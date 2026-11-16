//! 记忆存储层：迁移、FTS5 可用性、去重、软删。
//!
//! 直接对 SQLite 建库，不走 HTTP——这些是"表与 SQL 对不对"的问题，
//! 走一遍 Router 只会让失败原因更难定位。

mod common;

use protocol::{
    EvidenceSource, MemoryKind, MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource,
    MemoryStatus,
};
use sqlx::SqlitePool;
use jarvis_service::memory::store::{
    EvidenceDraft, MemoryDraft, MemoryFilter, MemoryPatch, MemoryStore,
};

fn draft(content: &str) -> MemoryDraft {
    MemoryDraft {
        kind: MemoryKind::Preference,
        pipeline: MemoryPipeline::Subjective,
        status: MemoryStatus::Active,
        scope: MemoryScope::Global,
        project_id: None,
        sensitivity: MemorySensitivity::Normal,
        content: content.to_string(),
        subject: None,
        predicate: None,
        time_scope: None,
        due_at: None,
        confidence: 0.9,
        importance: 0.6,
        pinned: false,
        batch_id: None,
        source: MemorySource::Explicit,
        valid_from: 1_700_000_000_000,
    }
}

async fn fresh_pool() -> (SqlitePool, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("创建临时目录失败");
    let path = dir.path().join("memory.db");
    let pool = jarvis_service::db::connect(&path)
        .await
        .expect("打开数据库失败");
    jarvis_service::db::migrate(&pool).await.expect("迁移失败");
    (pool, dir)
}

#[tokio::test]
async fn fts5_is_available() {
    let (pool, _dir) = fresh_pool().await;
    let enabled: i64 = sqlx::query_scalar("SELECT sqlite_compileoption_used('ENABLE_FTS5')")
        .fetch_one(&pool)
        .await
        .expect("查询编译选项失败");

    assert_eq!(enabled, 1, "FTS5 未编译进 SQLite，4.3 的索引方案不可用");
}

#[tokio::test]
async fn insert_indexes_tokens_and_reads_back() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let memory = store
        .insert(draft("回答先给结论再给依据"))
        .await
        .expect("写入失败");
    assert!(jarvis_service::ids::has_prefix(&memory.id, "mem"));
    assert_eq!(memory.content, "回答先给结论再给依据");
    assert_eq!(memory.status, MemoryStatus::Active);

    // 走 FTS 搜两字："结论" 必须命中，这正是 bigram 预分词要解决的问题。
    let (items, cursor) = store
        .list(
            MemoryFilter {
                q: Some("结论".to_string()),
                ..MemoryFilter::default()
            },
            None,
            20,
        )
        .await
        .expect("搜索失败");
    assert_eq!(items.len(), 1);
    assert!(cursor.is_none(), "关键词搜索不分页");
}

#[tokio::test]
async fn dedupe_merges_evidence() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let first = store
        .insert(draft("每周三下午有空"))
        .await
        .expect("写入失败");
    let duplicate = store
        .find_duplicate(None, "每周三下午有空")
        .await
        .expect("查重失败")
        .expect("应当查到重复");
    assert_eq!(duplicate.id, first.id);

    store
        .add_evidence(
            &first.id,
            EvidenceDraft {
                source_kind: EvidenceSource::Message,
                source_id: "msg_1".to_string(),
                quote: "我一般周三下午有空".to_string(),
                support_span: Some("周三下午".to_string()),
                created_at: 1_700_000_000_000,
            },
        )
        .await
        .expect("写证据失败");

    let detail = store.get(&first.id).await.expect("读失败").expect("应存在");
    assert_eq!(detail.evidence.len(), 1);
    assert_eq!(detail.evidence[0].quote, "我一般周三下午有空");

    // 不同内容不算重复。
    assert!(store
        .find_duplicate(None, "每周四下午有空")
        .await
        .expect("查重失败")
        .is_none());
}

#[tokio::test]
async fn soft_delete_is_invisible_to_reads() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let memory = store.insert(draft("不吃香菜")).await.expect("写入失败");
    store.soft_delete(&memory.id).await.expect("删除失败");

    assert!(store.get(&memory.id).await.expect("读失败").is_none());

    let (items, _) = store
        .list(MemoryFilter::default(), None, 20)
        .await
        .expect("列表失败");
    assert!(items.is_empty(), "软删后列表不应再出现");

    // 行还在，只是标记了；审计与撤销都依赖这一点。
    let (status, deleted_at): (String, Option<i64>) =
        sqlx::query_as("SELECT status, deleted_at FROM memories WHERE id = ?")
            .bind(&memory.id)
            .fetch_one(&pool)
            .await
            .expect("查询失败");
    assert_eq!(status, "deleted");
    assert!(deleted_at.is_some());

    // 重复删除是幂等的。
    store
        .soft_delete(&memory.id)
        .await
        .expect("重复删除不应报错");
}

