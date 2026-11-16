//! 手动整理：不依赖自动整理开关、不产生提醒、不推进自动整理的节流水位。

mod common;

use axum::http::StatusCode;
use serde_json::json;
use jarvis_service::config::Config;

use common::{body_json, setup_with, TestContext};

/// 只开记忆系统本身：自动整理（heartbeat）保持关闭。
/// 手动「整理」按钮的前提就是"只要求 memory.enabled"。
async fn organize_enabled() -> TestContext {
    setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.heartbeat.enabled = false;
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

/// 轮询到「这一轮整理」完成。后台任务在 spawn 里跑，测试只能等。
async fn wait_organized(ctx: &TestContext, started_at: i64) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let last: Option<i64> = sqlx::query_scalar(
            "SELECT CAST(value_json AS INTEGER) FROM memory_heartbeat_state \
             WHERE key = 'last_organized_at'",
        )
        .fetch_optional(&ctx.state.pool)
        .await
        .expect("查询水位失败");

        if last.map(|value| value >= started_at).unwrap_or(false) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "整理未在 5 秒内完成，水位仍是 {last:?}"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn manual_organize_works_without_heartbeat() {
    let ctx = organize_enabled().await;
    let (_device, token) = ctx.pair_and_login("org-manual").await;

    let now = jarvis_service::clock::now_ms();
    let stale = create_memory(&ctx, &token, "很久以前的小事").await;
    // 长期没用 + 低重要度：衰减归档必须命中它。
    sqlx::query(
        "UPDATE memories SET importance = 0.1, updated_at = ?, last_used_at = NULL WHERE id = ?",
    )
    .bind(now - 200 * 86_400_000)
    .bind(&stale)
    .execute(&ctx.state.pool)
    .await
    .expect("改库失败");

    let response = ctx
        .post_json("/api/memories/organize", &token, &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let started_at = body_json(response).await["started_at"]
        .as_i64()
        .expect("缺少 started_at");

    wait_organized(&ctx, started_at).await;

    // 状态快照：忙碌态已复位，并且留下了这一轮的结果。
    let response = ctx.get_json("/api/memories/state", &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let state = body_json(response).await;
    assert_eq!(state["maintenance"]["organizing"], false);
    let reported_at = state["maintenance"]["last_organized_at"]
        .as_i64()
        .expect("手动整理后应有 last_organized_at");
    assert!(
        reported_at >= started_at,
        "last_organized_at={reported_at} 早于本次 started_at={started_at}"
    );
    assert!(
        state["maintenance"]["last_report"]["decayed"]
            .as_u64()
            .unwrap_or(0)
            >= 1,
        "报告里应体现至少一条归档"
    );

    let status: Option<(String,)> = sqlx::query_as("SELECT status FROM memories WHERE id = ?")
        .bind(&stale)
        .fetch_optional(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(status.map(|row| row.0).as_deref(), Some("archived"));

    // 手动整理不发「昨晚整理了记忆」：结果已经在页面上弹出过了。
    let notifications: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memory_notifications")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(notifications, 0, "手动整理不该产生提醒");

    // 也不推进自动整理的节流水位：否则当晚的自动整理会被静默跳过。
    let nightly: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM memory_heartbeat_state WHERE key = 'last_nightly_at'",
    )
    .fetch_one(&ctx.state.pool)
    .await
    .expect("查询失败");
    assert_eq!(nightly, 0, "手动整理不许写 last_nightly_at");
}

#[tokio::test]
async fn manual_organize_advances_sediment_watermark() {
    let ctx = organize_enabled().await;
    let (_device, _token) = ctx.pair_and_login("org-sediment").await;

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

    let first = ctx
        .state
        .memory
        .organize(now)
        .await
        .expect("第一次整理应成功");
    assert!(
        first.sedimented >= 1,
        "新录音应被沉淀，实际 {}",
        first.sedimented
    );

    // 水位已经推进：同一批录音再整理一次不会重复投递。
    let second = ctx
        .state
        .memory
        .organize(now + 60_000)
        .await
        .expect("第二次整理应成功");
    assert_eq!(second.sedimented, 0, "水位之后没有新录音，不该重复投递");
}

#[tokio::test]
async fn concurrent_organize_returns_conflict() {
    let ctx = organize_enabled().await;
    let (_device, token) = ctx.pair_and_login("org-busy").await;

    // 手动占住闸门，模拟"上一轮还在跑"。
    let lease = ctx
        .state
        .memory
        .try_begin_organize()
        .expect("首次应能抢到闸门");
    assert!(ctx.state.memory.organizing());

    let response = ctx
        .post_json("/api/memories/organize", &token, &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(response).await["code"], "conflict");

    // 释放后立刻可以再抢：闸门不能因为一次占用就永久卡死。
    drop(lease);
    assert!(!ctx.state.memory.organizing());
    ctx.state
        .memory
        .try_begin_organize()
        .expect("释放后应能再抢到闸门");
}

#[tokio::test]
async fn organize_requires_memory_enabled() {
    // 默认配置：记忆系统整体关闭。
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("org-off").await;

    let response = ctx
        .post_json("/api/memories/organize", &token, &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(response).await["code"], "memory_unavailable");
}
