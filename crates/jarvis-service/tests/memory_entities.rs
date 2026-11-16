//! 实体：强/弱匹配、pending → active、夜间重算上限、合并、拆分。

mod common;

use std::pin::Pin;

use serde_json::json;
use jarvis_service::config::Config;
use jarvis_service::memory::entity::{self, EntityDraft, MatchReason};
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};

use common::{body_json, setup_with, TestContext};

struct FixedModel;

impl std::fmt::Debug for FixedModel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FixedModel")
    }
}

impl CompletionModel for FixedModel {
    fn complete(
        &self,
        _system: &str,
        _prompt: &str,
        _max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        Box::pin(async {
            Ok(Completion {
                text: "这位是 A 公司的对接人，最近在谈续约。".to_string(),
                prompt_tokens: 10,
                completion_tokens: 20,
                tokens_estimated: true,
                finish_reason: None,
            })
        }) as Pin<Box<_>>
    }
}

async fn memory_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
    })
    .await
}

async fn create_memory(ctx: &TestContext, token: &str, content: &str) -> String {
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
    body_json(response).await["memory"]["id"]
        .as_str()
        .expect("缺少记忆 id")
        .to_string()
}

fn draft(name: &str) -> EntityDraft {
    EntityDraft {
        entity_type: protocol::EntityType::Person,
        name: name.to_string(),
        project_id: None,
        project_path: None,
    }
}

#[tokio::test]
async fn new_entity_starts_pending_then_active() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-pending").await;
    let first = create_memory(&ctx, &token, "与王工确认了续约价格").await;
    let second = create_memory(&ctx, &token, "王工说下周给答复").await;

    let now = jarvis_service::clock::now_ms();
    let (id, reason) = entity::match_or_create(&ctx.state.pool, draft("王工"), &first, now, 0.7)
        .await
        .expect("建实体失败");
    assert_eq!(reason, MatchReason::Created);

    let detail = entity::get(&ctx.state.pool, &id)
        .await
        .expect("查实体失败")
        .expect("实体应存在");
    assert_eq!(detail.entity.status, protocol::EntityStatus::Pending);

    // 第二条独立证据到达才转 active。
    entity::match_or_create(&ctx.state.pool, draft("王工"), &second, now, 0.7)
        .await
        .expect("二次匹配失败");

    let detail = entity::get(&ctx.state.pool, &id)
        .await
        .expect("查实体失败")
        .expect("实体应存在");
    assert_eq!(detail.entity.status, protocol::EntityStatus::Active);
    assert_eq!(detail.timeline.len(), 2);
}

#[tokio::test]
async fn strong_match_by_alias() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-alias").await;
    let memory = create_memory(&ctx, &token, "王工负责 A 公司").await;
    let now = jarvis_service::clock::now_ms();

    let (id, _) = entity::match_or_create(&ctx.state.pool, draft("王工"), &memory, now, 0.7)
        .await
        .expect("建实体失败");

    entity::update(
        &ctx.state.pool,
        &id,
        protocol::EntityUpdateRequest {
            aliases: Some(vec!["老王".to_string()]),
            ..protocol::EntityUpdateRequest::default()
        },
    )
    .await
    .expect("加别名失败");

    let another = create_memory(&ctx, &token, "老王提到下周出差").await;
    let (matched, reason) =
        entity::match_or_create(&ctx.state.pool, draft("老王"), &another, now, 0.7)
            .await
            .expect("匹配失败");

    assert_eq!(matched, id, "别名应命中同一个实体");
    assert_eq!(reason, MatchReason::ExactAlias);
}

