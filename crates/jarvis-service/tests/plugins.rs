//! 技能包安装与管理端点的集成测试。
//!
//! 只测**跨模块的那部分**：解包、兼容判定、落库、`/api/skills` 的可见性、
//! 启停与卸载的联动。各模块内部的规则（路径穿越、zip 炸弹、工具映射细节）
//! 已在 `src/plugin/*.rs` 的单测里覆盖，这里不重复。

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
            // 以 `/` 结尾的走目录条目：真实 zip（含 Finder 打的）就是这样标记目录的，
            // 用 `start_file` 造会变成一个空文件，后续解包"建目录"时会撞上它。
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
    Request::post("/api/plugins")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/zip")
        .body(Body::from(bytes))
        .expect("构造请求失败")
}

const GOOD_SKILL: &str =
    "---\nname: weekly-digest\ndescription: 把一周的记录整理成摘要\n---\n## 收集信息\n## 写摘要\n";

/// 规范要求 `name` 与所在目录同名，所以这个包里的技能必须叫 site-brief。
const SITE_BRIEF_SKILL: &str =
    "---\nname: site-brief\ndescription: 读一个网页并摘要\n---\n## 读取\n## 归纳\n";

/// 一条合规技能：装得上、出现在技能列表里、停用后消失、卸载后目录也没了。
#[tokio::test]
async fn install_then_disable_then_remove() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-happy").await;

    let package = zip_bytes(&[
        (
            "plugin.json",
            r#"{"name":"com.example.weekly","version":"1.0.0","description":"周报"}"#,
        ),
        ("skills/weekly-digest/SKILL.md", GOOD_SKILL),
    ]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED, "安装应成功");

    let body = body_json(response).await;
    // 不能取 `items[0]`：种子技能（trip-plan / bill-explain）也在这个列表里，
    // 谁排在前面取决于安装时间，按 id 找才稳定。
    let weekly = body["items"]
        .as_array()
        .expect("插件列表应是数组")
        .iter()
        .find(|item| item["id"] == "com.example.weekly")
        .expect("装完应出现在列表里");
    assert_eq!(weekly["skills"][0]["name"], "weekly-digest");
    assert_eq!(weekly["skills"][0]["status"], "supported");
    assert_eq!(weekly["enabled"], true);

    // worker 没连上时也能看到：插件技能来自库，不依赖执行进程。
    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    assert!(
        skills
            .as_array()
            .expect("技能列表应是数组")
            .iter()
            .any(|skill| skill["name"] == "weekly-digest"),
        "装完应出现在技能列表: {skills}"
    );

    // 停用：技能从候选里消失。
    let response = ctx
        .patch_json(
            "/api/plugins/com.example.weekly",
            &token,
            &serde_json::json!({ "enabled": false }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    assert!(
        !skills
            .as_array()
            .expect("技能列表应是数组")
            .iter()
            .any(|skill| skill["name"] == "weekly-digest"),
        "停用后不该再出现: {skills}"
    );

    // 卸载：目录与记录一起消失。
    let response = ctx
        .call(authed_delete("/api/plugins/com.example.weekly", &token))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let plugins = body_json(ctx.call(authed_get("/api/plugins", &token)).await).await;
    // 列表里还有随应用分发的示例技能，所以不能断言"空了"，
    // 只能断言刚卸载的这条不在了。
    assert!(
        !plugins["items"]
            .as_array()
            .expect("插件列表应是数组")
            .iter()
            .any(|item| item["id"] == "com.example.weekly"),
        "卸载后不该再出现在列表里: {plugins}"
    );

    let path = ctx.state.config.plugins_dir().join("com.example.weekly");
    assert!(!path.exists(), "卸载应删掉安装目录: {}", path.display());
}

/// 依赖 Bash 的技能装得进去，但会被标成不支持，并且**不进技能列表**——
/// 让用户点到一条注定假装成功的技能，比装不上更糟。
#[tokio::test]
async fn shell_dependent_skill_is_hidden_from_skill_list() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-bash").await;

    let package = zip_bytes(&[(
        "SKILL.md",
        "---\nname: pdf-tools\ndescription: 提取 PDF 文本\nallowed-tools: Bash\n---\n运行脚本。\n",
    )]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED, "包本身是合法的");

    let body = body_json(response).await;
    // 同样不能取 `items[0]`：按技能名从全部分组里找。
    let skill = body["items"]
        .as_array()
        .expect("插件列表应是数组")
        .iter()
        .filter_map(|item| item["skills"].as_array())
        .flatten()
        .find(|skill| skill["name"] == "pdf-tools")
        .expect("技能应出现在列表里");
    assert_eq!(skill["status"], "unsupported");
    assert!(
        !skill["reasons"].as_array().expect("应有原因").is_empty(),
        "不支持的技能必须给出原因"
    );

    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    assert!(
        !skills
            .as_array()
            .expect("技能列表应是数组")
            .iter()
            .any(|item| item["name"] == "pdf-tools"),
        "不支持的技能不该出现在技能列表: {skills}"
    );
}

