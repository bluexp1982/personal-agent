//! 主题包安装与管理端点的集成测试。
//!
//! 只测**跨模块的那部分**：解包、清单校验、落库、`GET /api/themes` 的可见性、
//! 覆盖安装与删除的联动。安全规则（路径穿越、zip 炸弹、符号链接）已在
//! `src/archive.rs` 的单测里覆盖，这里只留一条冒烟。

mod common;

use std::io::{Cursor, Write};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{authed_delete, authed_get, body_json, setup};

/// 造一个 zip。`entries` 是 (路径, 内容)。
fn zip_bytes(entries: &[(&str, &str)]) -> Vec<u8> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (path, content) in entries {
            if path.ends_with('/') {
                writer.add_directory(*path, options).expect("写目录失败");
                continue;
            }
            writer.start_file(*path, options).expect("写条目失败");
            writer.write_all(content.as_bytes()).expect("写内容失败");
        }
        writer.finish().expect("收尾失败");
    }
    buffer.into_inner()
}

fn upload(token: &str, bytes: Vec<u8>) -> Request<Body> {
    Request::post("/api/themes")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/zip")
        .body(Body::from(bytes))
        .expect("构造请求失败")
}

fn remove(token: &str, id: &str) -> Request<Body> {
    authed_delete(&format!("/api/themes/{id}"), token)
}

const NIGHTFALL: &str = r##"{
    "id": "nightfall",
    "name": "夜幕",
    "version": "1.0.0",
    "author": "阿吉",
    "description": "偏冷的深色主题",
    "brightness": "dark",
    "colors": {
        "seed": "#635BFF",
        "text": { "tertiary": "#9A9AA6" },
        "status": { "success": "#4ADE80" },
        "accent": { "project_start": "#635BFF", "ssh_start": "#22D3EE" },
        "surface": { "top_tint": "#635BFF" },
        "icon": { "folder_selected": "#8B84FF" }
    }
}"##;

/// 装得上、能列出、覆盖安装即更新、删除后目录与记录一起消失。
#[tokio::test]
async fn install_then_overwrite_then_remove() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-happy").await;

    let package = zip_bytes(&[("nightfall/theme.json", NIGHTFALL)]);
    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED, "安装应成功");

    let body = body_json(response).await;
    let installed = body["items"]
        .as_array()
        .expect("主题列表应是数组")
        .iter()
        .find(|item| item["id"] == "nightfall")
        .expect("装完应出现在列表里");

    assert_eq!(installed["brightness"], "dark");
    assert_eq!(installed["author"], "阿吉");
    assert_eq!(installed["colors"]["seed"], "#635BFF");
    assert_eq!(installed["colors"]["text"]["tertiary"], "#9A9AA6");
    // 强调色 / 页面渐变必须原样回传：协议里少一个字段，
    // 服务端就会在落盘时把它裁掉，客户端只剩下内置琥珀。
    assert_eq!(
        installed["colors"]["accent"]["project_start"], "#635BFF",
        "accent.project_start 必须透传: {installed:?}"
    );
    assert_eq!(installed["colors"]["surface"]["top_tint"], "#635BFF");
    // 夹具里故意留着已移除的 `icon` 段：旧包要能装，段本身被丢弃。
    assert!(
        installed["colors"].get("icon").is_none(),
        "旧包的 icon 段应被忽略: {installed:?}"
    );
    // 未覆盖的格子不上线缆：客户端靠"没有"来回落到内置派生值。
    assert!(installed["colors"].get("message").is_none());
    assert!(installed["colors"]["status"].get("warning").is_none());
    assert!(installed["colors"]["accent"].get("project_end").is_none());

    // 覆盖安装：同 id 就是同一个主题的新版本。
    let updated = zip_bytes(&[(
        "theme.json",
        r##"{"id":"nightfall","name":"夜幕 2","version":"2.0.0","brightness":"dark"}"##,
    )]);
    let response = ctx.call(upload(&token, updated)).await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let body = body_json(response).await;
    let items = body["items"].as_array().expect("主题列表应是数组");
    let matches: Vec<_> = items
        .iter()
        .filter(|item| item["id"] == "nightfall")
        .collect();
    assert_eq!(matches.len(), 1, "同 id 不该出现两条: {items:?}");
    assert_eq!(matches[0]["name"], "夜幕 2");
    assert_eq!(matches[0]["version"], "2.0.0");

    // 删除：目录与记录一起消失。
    let response = ctx.call(remove(&token, "nightfall")).await;
    assert_eq!(response.status(), StatusCode::OK);

    let body = body_json(response).await;
    assert!(
        !body["items"]
            .as_array()
            .expect("主题列表应是数组")
            .iter()
            .any(|item| item["id"] == "nightfall"),
        "删除后不该再出现在列表里: {body}"
    );

    let dir = ctx.state.config.themes_dir().join("nightfall");
    assert!(!dir.exists(), "删除应清掉安装目录: {}", dir.display());
}

