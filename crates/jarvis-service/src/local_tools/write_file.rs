//! `write_file`：会话里真正把文件写到磁盘。
//!
//! 两条落点由装配方决定：会话绑了项目就写项目根，没绑就写草稿目录。
//! 两种情形共用 [`ProjectRoot::resolve_new`] 的准入，不另开一套规则。
//!
//! 覆盖策略是"两阶段"：
//!
//! - 目标不存在 → 直接原子写入，回执给路径与大小；
//! - 目标已存在 → 把待写内容落一条 `pending`，回执说"已请求确认"，
//!   由用户在卡片上确认后，另一个端点完成覆盖。
//!
//! 为什么不在这里挂起等确认：对话流挂起要处理断线、超时、重启三件事，
//! 而"用户确认后写这份内容"本身没有任何不确定性——内容已经在手上了。
//! 落库后由独立端点执行，链路短得多，失败面也小得多。

use std::sync::Arc;

use sqlx::SqlitePool;

use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::config::Config;
use crate::local_tools::{fail, format_size};
use crate::write_store::{self, PendingWrite, WriteScope};

/// 生成一个文件。
#[derive(Debug)]
pub(crate) struct WriteFileTool {
    pool: SqlitePool,
    config: Arc<Config>,
    conversation_id: String,
    /// 本轮回答的消息 id：待确认记录挂在它下面，卡片才能随历史消息回看。
    message_id: String,
    /// 写项目根还是草稿目录，由装配方按会话是否绑定项目决定。
    scope: WriteScope,
}

impl WriteFileTool {
    pub(crate) fn new(
        pool: SqlitePool,
        config: Arc<Config>,
        conversation_id: impl Into<String>,
        message_id: impl Into<String>,
        scope: WriteScope,
    ) -> Self {
        Self {
            pool,
            config,
            conversation_id: conversation_id.into(),
            message_id: message_id.into(),
            scope,
        }
    }

    /// 解析参数。只接受 `path` 与 `content` 两个键。
    fn parse(&self, arguments: &str) -> Result<(String, String), String> {
        let value: serde_json::Value =
            serde_json::from_str(arguments).map_err(|err| format!("不是合法 JSON（{err}）"))?;

        let path = value
            .get("path")
            .and_then(|item| item.as_str())
            .map(str::trim)
            .filter(|path| !path.is_empty())
            .ok_or_else(|| "缺少 path（要写到项目或草稿里的相对路径）".to_string())?
            .to_string();

        let content = value
            .get("content")
            .and_then(|item| item.as_str())
            .ok_or_else(|| "缺少 content（完整文件内容）".to_string())?
            .to_string();

        if content.trim().is_empty() {
            return Err("content 是空的，没有可写入的内容".to_string());
        }
        if content.len() > write_store::MAX_WRITE_BYTES {
            return Err(format!(
                "内容太大（{}，上限 {}）：请拆成多个文件，或先写骨架再补内容",
                format_size(content.len() as u64),
                format_size(write_store::MAX_WRITE_BYTES as u64)
            ));
        }

        Ok((path, content))
    }

    /// 写入回执里的位置说明。草稿要明说"不在任何项目里"，
    /// 否则用户会去项目目录里找一个根本不存在的文件。
    fn location_label(&self, relative: &str) -> String {
        match self.scope {
            WriteScope::Project => format!("项目内相对路径：{relative}"),
            WriteScope::Draft => {
                format!(
                    "会话草稿路径：{relative}（这个会话没有绑定项目，文件存在服务端草稿目录里）"
                )
            }
        }
    }

    fn written_card(&self, request: &write_store::WriteRequest) -> crate::chat::LocalToolOutcome {
        LocalToolOutcome {
            content: String::new(),
            sources: Vec::new(),
            ok: true,
            target: String::new(),
            ui: Vec::new(),
        }
        .with_card(crate::chat::ChatUiAction::FileWrite {
            write: Box::new(protocol::FileWrite {
                request_id: request.id.clone(),
                path: request.path.clone(),
                scope: request.scope.clone(),
                status: request.status.clone(),
                bytes: request.bytes,
                existing_bytes: request.existing_bytes,
                backup_path: request.backup_path.clone(),
                // 只有待确认的请求才有"过期"这回事；已写入的卡片给 `None`，
                // 否则客户端会把它当成一张已经失效的卡。
                expires_at: (request.status == write_store::STATUS_PENDING)
                    .then_some(request.expires_at),
                created_at: request.created_at,
            }),
        })
    }
}