/// 同名技能（与内置的 trip-plan 撞名）必须被拒，且不能残留目录。
#[tokio::test]
async fn duplicate_skill_name_is_rejected_without_leftovers() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-duplicate").await;

    let package = zip_bytes(&[(
        "SKILL.md",
        "---\nname: trip-plan\ndescription: 冒名顶替\n---\n正文\n",
    )]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let body = body_json(response).await;
    assert_eq!(body["code"], "plugin_conflict");

    let tmp = ctx.state.config.plugin_tmp_dir();
    let leftovers: Vec<_> = std::fs::read_dir(&tmp)
        .map(|entries| entries.flatten().collect())
        .unwrap_or_default();
    assert!(
        leftovers.is_empty(),
        "失败安装不能留下临时目录: {leftovers:?}"
    );
}

/// zip slip：路径穿越的条目要被挡在写盘之前。
#[tokio::test]
async fn path_traversal_is_rejected() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-slip").await;

    let package = zip_bytes(&[
        ("../escaped.txt", "boom"),
        ("SKILL.md", "---\nname: demo\ndescription: x\n---\n正文\n"),
    ]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let escaped = ctx.state.config.data_dir.join("escaped.txt");
    assert!(!escaped.exists(), "不能写到数据目录之外");
}

/// Finder 的「压缩」会带出 `__MACOSX/` 与 `._*`，这是 macOS 用户最自然的打包方式。
/// 它们既不能被当成包内容写进安装目录，也不能破坏外层目录的剥壳判断。
#[tokio::test]
async fn finder_zip_with_appledouble_is_accepted() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-finder").await;

    let package = zip_bytes(&[
        ("site-brief/", ""),
        ("__MACOSX/._site-brief", "junk"),
        ("site-brief/SKILL.md", SITE_BRIEF_SKILL),
        ("__MACOSX/site-brief/._SKILL.md", "junk"),
    ]);

    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(
        response.status(),
        StatusCode::CREATED,
        "Finder 压缩的包应能安装"
    );

    let body = body_json(response).await;
    assert_eq!(body["items"][0]["skills"][0]["name"], "site-brief");

    // 垃圾文件不该落进安装目录（单技能包会被装到 `<id>/<version>/SKILL.md`）。
    let dir = ctx
        .state
        .config
        .plugins_dir()
        .join("site-brief")
        .join("0.0.0");
    assert!(dir.join("SKILL.md").is_file(), "{}", dir.display());
    assert!(
        !dir.join("__MACOSX").exists(),
        "__MACOSX 不该被解包: {}",
        dir.display()
    );
}

/// 同一个 id 装第二次要报冲突，而不是静默覆盖。
#[tokio::test]
async fn installing_same_id_twice_is_a_conflict() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-twice").await;

    let package = zip_bytes(&[
        (
            "plugin.json",
            r#"{"name":"com.example.once","version":"1.0.0"}"#,
        ),
        (
            "skills/once/SKILL.md",
            "---\nname: once\ndescription: 一次性\n---\n正文\n",
        ),
    ]);

    let first = ctx.call(upload(&token, package.clone())).await;
    assert_eq!(first.status(), StatusCode::CREATED);

    let second = ctx.call(upload(&token, package)).await;
    assert_eq!(second.status(), StatusCode::CONFLICT);
}