#[tokio::test]
async fn update_recomputes_tokens() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let memory = store.insert(draft("用 Jenkinss")).await.expect("写入失败");
    store
        .update(
            &memory.id,
            MemoryPatch {
                content: Some("用 GitHub Actions".to_string()),
                source: Some(MemorySource::UserCorrected),
                ..MemoryPatch::default()
            },
        )
        .await
        .expect("更新失败");

    let (items, _) = store
        .list(
            MemoryFilter {
                q: Some("Actions".to_string()),
                ..MemoryFilter::default()
            },
            None,
            20,
        )
        .await
        .expect("搜索失败");
    assert_eq!(items.len(), 1, "改正文后索引必须跟着更新");
    assert_eq!(items[0].source, MemorySource::UserCorrected);

    // 旧内容不应再被搜到。
    let (stale, _) = store
        .list(
            MemoryFilter {
                q: Some("Jenkinss".to_string()),
                ..MemoryFilter::default()
            },
            None,
            20,
        )
        .await
        .expect("搜索失败");
    assert!(stale.is_empty(), "旧分词串必须从索引里消失");
}

#[tokio::test]
async fn list_paginates_by_cursor() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    for index in 0..5 {
        store
            .insert(draft(&format!("第 {index} 条记忆")))
            .await
            .expect("写入失败");
        // 保证 updated_at 单调，避免同一毫秒内排序不稳定。
        tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    }

    let (first, cursor) = store
        .list(MemoryFilter::default(), None, 2)
        .await
        .expect("列表失败");
    assert_eq!(first.len(), 2);
    let cursor = cursor.expect("还有下一页");

    let (second, _) = store
        .list(MemoryFilter::default(), Some(&cursor.encode()), 2)
        .await
        .expect("列表失败");
    assert_eq!(second.len(), 2);
    assert!(first
        .iter()
        .all(|item| second.iter().all(|other| other.id != item.id)));
}

#[tokio::test]
async fn stale_by_source_and_counts() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let memory = store.insert(draft("报销走飞书")).await.expect("写入失败");
    store
        .add_evidence(
            &memory.id,
            EvidenceDraft {
                source_kind: EvidenceSource::Message,
                source_id: "msg_9".to_string(),
                quote: "我们报销走飞书".to_string(),
                support_span: None,
                created_at: 1_700_000_000_000,
            },
        )
        .await
        .expect("写证据失败");

    let counts = store.counts().await.expect("统计失败");
    assert_eq!(counts.active, 1);

    let affected = store
        .mark_stale_by_source(EvidenceSource::Message, "msg_9")
        .await
        .expect("标记失败");
    assert_eq!(affected, 1);

    let counts = store.counts().await.expect("统计失败");
    assert_eq!(counts.active, 0);
    assert_eq!(counts.stale, 1);

    // stale 仍然可读（详情页要看得到），但不会进 digest。
    assert!(store.get(&memory.id).await.expect("读失败").is_some());
    assert!(store.for_digest(50).await.expect("取摘要失败").is_empty());
}

#[tokio::test]
async fn supersede_keeps_history() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let old = store
        .insert(draft("报销走邮件审批"))
        .await
        .expect("写入失败");
    let new = store
        .insert(draft("报销走飞书审批"))
        .await
        .expect("写入失败");

    assert!(store.supersede(&old.id, &new.id).await.expect("取代失败"));

    // 旧记忆不删除、不软删：行与证据都留着，只是不再生效。
    let row: (String, Option<String>, Option<i64>) =
        sqlx::query_as("SELECT status, superseded_by, valid_to FROM memories WHERE id = ?")
            .bind(&old.id)
            .fetch_one(&pool)
            .await
            .expect("查询失败");

    assert_eq!(row.0, "archived", "被取代的旧事实应退出生效区");
    assert_eq!(row.1.as_deref(), Some(new.id.as_str()));
    assert!(row.2.is_some(), "valid_to 要记下失效时刻");

    // 详情仍能查到（历史可追溯）。
    let detail = store
        .get(&old.id)
        .await
        .expect("查询失败")
        .expect("应仍可查");
    assert_eq!(detail.memory.status, MemoryStatus::Archived);

    // 重复取代是幂等的：第二次不再影响任何行。
    assert!(!store.supersede(&old.id, &new.id).await.expect("取代失败"));
}

