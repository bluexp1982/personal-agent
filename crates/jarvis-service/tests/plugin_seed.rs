//! 示例技能（种子）的播种行为。
//!
//! 覆盖四件事：首次启动装好、重复播种幂等、用户卸载后不再装回、
//! 应用带来更高版本时补装。

mod common;

use axum::http::StatusCode;
use jarvis_service::plugin::seed;

const TRIP_ID: &str = "com.personal-agent.trip-plan";
const BILL_ID: &str = "com.personal-agent.bill-explain";

#[tokio::test]
async fn seeds_are_installed_on_first_start() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("seed-install").await;

    let body = common::body_json(
        ctx.call(common::authed_get("/api/plugins", &token)).await,
    )
    .await;
    let items = body["items"].as_array().expect("插件列表应是数组");

    for id in [TRIP_ID, BILL_ID] {
        let item = items
            .iter()
            .find(|item| item["id"] == id)
            .unwrap_or_else(|| panic!("应已播种 {id}: {body}"));
        assert_eq!(item["enabled"], true, "种子装好即启用");
    }

    // 技能侧：来源是插件、带用途说明（`@` 候选里那行灰字就来自它）。
    let skills = common::body_json(ctx.call(common::authed_get("/api/skills", &token)).await).await;
    let skills = skills.as_array().expect("技能列表应是数组");

    let trip = skills
        .iter()
        .find(|skill| skill["name"] == "trip-plan")
        .unwrap_or_else(|| panic!("应能看见 trip-plan: {skills:?}"));
    assert_eq!(trip["plugin_id"], TRIP_ID, "来源应是外部插件");
    assert!(
        trip["description"]
            .as_str()
            .is_some_and(|text| !text.is_empty()),
        "候选里要有一句用途说明: {trip}"
    );

    let bill = skills
        .iter()
        .find(|skill| skill["name"] == "bill-explain")
        .expect("应能看见 bill-explain");
    assert_eq!(bill["plugin_id"], BILL_ID);
    assert!(bill["description"]
        .as_str()
        .is_some_and(|text| !text.is_empty()));
}

#[tokio::test]
async fn seeding_twice_installs_nothing() {
    let ctx = common::setup().await;
    // `setup` 已经播过一次；再播应当直接跳过，不碰磁盘也不重复入库。
    let installed = seed::ensure(&ctx.state.pool, &ctx.state.config.plugins_dir())
        .await
        .expect("播种失败");
    assert_eq!(installed, 0, "重复播种不该再装一遍");
}

#[tokio::test]
async fn removed_seed_is_not_installed_again() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("seed-remove").await;

    let response = ctx
        .call(common::authed_delete(
            &format!("/api/plugins/{TRIP_ID}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let installed = seed::ensure(&ctx.state.pool, &ctx.state.config.plugins_dir())
        .await
        .expect("播种失败");
    assert_eq!(installed, 0, "用户卸载过的示例技能不该被装回");

    let body = common::body_json(
        ctx.call(common::authed_get("/api/plugins", &token)).await,
    )
    .await;
    assert!(
        !body["items"]
            .as_array()
            .expect("插件列表应是数组")
            .iter()
            .any(|item| item["id"] == TRIP_ID),
        "卸载后不该再出现: {body}"
    );
}

/// 修订号变化要把已装的包重算一遍。
///
/// 这正是"兼容层判据修好、但包版本没变"的场景：只比版本会永远跳过，
/// 用户看到的是「包在那儿，但状态还是不支持」。这里把已装结果改坏、
/// 再把修订号回退成旧记录，播种必须重装并纠正状态。
#[tokio::test]
async fn stale_revision_forces_reinstall() {
    let ctx = common::setup().await;

    // 模拟旧判据写进库的结论。
    sqlx::query("UPDATE plugin_skills SET status = 'unsupported' WHERE name = 'trip-plan'")
        .execute(&ctx.state.pool)
        .await
        .expect("改写旧状态失败");
    // 旧记录没有 revision（迁移默认空串）。
    sqlx::query("UPDATE plugin_seeds SET revision = '' WHERE name = ?")
        .bind(TRIP_ID)
        .execute(&ctx.state.pool)
        .await
        .expect("回退修订号失败");

    let installed = seed::ensure(&ctx.state.pool, &ctx.state.config.plugins_dir())
        .await
        .expect("播种失败");
    assert_eq!(installed, 1, "修订号变了，应重装一次");

    let status: String = sqlx::query_scalar("SELECT status FROM plugin_skills WHERE name = ?")
        .bind("trip-plan")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询技能状态失败");
    assert_eq!(status, "supported", "重装后应纠正成可用");
}

/// 卸载过的预置技能，`restore` 要能装回来。
///
/// 卸载会写下 `dismissed`，正常播种一律跳过；`restore` 是用户显式要求
/// "我要它回来"，必须绕过那个标记——这正是命令行存在的理由。
#[tokio::test]
async fn restore_installs_a_dismissed_seed() {
    let ctx = common::setup().await;
    let (_device, token) = ctx.pair_and_login("seed-restore").await;

    let response = ctx
        .call(common::authed_delete(
            &format!("/api/plugins/{TRIP_ID}"),
            &token,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // 先确认正常播种确实不会把它带回来。
    let installed = seed::ensure(&ctx.state.pool, &ctx.state.config.plugins_dir())
        .await
        .expect("播种失败");
    assert_eq!(installed, 0);

    let lines = seed::restore(
        &ctx.state.pool,
        &ctx.state.config.plugins_dir(),
        Some(TRIP_ID),
    )
    .await
    .expect("恢复失败");
    assert!(
        lines.iter().any(|line| line.contains("已恢复 trip-plan")),
        "输出应说明恢复了什么: {lines:?}"
    );

    let body = common::body_json(
        ctx.call(common::authed_get("/api/plugins", &token)).await,
    )
    .await;
    assert!(
        body["items"]
            .as_array()
            .expect("插件列表应是数组")
            .iter()
            .any(|item| item["id"] == TRIP_ID),
        "恢复后应重新出现在列表里: {body}"
    );
}

/// 名字对不上时给出可用清单，而不是静默成功。
#[tokio::test]
async fn restore_rejects_unknown_seed() {
    let ctx = common::setup().await;
    let error = seed::restore(
        &ctx.state.pool,
        &ctx.state.config.plugins_dir(),
        Some("no-such-skill"),
    )
    .await
    .expect_err("未知名字应报错");

    assert!(error.contains("trip-plan"), "错误里要列出可用的: {error}");
}

#[tokio::test]
async fn outdated_seed_is_upgraded_on_start() {
    let ctx = common::setup().await;

    // 模拟"应用升级前装的是旧版本"：插件记录与播种记录一起改低。
    // 版本号走 SQL 直改，是因为对外没有任何"降级"接口——这正是要测的内部路径。
    for sql in [
        "UPDATE plugins SET version = '0.0.1' WHERE id = ?",
        "UPDATE plugin_seeds SET version = '0.0.1' WHERE name = ?",
    ] {
        sqlx::query(sql)
            .bind(TRIP_ID)
            .execute(&ctx.state.pool)
            .await
            .expect("改写版本失败");
    }

    let installed = seed::ensure(&ctx.state.pool, &ctx.state.config.plugins_dir())
        .await
        .expect("播种失败");
    assert_eq!(installed, 1, "旧版本应被补装");

    let version: String = sqlx::query_scalar("SELECT version FROM plugins WHERE id = ?")
        .bind(TRIP_ID)
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询插件版本失败");
    assert_eq!(version, "0.3.0", "应升到应用内置的版本");
}