#[async_trait::async_trait]
impl LocalTool for WriteFileTool {
    fn spec(&self) -> ToolSpec {
        ToolSpec::write_file()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let (path, content) = match self.parse(arguments) {
            Ok(parsed) => parsed,
            Err(reason) => return fail(format!("无法写入：{reason}"), "write_file:invalid".into()),
        };

        let root = match write_store::resolve_root(
            &self.pool,
            &self.config,
            &self.conversation_id,
            self.scope,
        )
        .await
        {
            Ok(root) => root,
            Err(err) => {
                return fail(
                    format!("无法写入：{err}"),
                    format!("write_file:{path}:root"),
                )
            }
        };

        let target = match root.resolve_new(&path) {
            Ok(target) => target,
            Err(error) => {
                return crate::local_tools::refused(&error, &format!("write_file:{path}:denied"))
            }
        };

        let relative = target.relative.clone();
        let audit_target = format!("write_file:{relative}");

        // 请求路径与最终落点不一致 = 开头的项目名被剥掉了。回执要说清，
        // 否则模型会以为自己写进了 `项目名/` 子目录，下一轮继续带前缀。
        let stripped_note = if normalized_request(&path) != relative {
            format!(
                "\n（路径开头的项目名「{}」已自动忽略：文件就在项目根下，实际路径是 {relative}）",
                root.root_label()
            )
        } else {
            String::new()
        };

        if !target.exists {
            return match write_store::atomic_write(&target.abs, &content).await {
                Ok(()) => {
                    let receipt = format!(
                        "已写入 {relative}（{}，{} 行）。\n{}{stripped_note}",
                        format_size(content.len() as u64),
                        content.lines().count(),
                        self.location_label(&relative)
                    );

                    // 新建是终态：一次 INSERT 就写 `written`，正文不入库
                    // （文件已经在盘上），只留一条卡片记录。
                    let request = match write_store::create_pending(
                        &self.pool,
                        PendingWrite {
                            conversation_id: &self.conversation_id,
                            message_id: Some(&self.message_id),
                            scope: self.scope,
                            path: &relative,
                            content: &content,
                            existing_bytes: 0,
                            status: write_store::STATUS_WRITTEN,
                            expires_at: 0,
                        },
                    )
                    .await
                    {
                        Ok(request) => request,
                        Err(err) => {
                            // 文件确实写成了：以事实为准报成功，只说明卡片没记上。
                            // 报失败会让模型重试，而重试必然撞上"目标已存在"，
                            // 用户会莫名其妙收到一张覆盖确认卡。
                            return LocalToolOutcome {
                                content: format!(
                                    "{receipt}\n（卡片记录失败，不影响文件本身：{err}）"
                                ),
                                sources: Vec::new(),
                                ok: true,
                                target: audit_target,
                                ui: Vec::new(),
                            };
                        }
                    };

                    let mut outcome = self.written_card(&request);
                    outcome.content = receipt;
                    outcome.target = audit_target;
                    outcome
                }
                Err(err) => fail(format!("写入 {relative} 失败：{err}"), audit_target),
            };
        }

        // 目标已存在：不覆盖，先挂一条待确认请求。
        let existing_bytes = match tokio::fs::metadata(&target.abs).await {
            Ok(meta) => meta.len() as i64,
            Err(err) => {
                return fail(
                    format!("无法读取 {relative} 的当前大小：{err}"),
                    audit_target,
                )
            }
        };

        let expires_at = crate::clock::now_ms() + self.config.approval_ttl_ms;

        let request = match write_store::create_pending(
            &self.pool,
            PendingWrite {
                conversation_id: &self.conversation_id,
                message_id: Some(&self.message_id),
                scope: self.scope,
                path: &relative,
                content: &content,
                existing_bytes,
                status: write_store::STATUS_PENDING,
                expires_at,
            },
        )
        .await
        {
            Ok(request) => request,
            Err(err) => return fail(format!("无法记录覆盖请求：{err}"), audit_target),
        };

        let mut outcome = self.written_card(&request);
        outcome.content = format!(
            "{relative} 已存在（{}），这次要写入 {}。\n\
             已请求用户确认覆盖，卡片就在回答下面。\n\
             不要重复调用这个工具，也不要声称已经覆盖；等用户决定后由系统执行。\n\
             {}{stripped_note}",
            format_size(existing_bytes.max(0) as u64),
            format_size(content.len() as u64),
            self.location_label(&relative)
        );
        outcome.target = audit_target;
        outcome
    }
}

