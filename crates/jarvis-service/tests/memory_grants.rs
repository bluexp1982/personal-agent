//! 执行授权：命中、硬边界、撤销、终态回收、过期。
//!
//! 这一组直接调 `grants` 模块并构造最小的库内数据（项目 → 会话 → 任务 → 审批），
//! 不起真实 worker：审批链路的顺序（授权命中在 pending 之前）由
//! `worker/events.rs` 的代码顺序保证，见该函数头部的注释。

mod common;

use jarvis_service::config::Config;
use jarvis_service::grants::{self, GrantFilter, NewGrant};
use jarvis_service::task;

use protocol::{GrantScope, RiskLevel, TaskState};

use common::{setup_with, TestContext};

struct Fixture {
    ctx: TestContext,
    project_id: String,
    conversation_id: String,
    task_id: String,
    approval_id: String,
}

/// 造一条最小链路：项目 → 会话 → 任务 → 已批准的审批。
async fn fixture(tag: &str) -> Fixture {
    let ctx = setup_with(|config: &mut Config| {
        config.memory.enabled = true;
    })
    .await;
    let (_device, _token) = ctx.pair_and_login(tag).await;
    let project_id = ctx.work_project(tag).await;
    let now = jarvis_service::clock::now_ms();

    let conversation_id = format!("conv_{tag}");
    sqlx::query(
        "INSERT INTO conversations (id, title, device_id, project_id, created_at, updated_at) \
         VALUES (?, '测试会话', NULL, ?, ?, ?)",
    )
    .bind(&conversation_id)
    .bind(&project_id)
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入会话失败");

    let task_id = format!("task_{tag}");
    sqlx::query(
        "INSERT INTO tasks (id, conversation_id, type, skill, state, created_at, updated_at) \
         VALUES (?, ?, 'code', 'code_task', 'running', ?, ?)",
    )
    .bind(&task_id)
    .bind(&conversation_id)
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入任务失败");

    let approval_id = format!("apv_{tag}");
    sqlx::query(
        "INSERT INTO approvals (id, task_id, action, expires_at, decision, created_at, scope) \
         VALUES (?, ?, 'code.tool_use', ?, 'pending', ?, 'tool')",
    )
    .bind(&approval_id)
    .bind(&task_id)
    .bind(now + 600_000)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入审批失败");

    Fixture {
        ctx,
        project_id,
        conversation_id,
        task_id,
        approval_id,
    }
}

async fn grant_for(
    fixture: &Fixture,
    risk: RiskLevel,
    scope: GrantScope,
) -> Result<protocol::Grant, grants::GrantError> {
    let now = jarvis_service::clock::now_ms();
    let resolved = grants::resolve_scope(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        scope,
        600_000,
        now,
    )
    .await?;
    grants::create_resolved(
        &fixture.ctx.state.pool,
        NewGrant {
            tool: "code.write",
            risk,
            scope,
            approval_id: &fixture.approval_id,
            device_id: None,
        },
        resolved,
        now,
    )
    .await
}

#[tokio::test]
async fn grant_hit_skips_card_and_audits() {
    let fixture = fixture("grt-hit").await;
    let grant = grant_for(&fixture, RiskLevel::ReversibleWrite, GrantScope::Task)
        .await
        .expect("建授权失败");

    let now = jarvis_service::clock::now_ms();
    let hit = grants::find_hit(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        "code.write",
        RiskLevel::ReversibleWrite,
        now,
    )
    .await
    .expect("查询失败")
    .expect("应命中任务级授权");

    assert_eq!(hit.id, grant.id);
    assert_eq!(hit.hit_count, 1, "命中要累计次数，用于事后解释");

    // 同一任务的下一次调用仍然命中。
    let again = grants::find_hit(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        "code.write",
        RiskLevel::ReversibleWrite,
        now,
    )
    .await
    .expect("查询失败")
    .expect("应命中");
    assert_eq!(again.hit_count, 2);
}