#[tokio::test]
async fn batch_revoke_archives_all() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    for index in 0..3 {
        let mut item = draft(&format!("第 {index} 条自动抽取"));
        item.batch_id = Some("bat_1".to_string());
        item.status = MemoryStatus::Candidate;
        store.insert(item).await.expect("写入失败");
    }

    let revoked = store.revoke_batch("bat_1").await.expect("撤销失败");
    assert_eq!(revoked, 3, "整批撤销应覆盖同批次全部候选");

    let archived: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM memories WHERE batch_id = 'bat_1' AND status = 'archived'",
    )
    .fetch_one(&pool)
    .await
    .expect("查询失败");
    assert_eq!(archived, 3);

    // 撤销不硬删：行仍在（时间线可追溯）。
    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memories WHERE batch_id = 'bat_1'")
        .fetch_one(&pool)
        .await
        .expect("查询失败");
    assert_eq!(rows, 3);
}

#[tokio::test]
async fn supersede_conflicting_replaces_same_fact() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    // 同主体 + 同谓词的两条旧事实，加一条别的主体（不该被牵连）。
    let mut old_a = draft("张三的生日是 3 月 5 日");
    old_a.subject = Some("张三".to_string());
    old_a.predicate = Some("生日".to_string());
    let old_a = store.insert(old_a).await.expect("写入失败");

    let mut old_b = draft("张三的生日是 3 月 6 日");
    old_b.subject = Some("张三".to_string());
    old_b.predicate = Some("生日".to_string());
    let old_b = store.insert(old_b).await.expect("写入失败");

    let mut other = draft("李四的生日是 7 月 1 日");
    other.subject = Some("李四".to_string());
    other.predicate = Some("生日".to_string());
    let other = store.insert(other).await.expect("写入失败");

    let new = store
        .insert({
            let mut item = draft("张三的生日是 3 月 7 日");
            item.subject = Some("张三".to_string());
            item.predicate = Some("生日".to_string());
            item
        })
        .await
        .expect("写入失败");

    let count = store
        .supersede_conflicting("张三", "生日", &new.id, "张三的生日是 3 月 7 日")
        .await
        .expect("取代失败");
    assert_eq!(count, 2, "同主体同谓词的两条旧事实都应被取代");

    for id in [&old_a.id, &old_b.id] {
        let status: (String,) = sqlx::query_as("SELECT status FROM memories WHERE id = ?")
            .bind(id)
            .fetch_one(&pool)
            .await
            .expect("查询失败");
        assert_eq!(status.0, "archived");
    }

    let untouched: (String,) = sqlx::query_as("SELECT status FROM memories WHERE id = ?")
        .bind(&other.id)
        .fetch_one(&pool)
        .await
        .expect("查询失败");
    assert_eq!(untouched.0, "active", "别的主体的记忆不该被牵连");

    // 主语或谓语缺失时不做取代：没有判据就宁可不做。
    assert_eq!(
        store
            .supersede_conflicting("", "生日", &new.id, "x")
            .await
            .expect("取代失败"),
        0
    );
}

#[tokio::test]
async fn dedupe_merges_punctuation_variants() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let mut first = draft("用户希望被称呼为\"老爷\"。");
    first.subject = Some("用户".to_string());
    first.predicate = Some("称呼".to_string());
    let first = store.insert(first).await.expect("写入失败");

    // 同一句话的另一种写法：引号变成全角引号 + 空格差异。
    let subject_norm = jarvis_service::memory::tokenize::normalize_for_match("用户");
    let found = store
        .find_duplicate(Some(&subject_norm), "用户希望被称呼为“老爷”")
        .await
        .expect("查询失败")
        .expect("标点差异不该产生第二条");

    assert_eq!(found.id, first.id);

    // 真的不同的话仍然不算重复。
    assert!(store
        .find_duplicate(Some(&subject_norm), "用户希望被称呼为老板")
        .await
        .expect("查询失败")
        .is_none());
}

#[tokio::test]
async fn conflicting_requires_same_predicate() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let mut birthday = draft("用户出生于 1982 年");
    birthday.subject = Some("用户".to_string());
    birthday.predicate = Some("生日".to_string());
    let birthday = store.insert(birthday).await.expect("写入失败");

    let mut address = draft("用户是浙江嘉兴人");
    address.subject = Some("用户".to_string());
    address.predicate = Some("籍贯".to_string());
    store.insert(address).await.expect("写入失败");

    // 主体相同但谓词不同：不是"同一件事的两种说法"，不该报警。
    let detail = store
        .get(&birthday.id)
        .await
        .expect("查询失败")
        .expect("应存在");
    assert!(!detail.memory.conflicting, "不同谓词不该互相判成分歧");

    // 同谓词、不同内容才是真正的分歧。
    let mut another = draft("用户出生于 1983 年");
    another.subject = Some("用户".to_string());
    another.predicate = Some("生日".to_string());
    store.insert(another).await.expect("写入失败");

    let detail = store
        .get(&birthday.id)
        .await
        .expect("查询失败")
        .expect("应存在");
    assert!(detail.memory.conflicting, "同谓词的不同说法应标记为分歧");
}