/// worker 只上报了编码技能（插件还没重载）时，插件技能仍要出现在 `/api/skills`。
///
/// 这是真实时序：装完或恢复完插件，worker 的 registry 还是启动那一刻的快照。
/// 列表若只信 registry，`@` 候选会整个空掉——因为前端还会把 `code.exec`
/// 的技能过滤掉，最后一条都不剩。
#[tokio::test]
async fn plugin_skills_stay_visible_when_worker_snapshot_is_stale() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("skills-stale").await;

    let (manifest, _body) = protocol::skill::parse_builtin(
        "---\nname: code-task\nversion: 0.1.0\nrisk_level: irreversible_write\n\
         required_tools:\n  - code.exec\noutputs: [diff]\nsteps:\n  - 执行\n---\n正文\n",
    )
    .expect("构造内置技能清单失败");

    {
        let mut registry = ctx
            .state
            .skills
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        registry.clear();
        registry.push(manifest);
    }

    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    let names: Vec<&str> = skills
        .as_array()
        .expect("技能列表应是数组")
        .iter()
        .filter_map(|skill| skill["name"].as_str())
        .collect();

    assert!(
        names.contains(&"bill-explain"),
        "worker 快照滞后时插件技能也不该消失: {names:?}"
    );
}

/// 停用插件后，即使 worker 还没重载（registry 里仍有该技能），列表也不能再返回它。
///
/// 否则用户看到的是：设置里关了，聊天里还挂着一条没描述、状态写着"可用"的
/// 技能——点下去才失败。停用必须立即生效，不能等执行进程重载。
#[tokio::test]
async fn disabled_plugin_skill_disappears_before_worker_reload() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-disable-stale").await;

    let package = zip_bytes(&[
        (
            "plugin.json",
            r#"{"name":"com.example.stale","version":"1.0.0"}"#,
        ),
        (
            "skills/stale-skill/SKILL.md",
            "---\nname: stale-skill\ndescription: 停用测试\n---\n正文\n",
        ),
    ]);
    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED);

    // 模拟 worker 已加载：registry 里有它，停用不会让它自己消失。
    let (manifest, _) = protocol::skill::parse_builtin(
        "---\nname: stale-skill\nversion: 1.0.0\nrisk_level: read\n\
         outputs: [report]\nsteps:\n  - 执行\n---\n正文\n",
    )
    .expect("构造技能清单失败");
    ctx.state
        .skills
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .push(manifest);

    let response = ctx
        .patch_json(
            "/api/plugins/com.example.stale",
            &token,
            &serde_json::json!({ "enabled": false }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    let names: Vec<&str> = skills
        .as_array()
        .expect("技能列表应是数组")
        .iter()
        .filter_map(|skill| skill["name"].as_str())
        .collect();

    assert!(
        !names.contains(&"stale-skill"),
        "停用后不该残留（registry 还没重载也一样）: {names:?}"
    );
}

/// 卸载插件后同样不能等 worker 重载：registry 里残留的技能要立即消失。
#[tokio::test]
async fn removed_plugin_skill_disappears_before_worker_reload() {
    let ctx = setup().await;
    let (_device, token) = ctx.pair_and_login("plugins-remove-stale").await;

    let package = zip_bytes(&[
        (
            "plugin.json",
            r#"{"name":"com.example.gone","version":"1.0.0"}"#,
        ),
        (
            "skills/gone-skill/SKILL.md",
            "---\nname: gone-skill\ndescription: 卸载测试\n---\n正文\n",
        ),
    ]);
    let response = ctx.call(upload(&token, package)).await;
    assert_eq!(response.status(), StatusCode::CREATED);

    // registry 里的残留技能必须带 `plugin_id`，才认得出"它属于某个已卸载的包"。
    let (mut manifest, _) = protocol::skill::parse_builtin(
        "---\nname: gone-skill\nversion: 1.0.0\nrisk_level: read\n\
         outputs: [report]\nsteps:\n  - 执行\n---\n正文\n",
    )
    .expect("构造技能清单失败");
    manifest.plugin_id = Some("com.example.gone".to_string());
    manifest.source = "third_party".to_string();
    ctx.state
        .skills
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .push(manifest);

    let response = ctx
        .call(authed_delete("/api/plugins/com.example.gone", &token))
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let skills = body_json(ctx.call(authed_get("/api/skills", &token)).await).await;
    let names: Vec<&str> = skills
        .as_array()
        .expect("技能列表应是数组")
        .iter()
        .filter_map(|skill| skill["name"].as_str())
        .collect();

    assert!(
        !names.contains(&"gone-skill"),
        "卸载后不该残留（registry 还没重载也一样）: {names:?}"
    );
}