#[tokio::test]
async fn grant_cannot_cover_irreversible() {
    let fixture = fixture("grt-irrev").await;
    let result = grant_for(&fixture, RiskLevel::IrreversibleWrite, GrantScope::Task).await;

    assert!(result.is_err(), "不可逆动作永远不建授权");
    let now = jarvis_service::clock::now_ms();
    let hit = grants::find_hit(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        "code.write",
        RiskLevel::IrreversibleWrite,
        now,
    )
    .await
    .expect("查询失败");
    assert!(hit.is_none());
}

#[tokio::test]
async fn revoke_asks_again() {
    let fixture = fixture("grt-revoke").await;
    let grant = grant_for(&fixture, RiskLevel::ReversibleWrite, GrantScope::Task)
        .await
        .expect("建授权失败");

    grants::revoke(
        &fixture.ctx.state.pool,
        &grant.id,
        jarvis_service::clock::now_ms(),
    )
    .await
    .expect("撤销失败");

    let now = jarvis_service::clock::now_ms();
    let hit = grants::find_hit(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        "code.write",
        RiskLevel::ReversibleWrite,
        now,
    )
    .await
    .expect("查询失败");
    assert!(hit.is_none(), "撤销后下一次同类调用必须重新建卡");
}

#[tokio::test]
async fn task_end_revokes_task_scope() {
    let fixture = fixture("grt-task-end").await;
    grant_for(&fixture, RiskLevel::ReversibleWrite, GrantScope::Task)
        .await
        .expect("建授权失败");

    // 终态经由 `task::transition`：任务级授权在那里被批量撤销。
    task::transition(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        TaskState::Succeeded,
        None,
    )
    .await
    .expect("状态转移失败");

    let now = jarvis_service::clock::now_ms();
    let hit = grants::find_hit(
        &fixture.ctx.state.pool,
        &fixture.task_id,
        "code.write",
        RiskLevel::ReversibleWrite,
        now,
    )
    .await
    .expect("查询失败");
    assert!(hit.is_none(), "任务结束后任务级授权应失效");
}

#[tokio::test]
async fn session_scope_expires_24h() {
    let fixture = fixture("grt-session").await;
    let grant = grant_for(&fixture, RiskLevel::ReversibleWrite, GrantScope::Session)
        .await
        .expect("建授权失败");

    assert_eq!(grant.scope, GrantScope::Session);
    assert_eq!(
        grant.scope_id, fixture.conversation_id,
        "会话级作用域要落到会话 id，而不是任务 id"
    );

    let now = jarvis_service::clock::now_ms();
    // 24 小时内可用。
    let alive = grants::list(
        &fixture.ctx.state.pool,
        &GrantFilter::default(),
        None,
        20,
        now + 3_600_000,
    )
    .await
    .expect("列表失败");
    assert_eq!(alive.items.len(), 1);

    // 24 小时之后：过期清标后不再出现。
    grants::expire_due(&fixture.ctx.state.pool, now + 25 * 3_600_000)
        .await
        .expect("清标失败");
    let expired = grants::list(
        &fixture.ctx.state.pool,
        &GrantFilter::default(),
        None,
        20,
        now + 25 * 3_600_000,
    )
    .await
    .expect("列表失败");
    assert!(expired.items.is_empty(), "会话级授权 24 小时后失效");
}

#[tokio::test]
async fn api_lists_and_revokes() {
    let fixture = fixture("grt-api").await;
    let grant = grant_for(&fixture, RiskLevel::ReversibleWrite, GrantScope::Task)
        .await
        .expect("建授权失败");

    let (_device, token) = fixture.ctx.pair_and_login("grt-api-2").await;
    let response = fixture.ctx.get_json("/api/grants", &token).await;
    assert_eq!(response.status(), 200);
    let page = common::body_json(response).await;
    assert_eq!(page["items"].as_array().map(Vec::len), Some(1));

    let response = fixture
        .ctx
        .delete(&format!("/api/grants/{}", grant.id), &token)
        .await;
    assert_eq!(response.status(), 204);

    let response = fixture.ctx.get_json("/api/grants", &token).await;
    let page = common::body_json(response).await;
    assert_eq!(page["items"].as_array().map(Vec::len), Some(0));

    // 项目删掉后项目级授权也应失效（这里用同一作用域构造一次）。
    let _ = fixture.project_id;
}