#[tokio::test]
async fn consolidate_merges_subsumed_addresses() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    // 真实出现过的五条"同一地址的详略不同"，全部 subject=用户、kind=profile。
    let texts = [
        "用户的老家是浙江省嘉兴市南湖区八字桥村。",
        "用户的老家在嘉兴市南湖区八字桥村。",
        "用户的老家是浙江嘉兴南湖区",
        "用户所在地为嘉兴市南湖区。",
        "用户是浙江嘉兴人。",
    ];
    let mut ids = Vec::new();
    for text in texts {
        let mut item = draft(text);
        item.kind = MemoryKind::Profile;
        item.subject = Some("用户".to_string());
        item.predicate = Some(format!("p{}", ids.len()));
        ids.push(store.insert(item).await.expect("写入失败").id);
    }

    // 给"最短"的那条挂一条独有证据，验证归并后证据会迁移。
    store
        .add_evidence(
            &ids[1],
            EvidenceDraft {
                source_kind: EvidenceSource::Explicit,
                source_id: "bat_test".to_string(),
                quote: "我老家在嘉兴市南湖区八字桥村".to_string(),
                support_span: None,
                created_at: 1_700_000_000_000,
            },
        )
        .await
        .expect("写证据失败");

    let merged = store.consolidate_subsumed(100).await.expect("归并失败");
    assert!(
        merged >= 2,
        "至少应把两条更简的并进最完整的一条，实际 {merged}"
    );

    let active: Vec<(String, String)> = sqlx::query_as(
        "SELECT id, content FROM memories WHERE status = 'active' ORDER BY length(content) DESC",
    )
    .fetch_all(&pool)
    .await
    .expect("查询失败");

    assert!(
        active
            .iter()
            .any(|(_, content)| content.contains("浙江省嘉兴市南湖区八字桥村")),
        "最完整的那条必须保留"
    );
    assert!(
        active.len() <= 3,
        "简写地址应被并掉，实际剩下 {} 条: {:?}",
        active.len(),
        active
    );

    // 归并是归档不是删除：被并掉的行仍在，且 superseded_by 指向保留条。
    let archived: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM memories WHERE status = 'archived' AND superseded_by IS NOT NULL",
    )
    .fetch_one(&pool)
    .await
    .expect("查询失败");
    assert!(archived >= 2, "被并掉的行应保留并标注 superseded_by");

    // 证据没有丢：条数不变，且不再挂在被归档的那条上。
    let evidence: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memory_evidence")
        .fetch_one(&pool)
        .await
        .expect("查询失败");
    assert_eq!(evidence, 1, "证据应整行迁移，不复制、不丢失");
    let on_archived: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_evidence WHERE memory_id = ?")
            .bind(&ids[1])
            .fetch_one(&pool)
            .await
            .expect("查询失败");
    assert_eq!(on_archived, 0, "证据应已迁到保留条");
}

#[tokio::test]
async fn consolidate_skips_unrelated_and_short() {
    let (pool, _dir) = fresh_pool().await;
    let store = MemoryStore::new(&pool);

    let mut birthday = draft("用户1982年出生。");
    birthday.kind = MemoryKind::Profile;
    birthday.subject = Some("用户".to_string());
    birthday.predicate = Some("生日".to_string());
    let birthday = store.insert(birthday).await.expect("写入失败");

    let mut name = draft("用户希望被称呼为老爷。");
    name.kind = MemoryKind::Preference;
    name.subject = Some("用户".to_string());
    name.predicate = Some("称呼".to_string());
    let name = store.insert(name).await.expect("写入失败");

    let merged = store.consolidate_subsumed(100).await.expect("归并失败");
    assert_eq!(merged, 0, "不同事实不该被归并");

    for id in [&birthday.id, &name.id] {
        let status: (String,) = sqlx::query_as("SELECT status FROM memories WHERE id = ?")
            .bind(id)
            .fetch_one(&pool)
            .await
            .expect("查询失败");
        assert_eq!(status.0, "active");
    }
}
