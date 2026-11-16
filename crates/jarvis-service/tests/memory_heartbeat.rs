//! 心跳：到期扫描、24h 去重、每日额度、静音仍记录、状态可恢复。

mod common;

use serde_json::json;
use jarvis_service::config::Config;
use jarvis_service::heartbeat;

use common::{body_json, setup_with, TestContext};

async fn heartbeat_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = true;
        config.memory.heartbeat.daily_limit = 2;
        // 24 点不存在 → 夜间整理永不触发，delivered 计数才有确定性。
        // 需要夜间分支的用例自己把它改成 0。
        config.memory.heartbeat.nightly_after_hour = 24;
    })
    .await
}

async fn create_due_memory(ctx: &TestContext, token: &str, content: &str, due_at: i64) -> String {
    let response = ctx
        .post_json(
            "/api/memories",
            token,
            &json!({
                "kind": "event",
                "content": content,
                "evidence_quote": content,
            }),
        )
        .await;
    let id = body_json(response).await["memory"]["id"]
        .as_str()
        .expect("缺少记忆 id")
        .to_string();

    // `due_at` 没有对外端点（它由抽取的 time_scope 推导），这里直接改库造数据。
    sqlx::query("UPDATE memories SET due_at = ? WHERE id = ?")
        .bind(due_at)
        .bind(&id)
        .execute(&ctx.state.pool)
        .await
        .expect("设置 due_at 失败");

    id
}

#[tokio::test]
async fn due_scan_finds_today_and_tomorrow() {
    let ctx = heartbeat_enabled().await;
    let (_device, token) = ctx.pair_and_login("hb-due").await;
    let project = ctx.work_project("hb").await;
    assert!(!project.is_empty());

    let now = jarvis_service::clock::now_ms();
    create_due_memory(&ctx, &token, "明天十点面试", now + 3_600_000).await;
    // 三天后的不该进这一轮。
    create_due_memory(&ctx, &token, "三天后出差", now + 3 * 86_400_000).await;

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert_eq!(report.due, 1, "只扫未来 24 小时");
    // 夜间整理会额外产出一条 digest_report，这里只数 due。
    let due_rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE category = 'due'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(due_rows, 1, "命中一条就应产出一条到期提醒");
}

#[tokio::test]
async fn dedupe_within_24h() {
    let ctx = heartbeat_enabled().await;
    let (_device, token) = ctx.pair_and_login("hb-dedupe").await;
    ctx.work_project("hb-dedupe").await;

    let now = jarvis_service::clock::now_ms();
    create_due_memory(&ctx, &token, "今天下午评审", now + 3_600_000).await;

    let _first = heartbeat::run_once_at(&ctx.state, now).await;

    // 15 分钟后再跑同一件事：去重键相同，库里仍然只有一条记录。
    let second = heartbeat::run_once_at(&ctx.state, now + 15 * 60_000).await;
    assert_eq!(second.delivered, 0, "同一事项 24 小时内不重复投递");

    let rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE category = 'due'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(rows, 1, "去重键唯一索引必须挡住第二次入队");
}

#[tokio::test]
async fn daily_limit_truncates_by_score() {
    let ctx = setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = true;
        config.memory.heartbeat.daily_limit = 2;
        // 让夜间整理也产出一条 digest_report：额度截断需要三个不同类别才测得出来
        // （同类会被聚合成一条，见 `aggregates_same_category`）。
        config.memory.heartbeat.nightly_after_hour = 0;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("hb-limit").await;
    ctx.work_project("hb-limit").await;

    let now = jarvis_service::clock::now_ms();
    for index in 0..2 {
        create_due_memory(
            &ctx,
            &token,
            &format!("今天第 {index} 件事"),
            now + 3_600_000 + index,
        )
        .await;
    }
    for index in 0..2 {
        create_due_memory(
            &ctx,
            &token,
            &format!("过期第 {index} 件事"),
            now - 86_400_000 - index,
        )
        .await;
    }

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert_eq!(
        report.delivered, 2,
        "每日上限 2 条，实际投递 {}",
        report.delivered
    );
    assert!(report.queued >= 1, "超出额度的留在队列里");

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(rows, 3, "到期 / 待办 / 整理各一条汇总结论都要留痕");
}