/// 没有 `theme.json` 的包要给出可读原因，并且不残留临时目录。
#[tokio::test]
async fn package_without_manifest_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-no-manifest").await;

    let response = ctx
        .call(upload(&token, zip_bytes(&[("README.md", "只有说明")])))
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let body = body_json(response).await;
    assert_eq!(body["code"], "theme_invalid");
    assert!(
        !body["retryable"].as_bool().unwrap_or(true),
        "改包才能过，不该给重试"
    );

    let leftovers: Vec<_> = std::fs::read_dir(ctx.state.config.theme_tmp_dir())
        .map(|entries| entries.flatten().collect())
        .unwrap_or_default();
    assert!(
        leftovers.is_empty(),
        "失败安装不能留下临时目录: {leftovers:?}"
    );
}

/// 内置主题的代号不能当包 id：客户端把它们当"内置主题"的代号持久化。
#[tokio::test]
async fn reserved_id_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-reserved").await;

    for id in ["light", "dark", "system", "custom"] {
        let manifest =
            format!(r##"{{"id":"{id}","name":"冒名","version":"1.0.0","brightness":"light"}}"##);
        let package = zip_bytes(&[("theme.json", manifest.as_str())]);
        let response = ctx.call(upload(&token, package)).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "应拒绝 id={id}");
    }
}

/// 颜色必须是 `#RRGGBB` 或 `#AARRGGBB`，否则整包被拒（而不是静默忽略这一格）。
#[tokio::test]
async fn malformed_color_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-bad-color").await;

    let package = zip_bytes(&[(
        "theme.json",
        r##"{"id":"x","name":"X","version":"1","brightness":"light","colors":{"seed":"blue"}}"##,
    )]);
    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let body = body_json(response).await;
    assert_eq!(body["code"], "theme_invalid");
}

/// zip slip：路径穿越的条目要被挡在写盘之前。
#[tokio::test]
async fn path_traversal_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-slip").await;

    let package = zip_bytes(&[("../escaped.txt", "boom"), ("theme.json", NIGHTFALL)]);
    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let escaped = ctx.state.config.data_dir.join("escaped.txt");
    assert!(!escaped.exists(), "不能写到数据目录之外");
}

/// Finder 的「压缩」会带出 `__MACOSX/` 与 `._*`：既不能落盘，也不能破坏剥壳判断。
#[tokio::test]
async fn finder_zip_with_appledouble_is_accepted() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-finder").await;

    let package = zip_bytes(&[
        ("nightfall/", ""),
        ("nightfall/theme.json", NIGHTFALL),
        ("__MACOSX/._nightfall", "junk"),
        ("__MACOSX/nightfall/._theme.json", "junk"),
    ]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "Finder 压缩的包应能安装"
    );

    let dir = ctx.state.config.themes_dir().join("nightfall");
    assert!(dir.join("theme.json").is_file(), "{}", dir.display());
    assert!(
        !dir.join("__MACOSX").exists(),
        "__MACOSX 不该被解包: {}",
        dir.display()
    );
}

/// 删除不存在的主题返回 404，而不是静默成功。
#[tokio::test]
async fn removing_unknown_theme_is_not_found() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-missing").await;

    let response = ctx.call(remove(&token, "nope")).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    let body = body_json(response).await;
    assert_eq!(body["code"], "theme_not_found");
}

/// `scheme` 组是"底和线"：装机后必须原样出现在列表里。
///
/// 客户端靠它把整站做成纯黑（终端仿真主题），服务端一个字段都不能吞。
#[tokio::test]
async fn scheme_group_roundtrips_through_api() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-scheme").await;

    let package = zip_bytes(&[(
        "theme.json",
        r##"{
            "id": "homebrew-terminal",
            "name": "Homebrew Terminal",
            "version": "1.0.0",
            "brightness": "dark",
            "colors": {
                "scheme": {
                    "primary": "#00A600",
                    "on_primary": "#000000",
                    "surface": "#000000",
                    "surface_container_highest": "#181818",
                    "on_surface": "#E5E5E5",
                    "outline_variant": "#2B2B2B"
                }
            }
        }"##,
    )]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let body = body_json(response).await;
    let scheme = &body["items"][0]["colors"]["scheme"];
    assert_eq!(scheme["surface"], "#000000");
    assert_eq!(scheme["on_surface"], "#E5E5E5");
    assert_eq!(scheme["primary"], "#00A600");
    assert_eq!(scheme["surface_container_highest"], "#181818");
    assert!(scheme.get("secondary").is_none(), "未覆盖的角色不应出现");
}

/// 列表是空的时候也要 200 + 空数组，客户端据此显示空态。
#[tokio::test]
async fn empty_list_is_ok() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("themes-empty").await;

    let body = body_json(ctx.call(authed_get("/api/themes", &token)).await).await;
    assert_eq!(body["items"].as_array().map(Vec::len), Some(0));
}
