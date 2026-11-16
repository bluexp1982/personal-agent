//! `preview_url`：请客户端打开一个东西给人看。
//!
//! 三种输入**三选一**，准入各不相同，不要"统一"成一套：
//!
//! - `url`：与 `web_fetch` 正好相反，这里允许本机与内网（用户自己的 dev server
//!   是主要用途），只拒绝非 http(s) 的 scheme 与带账号密码的地址；
//! - `path`：项目里的 html，走 [`ProjectRoot`] 准入（越界、敏感名、软链接）；
//! - `run`：项目声明的运行目标，端口来自 `.jarvis/run.json`。
//!
//! 后两种的共同点：**地址由服务端拼，模型只说"看哪个"**。端口与访问令牌
//! 都不进模型参数——否则一次提示注入就能把用户的浏览器导到本机任意服务上。
//!
//! 真正危险的是 `file:` 与 `javascript:`：前者能绕过路径准入把任意本地文件
//! 喂给 WebView，后者是注入。这两个一律拒绝。

use std::str::FromStr;
use std::sync::Arc;

use crate::chat::{ChatUiAction, LocalTool, LocalToolOutcome, ToolSpec};
use crate::local_tools::fail;
use crate::local_tools::path_guard::ProjectRoot;
use crate::web_preview::{self, WebPreview};

/// 地址长度上限。正常 URL 远小于这个数，超长基本是模型把正文塞进来了。
const MAX_URL_CHARS: usize = 2048;

/// 标签标题上限：它会出现在标签栏上，过长会被截断成省略号。
const MAX_TITLE_CHARS: usize = 80;

/// 文件路径长度上限。项目内路径远超不了这个数。
const MAX_PATH_CHARS: usize = 512;

/// 草稿文件的上下文：没有绑定项目的会话靠它打开自己生成的文件。
#[derive(Debug, Clone)]
pub(crate) struct DraftScope {
    pub(crate) conversation_id: String,
    pub(crate) config: Arc<crate::config::Config>,
}

#[derive(Debug)]
pub(crate) struct PreviewUrlTool {
    /// 有项目才有"打开项目文件 / 运行目标"的能力。
    root: Option<ProjectRoot>,
    /// 预览站句柄。`None` 表示它没起来（启动失败），此时只剩 `url` 可用。
    preview: Option<Arc<WebPreview>>,
    /// 会话所属项目 id：文件地址与代理地址都要带上它。
    project_id: Option<String>,
    /// 没有项目时，`path` 退到会话草稿目录。
    draft: Option<DraftScope>,
}

impl PreviewUrlTool {
    pub(crate) fn new(
        root: Option<ProjectRoot>,
        preview: Option<Arc<WebPreview>>,
        project_id: Option<String>,
    ) -> Self {
        Self {
            root,
            preview,
            project_id,
            draft: None,
        }
    }

    /// 允许打开会话草稿里的文件。
    ///
    /// 只给没有项目的会话配：有项目时 `path` 的含义必须唯一，
    /// 否则模型说不清"看哪个 index.html"，用户也分不清打开的是哪个。
    #[must_use]
    pub(crate) fn with_draft(mut self, draft: DraftScope) -> Self {
        self.draft = Some(draft);
        self
    }
}

#[async_trait::async_trait]
impl LocalTool for PreviewUrlTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::preview_url()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let args = match parse(arguments) {
            Ok(args) => args,
            Err(reason) => {
                return fail(
                    format!(
                        "参数不合法：{reason}。url / path / run 三选一：\
                         现成地址给 url，项目里的网页给 path，运行中的项目给 run=true。"
                    ),
                    "preview_url:invalid".to_string(),
                );
            }
        };

        match args.target {
            Target::Url(url) => self.open_url(url, args.title),
            Target::Path(path) => self.open_path(&path, args.title),
            Target::Run => self.open_run(args.title),
        }
    }
}