#[tokio::test]
async fn weak_match_requires_confidence() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-weak").await;
    let now = jarvis_service::clock::now_ms();

    let first = create_memory(&ctx, &token, "鼎盛建材报价最低").await;
    let second = create_memory(&ctx, &token, "鼎盛建材这周送货").await;
    let (existing, _) =
        entity::match_or_create(&ctx.state.pool, draft("鼎盛建材"), &first, now, 0.7)
            .await
            .expect("建实体失败");
    entity::match_or_create(&ctx.state.pool, draft("鼎盛建材"), &second, now, 0.7)
        .await
        .expect("二次匹配失败");

    // 名称互相包含但置信度阈值调到 1.0：只能新建 pending，不许错误归并。
    let third = create_memory(&ctx, &token, "鼎盛的发票还没到").await;
    let (new_id, reason) =
        entity::match_or_create(&ctx.state.pool, draft("鼎盛"), &third, now, 1.0)
            .await
            .expect("匹配失败");

    assert_ne!(new_id, existing, "阈值不达标时不许并到既有实体");
    assert_eq!(reason, MatchReason::Created);
}

#[tokio::test]
async fn merge_moves_links() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-merge").await;
    let first = create_memory(&ctx, &token, "王工负责对接").await;
    let second = create_memory(&ctx, &token, "李经理负责采购").await;
    let now = jarvis_service::clock::now_ms();

    let (source, _) = entity::match_or_create(&ctx.state.pool, draft("王工"), &first, now, 0.7)
        .await
        .expect("建实体失败");
    let (target, _) = entity::match_or_create(&ctx.state.pool, draft("李经理"), &second, now, 0.7)
        .await
        .expect("建实体失败");

    entity::merge(&ctx.state.pool, &source, &target, "test")
        .await
        .expect("合并失败");

    let target_detail = entity::get(&ctx.state.pool, &target)
        .await
        .expect("查实体失败")
        .expect("目标应存在");
    assert_eq!(target_detail.timeline.len(), 2, "引用应全部转投目标");

    let source_detail = entity::get(&ctx.state.pool, &source)
        .await
        .expect("查实体失败")
        .expect("被合并方仍可查");
    assert_eq!(source_detail.entity.status, protocol::EntityStatus::Merged);
    assert!(source_detail.timeline.is_empty());
}

#[tokio::test]
async fn split_creates_new_entity() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-split").await;
    let first = create_memory(&ctx, &token, "王工负责续约").await;
    let second = create_memory(&ctx, &token, "王工喜欢喝茶").await;
    let now = jarvis_service::clock::now_ms();

    let (id, _) = entity::match_or_create(&ctx.state.pool, draft("王工"), &first, now, 0.7)
        .await
        .expect("建实体失败");
    entity::match_or_create(&ctx.state.pool, draft("王工"), &second, now, 0.7)
        .await
        .expect("二次匹配失败");

    let new_id = entity::split(
        &ctx.state.pool,
        &id,
        std::slice::from_ref(&second),
        Some("王工-爱好"),
    )
    .await
    .expect("拆分失败");

    let new_detail = entity::get(&ctx.state.pool, &new_id)
        .await
        .expect("查实体失败")
        .expect("新实体应存在");
    assert_eq!(new_detail.entity.name, "王工-爱好");
    assert_eq!(new_detail.entity.status, protocol::EntityStatus::Pending);
    assert_eq!(new_detail.timeline.len(), 1);

    let old_detail = entity::get(&ctx.state.pool, &id)
        .await
        .expect("查实体失败")
        .expect("原实体应存在");
    assert_eq!(old_detail.timeline.len(), 1, "被拆走的记忆不该留在原实体");
}

#[tokio::test]
async fn recompute_respects_nightly_limit() {
    let ctx = memory_enabled().await;
    let (_device, token) = ctx.pair_and_login("ent-recompute").await;
    let now = jarvis_service::clock::now_ms();

    for index in 0..3 {
        let memory = create_memory(&ctx, &token, &format!("第 {index} 条关于王工的记录")).await;
        entity::match_or_create(
            &ctx.state.pool,
            draft(&format!("王工{index}")),
            &memory,
            now,
            0.7,
        )
        .await
        .expect("建实体失败");
    }

    let model = FixedModel;
    let report = entity::recompute_dirty(&ctx.state.pool, Some(&model), 2, now)
        .await
        .expect("重算失败");

    assert_eq!(report.scanned, 2, "夜间批处理必须受 nightly_limit 约束");
    assert_eq!(report.updated, 2);

    // 还有一个仍然是脏的，下一轮会处理。
    let dirty: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memory_entities WHERE dirty = 1")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(dirty, 1);
}