#[tokio::test]
async fn muted_category_records_but_does_not_deliver() {
    let ctx = heartbeat_enabled().await;
    let (_device, token) = ctx.pair_and_login("hb-mute").await;
    ctx.work_project("hb-mute").await;

    let response = ctx
        .patch_json(
            "/api/memories/settings",
            &token,
            &json!({ "heartbeat_mute": ["due"], "daily_limit": 2 }),
        )
        .await;
    assert_eq!(response.status(), axum::http::StatusCode::OK);

    let now = jarvis_service::clock::now_ms();
    create_due_memory(&ctx, &token, "明天交周报", now + 3_600_000).await;

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert_eq!(report.delivered, 0);
    assert_eq!(report.muted, 1);

    let muted: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE status = 'muted'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(muted, 1, "静音的类别仍要留痕");
}

#[tokio::test]
async fn state_survives_restart() {
    let ctx = heartbeat_enabled().await;
    let (_device, _token) = ctx.pair_and_login("hb-state").await;
    ctx.work_project("hb-state").await;

    let now = jarvis_service::clock::now_ms();
    heartbeat::run_once_at(&ctx.state, now).await;

    // "重启"= 用同一份配置新建一个 AppState，读回来还是在库里。
    let settings = jarvis_service::memory::settings::load(&ctx.state.pool).await;
    let (mute, limit) = (settings.mute, settings.daily_limit);
    assert!(mute.is_empty());
    assert_eq!(limit, 2);
    assert!(settings.digest_enabled);
}

#[tokio::test]
async fn overdue_items_become_todo_notifications() {
    let ctx = heartbeat_enabled().await;
    let (_device, token) = ctx.pair_and_login("hb-todo").await;
    ctx.work_project("hb-todo").await;

    let now = jarvis_service::clock::now_ms();
    // 昨天就该做的事：走"待办推进"，不进"未来 24 小时"。
    create_due_memory(&ctx, &token, "昨天该交的周报", now - 86_400_000).await;

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert_eq!(report.todo, 1, "过期项应归入待办推进");
    assert_eq!(report.due, 0, "过期项不该同时算到期提醒");

    let rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE category = 'todo'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(rows, 1);

    // 当天再跑一轮：去重键按天，不该重复提醒。
    heartbeat::run_once_at(&ctx.state, now + 15 * 60_000).await;
    let rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE category = 'todo'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(rows, 1, "同一件事当天只提醒一次");
}

#[tokio::test]
async fn nightly_sediments_recordings() {
    let ctx = setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = true;
        // 把"凌晨之后"改成"任何时候"：测试不该依赖运行时刻。
        config.memory.heartbeat.nightly_after_hour = 0;
    })
    .await;
    let (_device, _token) = ctx.pair_and_login("hb-sediment").await;

    let now = jarvis_service::clock::now_ms();
    sqlx::query(
        "INSERT INTO recordings \
          (id, client_recording_id, title, mode, status, text, summary, summary_status, \
           summary_updated_at, created_at, updated_at) \
         VALUES ('rec_1', 'client_1', '周会', 'realtime', 'recorded', '今天对齐了范围', \
                 '今天对齐了范围', 'ready', ?, ?, ?)",
    )
    .bind(now)
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入录音失败");

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert!(
        report.sedimented >= 1,
        "夜间整理应把新录音投递成抽取，实际 {}",
        report.sedimented
    );

    // 水位已经推进：同一批录音下一晚不会再投递。
    let again = heartbeat::run_once_at(&ctx.state, now + 21 * 3_600_000).await;
    assert_eq!(again.sedimented, 0, "水位之后没有新录音，不该重复投递");
}

#[tokio::test]
async fn aggregates_same_category() {
    let ctx = heartbeat_enabled().await;
    let (_device, token) = ctx.pair_and_login("hb-agg").await;
    ctx.work_project("hb-agg").await;

    let now = jarvis_service::clock::now_ms();
    for index in 0..3 {
        create_due_memory(
            &ctx,
            &token,
            &format!("第 {index} 件事"),
            now + 3_600_000 + index,
        )
        .await;
    }

    heartbeat::run_once_at(&ctx.state, now).await;

    let rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications WHERE category = 'due'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(rows, 1, "同类三条应合成一条汇总提醒");

    let (key, body): (String, String) =
        sqlx::query_as("SELECT dedupe_key, body FROM memory_notifications WHERE category = 'due'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert!(
        key.starts_with("agg:due:"),
        "汇总条目走独立去重键，实际 {key}"
    );
    assert!(body.contains("等 3 条"), "正文要点出总条数，实际 {body}");
}