impl PreviewUrlTool {
    /// 打开一个现成的 http(s) 地址。
    fn open_url(&self, raw: String, title: Option<String>) -> LocalToolOutcome {
        let parsed = match reqwest::Url::from_str(&raw) {
            Ok(url) => url,
            Err(err) => {
                return fail(
                    format!("{raw} 不是合法地址（{err}）"),
                    "preview_url:invalid".to_string(),
                );
            }
        };

        if !matches!(parsed.scheme(), "http" | "https") {
            return fail(
                format!(
                    "只允许打开 http/https 地址，收到的是 {}://。本机文件与脚本地址一律不放行。",
                    parsed.scheme()
                ),
                "preview_url:denied".to_string(),
            );
        }

        if parsed.host_str().is_none() {
            return fail(
                format!("{raw} 缺少主机名"),
                "preview_url:invalid".to_string(),
            );
        }

        if !parsed.username().is_empty() || parsed.password().is_some() {
            return fail(
                "地址里不要带账号密码：浏览器面板会把它记进历史".to_string(),
                "preview_url:denied".to_string(),
            );
        }

        let url = parsed.to_string();
        LocalToolOutcome {
            content: format!(
                "已请客户端在浏览器面板打开 {url}。\n\
                 我看不到页面内容，也无法确认它是否加载成功：\
                 要读页面正文请用 web_fetch，要确认效果请让用户看一眼。"
            ),
            // 打开页面不是"引用来源"，不产出 source 卡片。
            sources: Vec::new(),
            ok: true,
            target: format!("url:{url}"),
            ui: vec![ChatUiAction::OpenUrl {
                url,
                title,
                display: None,
            }],
        }
    }

    /// 打开项目里（或会话草稿里）的 html。
    fn open_path(&self, path: &str, title: Option<String>) -> LocalToolOutcome {
        // 有项目按项目解析，没有项目退到草稿目录：两者的准入与入口白名单
        // 完全一致（都走 `ProjectRoot::file`），差别只在根从哪来。
        let target = if let Some((root, preview, project_id)) = self.context() {
            // 准入、入口白名单、地址拼接都在 `file_target`：会话工具与会话外的
            // 右键菜单必须走同一条路，否则两处规则迟早分叉。
            match web_preview::file_target(preview, root, project_id, path) {
                Ok(target) => target,
                Err(web_preview::TargetError::Denied(reason)) => {
                    return fail(
                        format!("{reason}。项目之外的文件我打不开，也不该打开。"),
                        format!("preview_url:path:{path}:denied"),
                    );
                }
                Err(web_preview::TargetError::Invalid(reason)) => {
                    return fail(
                        format!("{reason}。请确认路径相对项目根、且确实是 html/htm。"),
                        format!("preview_url:path:{path}:invalid"),
                    );
                }
            }
        } else if let (Some(draft), Some(preview)) = (&self.draft, self.preview.as_ref()) {
            match web_preview::draft_target(preview, &draft.config, &draft.conversation_id, path) {
                Ok(target) => target,
                Err(web_preview::TargetError::Denied(reason)) => {
                    return fail(
                        format!("{reason}。草稿目录之外的文件我打不开，也不该打开。"),
                        format!("preview_url:path:{path}:denied"),
                    );
                }
                Err(web_preview::TargetError::Invalid(reason)) => {
                    return fail(
                        format!("{reason}。请确认这个文件已经在会话草稿里，且确实是 html/htm。"),
                        format!("preview_url:path:{path}:invalid"),
                    );
                }
            }
        } else {
            return self.context_failure();
        };

        let name = target
            .relative
            .rsplit('/')
            .next()
            .unwrap_or(&target.relative)
            .to_string();

        LocalToolOutcome {
            content: format!(
                "已请客户端打开项目文件 {}。\n\
                 我看不到页面内容，也无法确认它是否加载成功：\
                 要读正文请用 read_file，要确认效果请让用户看一眼。\n\
                 页面里引用的同目录资源（css/js/图片）会一起加载；\
                 需要调用后端接口的页面请用 run=true 打开运行目标。",
                target.relative
            ),
            sources: Vec::new(),
            ok: true,
            target: format!("file:{}", target.relative),
            ui: vec![ChatUiAction::OpenUrl {
                url: target.url,
                title: title.or(Some(name)),
                display: Some(target.display),
            }],
        }
    }