/// 把模型给的路径压成便于比较的形式：统一分隔符，去掉开头的 `./` 与多余斜杠。
///
/// 只用来判断"最终落点与请求是否不同"，不参与准入——准入是 `resolve_new` 的事。
fn normalized_request(raw: &str) -> String {
    let mut value = raw.trim().replace('\\', "/");
    while let Some(rest) = value.strip_prefix("./") {
        value = rest.to_string();
    }
    value.trim_matches('/').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(scope: WriteScope, message_id: &str) -> WriteFileTool {
        // 单测只跑参数解析与文案，不碰数据库与磁盘。
        let config = Config {
            data_dir: std::env::temp_dir(),
            ..Config::default()
        };
        let pool = SqlitePool::connect_lazy("sqlite::memory:").expect("惰性连接应成功");

        WriteFileTool::new(pool, Arc::new(config), "conv_test", message_id, scope)
    }

    #[tokio::test]
    async fn rejects_missing_and_oversized_content() {
        let tool = tool(WriteScope::Draft, "msg_1");

        assert!(tool.parse("{}").is_err());
        assert!(tool.parse(r#"{"path":"a.html"}"#).is_err());
        assert!(tool.parse(r#"{"path":"a.html","content":"   "}"#).is_err());
        assert!(tool.parse(r#"{"path":"","content":"x"}"#).is_err());
        assert!(tool.parse("not-json").is_err());

        let huge = "x".repeat(write_store::MAX_WRITE_BYTES + 1);
        let arguments = serde_json::json!({ "path": "a.html", "content": huge }).to_string();
        assert!(tool.parse(&arguments).is_err());
    }

    #[tokio::test]
    async fn parses_normal_arguments_and_keeps_content_verbatim() {
        let tool = tool(WriteScope::Draft, "msg_1");
        let (path, content) = tool
            .parse(r#"{"path":"prototypes/calc.html","content":"<h1>1+1</h1>"}"#)
            .expect("应通过");

        assert_eq!(path, "prototypes/calc.html");
        assert_eq!(content, "<h1>1+1</h1>");
    }

    #[tokio::test]
    async fn draft_location_is_spelled_out() {
        let draft = tool(WriteScope::Draft, "msg_1").location_label("calc.html");
        assert!(draft.contains("草稿"), "{draft}");
        assert!(draft.contains("没有绑定项目"), "{draft}");

        let project = tool(WriteScope::Project, "msg_1").location_label("calc.html");
        assert!(project.contains("项目内相对路径"), "{project}");
    }

    /// 真实的 sqlite + 临时数据目录：落盘与待确认都要真跑一遍。
    async fn tool_ctx(scope: WriteScope, tag: &str) -> (WriteFileTool, Config, sqlx::SqlitePool) {
        let dir = std::env::temp_dir().join(format!("pa-write-tool-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        let config = Config {
            data_dir: dir,
            ..Config::default()
        };
        let pool = crate::db::connect(&config.db_path())
            .await
            .expect("打开数据库失败");
        crate::db::migrate(&pool).await.expect("迁移失败");

        let tool = WriteFileTool::new(
            pool.clone(),
            Arc::new(config.clone()),
            "conv_test",
            "msg_1",
            scope,
        );

        (tool, config, pool)
    }

    #[tokio::test]
    async fn writes_new_file_into_draft() {
        let (tool, config, pool) = tool_ctx(WriteScope::Draft, "draft-new").await;
        let outcome = tool
            .call(r#"{"path":"prototypes/calc.html","content":"<h1>1+1</h1>"}"#)
            .await;

        assert!(outcome.ok, "{}", outcome.content);
        assert!(
            outcome.content.contains("prototypes/calc.html"),
            "{}",
            outcome.content
        );

        let path = config
            .drafts_dir()
            .join("conv_test")
            .join("prototypes")
            .join("calc.html");
        assert_eq!(
            tokio::fs::read_to_string(&path)
                .await
                .expect("文件应已写入"),
            "<h1>1+1</h1>"
        );

        assert_eq!(outcome.ui.len(), 1);
        match &outcome.ui[0] {
            crate::chat::ChatUiAction::FileWrite { write } => {
                assert_eq!(write.status, write_store::STATUS_WRITTEN);
                assert_eq!(write.path, "prototypes/calc.html");
                assert_eq!(write.scope, "draft");
                assert!(write.expires_at.is_none(), "已写入的卡片不该带过期时间");
            }
            other => panic!("期望文件卡片，得到 {other:?}"),
        }

        // 终态记录一次写到 written，且不留正文：文件已经在盘上了。
        let (status, content, bytes): (String, String, i64) =
            sqlx::query_as("SELECT status, content, bytes FROM file_write_requests WHERE path = ?")
                .bind("prototypes/calc.html")
                .fetch_one(&pool)
                .await
                .expect("应有卡片记录");
        assert_eq!(status, write_store::STATUS_WRITTEN);
        assert!(content.is_empty(), "终态不该在库里留文件全文");
        assert_eq!(bytes as usize, "<h1>1+1</h1>".len());
    }

    #[tokio::test]
    async fn existing_file_becomes_pending_without_touching_disk() {
        let (tool, config, pool) = tool_ctx(WriteScope::Draft, "draft-pending").await;

        let first = tool.call(r#"{"path":"index.html","content":"old"}"#).await;
        assert!(first.ok, "{}", first.content);

        let second = tool.call(r#"{"path":"index.html","content":"new"}"#).await;
        assert!(second.ok, "{}", second.content);
        assert!(
            second.content.contains("已请求用户确认"),
            "回执要说明在等确认：{}",
            second.content
        );

        // 覆盖必须真的没发生：用户还没点。
        let path = config.drafts_dir().join("conv_test").join("index.html");
        assert_eq!(
            tokio::fs::read_to_string(&path)
                .await
                .expect("原文件应还在"),
            "old"
        );

        let (pending,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM file_write_requests WHERE status = 'pending'")
                .fetch_one(&pool)
                .await
                .expect("查询待确认失败");
        assert_eq!(pending, 1, "应当留下一条待确认请求");

        match &second.ui[0] {
            crate::chat::ChatUiAction::FileWrite { write } => {
                assert_eq!(write.status, write_store::STATUS_PENDING);
                assert!(write.expires_at.is_some(), "待确认要带有效期");
            }
            other => panic!("期望文件卡片，得到 {other:?}"),
        }
    }

    #[tokio::test]
    async fn strips_redundant_root_name_prefix_and_says_so() {
        let (tool, config, _pool) = tool_ctx(WriteScope::Draft, "draft-prefix").await;

        // 草稿根名是 `conv_test`：模型把它当第一层目录时（`list_dir` 的根标签
        // 就长这样），要剥掉，而不是在草稿里再建一层同名目录。
        let outcome = tool
            .call(r#"{"path":"conv_test/calc.html","content":"<h1/>"}"#)
            .await;

        assert!(outcome.ok, "{}", outcome.content);
        assert!(
            outcome.content.contains("已自动忽略"),
            "回执要说清路径被剥过，否则模型下一轮还会带前缀：{}",
            outcome.content
        );

        let root = config.drafts_dir().join("conv_test");
        assert!(root.join("calc.html").is_file(), "文件应落在草稿根下");
        assert!(
            !root.join("conv_test").exists(),
            "不该多出一层与根同名的目录"
        );
    }

    #[tokio::test]
    async fn refuses_paths_outside_the_root() {
        let (tool, _config, _pool) = tool_ctx(WriteScope::Draft, "draft-deny").await;

        for arguments in [
            r#"{"path":"../evil.html","content":"x"}"#,
            r#"{"path":"/tmp/evil.html","content":"x"}"#,
            r#"{"path":".env","content":"x"}"#,
            r#"{"path":"sub/.git/config","content":"x"}"#,
        ] {
            let outcome = tool.call(arguments).await;
            assert!(!outcome.ok, "{arguments} 必须被拒绝");
            assert!(outcome.ui.is_empty(), "{arguments} 不该产出卡片");
        }
    }
}