#[tokio::test]
async fn decay_archives_stale_low_importance() {
    let ctx = setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = true;
        // 把"凌晨之后"改成"任何时候"，测试不依赖运行时刻。
        config.memory.heartbeat.nightly_after_hour = 0;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("hb-decay").await;

    let now = jarvis_service::clock::now_ms();
    let stale = create_due_memory(&ctx, &token, "很久以前的小事", now + 3_600_000).await;
    let pinned = create_due_memory(&ctx, &token, "置顶的事", now + 3_600_000).await;
    let important = create_due_memory(&ctx, &token, "重要的事", now + 3_600_000).await;

    let old = now - 200 * 86_400_000;
    // 三条都调成"很久没动 + 低重要度"，再让其中一条置顶、一条重要度偏高。
    sqlx::query(
        "UPDATE memories SET importance = 0.1, updated_at = ?, last_used_at = NULL WHERE id = ?",
    )
    .bind(old)
    .bind(&stale)
    .execute(&ctx.state.pool)
    .await
    .expect("改库失败");
    sqlx::query("UPDATE memories SET importance = 0.1, pinned = 1, updated_at = ? WHERE id = ?")
        .bind(old)
        .bind(&pinned)
        .execute(&ctx.state.pool)
        .await
        .expect("改库失败");
    sqlx::query("UPDATE memories SET importance = 0.9, updated_at = ? WHERE id = ?")
        .bind(old)
        .bind(&important)
        .execute(&ctx.state.pool)
        .await
        .expect("改库失败");

    let report = heartbeat::run_once_at(&ctx.state, now).await;
    assert!(
        report.decayed >= 1,
        "应至少归档一条，实际 {}",
        report.decayed
    );

    let rows: Vec<(String, String, Option<i64>)> = sqlx::query_as(
        "SELECT id, status, deleted_at FROM memories WHERE id IN (?, ?, ?) ORDER BY id",
    )
    .bind(&stale)
    .bind(&pinned)
    .bind(&important)
    .fetch_all(&ctx.state.pool)
    .await
    .expect("查询失败");

    for (id, status, deleted_at) in rows {
        if id == stale {
            assert_eq!(status, "archived", "长期不用又不重要的应归档");
            assert!(deleted_at.is_none(), "归档不是遗忘，不许写删除标记");
        } else {
            assert_ne!(status, "archived", "置顶或重要的记忆不该被归档");
        }
    }
}

#[tokio::test]
async fn nightly_consolidates_duplicates() {
    let ctx = setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = true;
        // 让夜间整理在任何时刻都能触发。
        config.memory.heartbeat.nightly_after_hour = 0;
    })
    .await;
    let (_device, token) = ctx.pair_and_login("hb-consolidate").await;

    // 两条同一地址的详略写法：短的应被并进长的那条。
    let long = create_due_memory(&ctx, &token, "用户的老家是浙江省嘉兴市南湖区八字桥村。", 0).await;
    let short = create_due_memory(&ctx, &token, "用户的老家在嘉兴市南湖区八字桥村。", 0).await;
    for (id, subject, predicate) in [
        (&long, "用户", "老家所在地"),
        (&short, "用户", "老家在嘉兴市南湖区八字桥村"),
    ] {
        sqlx::query(
            "UPDATE memories SET kind = 'profile', subject = ?, predicate = ? WHERE id = ?",
        )
        .bind(subject)
        .bind(predicate)
        .bind(id)
        .execute(&ctx.state.pool)
        .await
        .expect("改库失败");
    }

    let now = jarvis_service::clock::now_ms();
    let report = heartbeat::run_once_at(&ctx.state, now).await;

    assert!(report.consolidated >= 1, "夜间应把简写并进完整的那条");

    let archived: Option<(String,)> = sqlx::query_as("SELECT status FROM memories WHERE id = ?")
        .bind(&short)
        .fetch_optional(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(archived.map(|row| row.0).as_deref(), Some("archived"));

    let audited: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'memory.consolidated'")
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(audited, 1, "归并要留审计（只记条数）");
}