    /// 打开项目声明的运行目标。
    fn open_run(&self, title: Option<String>) -> LocalToolOutcome {
        let Some((root, preview, project_id)) = self.context() else {
            return self.context_failure();
        };

        // 提前判一次存在性：让模型拿到"该建哪个文件"的明确指示，
        // 而不是打开一个只有 502 的标签页再让用户自己猜。
        let config = root.root().join(".jarvis").join("run.json");
        if !config.is_file() {
            return fail(
                format!(
                    "项目里没有 {}，不知道要打开哪个端口。\
                     请让用户或编码任务建一份，内容形如 \
                     {{\"frontend\":3001,\"backend\":8081,\"api_prefix\":\"/api\"}}。",
                    web_preview::run_config_path()
                ),
                "preview_url:run:no_config".to_string(),
            );
        }

        let url = preview.run_url(project_id);
        let label = format!("{}/", root.root_label());

        LocalToolOutcome {
            content: format!(
                "已请客户端打开项目的运行目标 {label}。\n\
                 页面里的 /api 请求会由服务端转给后端；我只负责打开，\
                 看不到页面内容，也确认不了前后端是否都起来了——\
                 打不开时页面上会显示具体原因。"
            ),
            sources: Vec::new(),
            ok: true,
            target: format!("run:{label}"),
            ui: vec![ChatUiAction::OpenUrl {
                url,
                title,
                display: Some(label),
            }],
        }
    }

    /// 文件预览与运行目标都要求"有项目 + 预览站已启动"。
    fn context(&self) -> Option<(&ProjectRoot, &Arc<WebPreview>, &str)> {
        Some((
            self.root.as_ref()?,
            self.preview.as_ref()?,
            self.project_id.as_deref()?,
        ))
    }

    /// 缺上下文时给出能照做的一句话，而不是一句"失败"。
    fn context_failure(&self) -> LocalToolOutcome {
        let reason = if self.root.is_none() && self.draft.is_none() {
            "当前会话没有绑定项目，打不开项目里的文件或运行目标"
        } else if self.preview.is_none() {
            "预览站没有启动（服务端启动时失败了），文件与运行目标暂时打不开"
        } else {
            "会话草稿里还没有这个文件：先用 write_file 生成，再打开"
        };
        fail(reason.to_string(), "preview_url:unavailable".to_string())
    }
}

enum Target {
    Url(String),
    Path(String),
    Run,
}

struct Args {
    target: Target,
    title: Option<String>,
}

fn parse(raw: &str) -> Result<Args, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|err| format!("不是合法 JSON（{err}）"))?;

    let url = text_field(&value, "url");
    let path = text_field(&value, "path");
    let run = value["run"].as_bool().unwrap_or(false);

    let chosen = usize::from(url.is_some()) + usize::from(path.is_some()) + usize::from(run);
    if chosen != 1 {
        return Err("url / path / run 必须且只能给一个".to_string());
    }

    let target = if let Some(url) = url {
        if url.chars().count() > MAX_URL_CHARS {
            return Err(format!("地址超过 {MAX_URL_CHARS} 字符"));
        }
        Target::Url(url)
    } else if let Some(path) = path {
        if path.chars().count() > MAX_PATH_CHARS {
            return Err(format!("路径超过 {MAX_PATH_CHARS} 字符"));
        }
        Target::Path(path)
    } else {
        Target::Run
    };

    let title = value["title"]
        .as_str()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(|title| title.chars().take(MAX_TITLE_CHARS).collect::<String>());

    Ok(Args { target, title })
}

/// 取一个非空文本字段。空白串等同于"没给"：模型经常把可选参数填成 `""`。
fn text_field(value: &serde_json::Value, key: &str) -> Option<String> {
    value[key]
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_non_http_schemes() {
        let tool = PreviewUrlTool::new(None, None, None);

        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,x",
        ] {
            let outcome = tool.call(&format!(r#"{{"url":"{url}"}}"#)).await;
            assert!(!outcome.ok, "{url} 必须拒绝");
            assert!(outcome.ui.is_empty(), "{url} 不应产生打开动作");
            assert!(
                outcome.content.contains("只允许打开 http/https"),
                "{url}: {}",
                outcome.content
            );
        }
    }

    #[tokio::test]
    async fn accepts_local_dev_server_without_display() {
        let tool = PreviewUrlTool::new(None, None, None);
        let outcome = tool
            .call(r#"{"url":"http://localhost:3000/app","title":"本地预览"}"#)
            .await;

        assert!(outcome.ok, "{}", outcome.content);
        assert_eq!(outcome.ui.len(), 1);
        match &outcome.ui[0] {
            ChatUiAction::OpenUrl {
                url,
                title,
                display,
            } => {
                assert_eq!(url, "http://localhost:3000/app");
                assert_eq!(title.as_deref(), Some("本地预览"));
                assert!(
                    display.is_none(),
                    "用户自己给的地址就是可读地址，不需要额外覆盖"
                );
            }
            other => panic!("期望 OpenUrl，得到 {other:?}"),
        }
        assert!(
            outcome.content.contains("看不到页面内容"),
            "必须说明它不返回正文"
        );
    }

    #[tokio::test]
    async fn rejects_credentials_in_url() {
        let tool = PreviewUrlTool::new(None, None, None);
        let outcome = tool
            .call(r#"{"url":"https://user:pass@example.com"}"#)
            .await;
        assert!(!outcome.ok);
        assert!(outcome.content.contains("账号密码"), "{}", outcome.content);
    }

    #[tokio::test]
    async fn file_and_run_need_a_project() {
        let tool = PreviewUrlTool::new(None, None, None);

        for arguments in [r#"{"path":"report.html"}"#, r#"{"run":true}"#] {
            let outcome = tool.call(arguments).await;
            assert!(!outcome.ok, "{arguments} 没有项目时必须失败");
            assert!(outcome.ui.is_empty());
            assert!(
                outcome.content.contains("没有绑定项目"),
                "{arguments}: {}",
                outcome.content
            );
        }
    }

    #[test]
    fn parse_requires_exactly_one_target() {
        assert!(parse("{}").is_err(), "什么都不给必须拒绝");
        assert!(parse(r#"{"url":"  "}"#).is_err(), "空白串等同没给");

        assert!(parse(r#"{"url":"https://a.test","path":"a.html"}"#).is_err());
        assert!(parse(r#"{"path":"a.html","run":true}"#).is_err());
        assert!(
            parse(r#"{"url":"https://a.test","run":true}"#).is_err(),
            "地址与运行目标不能同时给"
        );

        assert!(matches!(
            parse(r#"{"path":"a.html"}"#).expect("单个目标应通过").target,
            Target::Path(path) if path == "a.html"
        ));
        assert!(matches!(
            parse(r#"{"run":true}"#).expect("运行目标应通过").target,
            Target::Run
        ));
    }

    #[test]
    fn parse_caps_title_and_path() {
        let args = parse(&format!(
            r#"{{"path":"a.html","title":"{}"}}"#,
            "标".repeat(MAX_TITLE_CHARS + 10)
        ))
        .expect("应通过");
        assert_eq!(
            args.title.unwrap().chars().count(),
            MAX_TITLE_CHARS,
            "标题应被截断"
        );

        let long = "a".repeat(MAX_PATH_CHARS + 1);
        assert!(
            parse(&format!(r#"{{"path":"{long}"}}"#)).is_err(),
            "超长路径必须拒绝"
        );
    }
}
