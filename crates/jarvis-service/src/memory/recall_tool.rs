//! `memory_recall`：模型主动检索本地记忆的进程内工具。
//!
//! 分工：`retrieve` 负责打分，这里只负责**参数校验 + 渲染回填文本 + 产出来源**。
//! 不自己打分，也不改记忆状态——工具调用不该有副作用（除了一条召回日志）。
//!
//! 关键约定：
//! - 结果为空时回填"没有命中"，要求模型明说"我没有相关记忆"，不许编造；
//! - 检索失败也回填一句可读的话并 `ok=false`，**绝不中断整轮回答**；
//! - 产出 `Source::memory`，客户端据此渲染「来自记忆」卡片。

use protocol::MemoryKind;
use sqlx::SqlitePool;

use super::retrieve::{self, RecallHit, RecallQuery, RecallScope};
use super::tokenize;
use crate::chat::{LocalTool, LocalToolOutcome, ToolSpec};
use crate::config::MemoryRecallConfig;
use crate::tool_gateway::Source;

/// 单次回填给模型的记忆条数上限（与 `memory.recall.max_results` 取小）。
const HARD_LIMIT: usize = 8;

#[derive(Debug)]
pub struct MemoryRecallTool<'a> {
    pool: &'a SqlitePool,
    config: &'a MemoryRecallConfig,
    scope: RecallScope,
    conversation_id: Option<String>,
    now: i64,
}

impl<'a> MemoryRecallTool<'a> {
    pub fn new(
        pool: &'a SqlitePool,
        config: &'a MemoryRecallConfig,
        scope: RecallScope,
        conversation_id: Option<String>,
    ) -> Self {
        Self {
            pool,
            config,
            scope,
            conversation_id,
            now: crate::clock::now_ms(),
        }
    }
}

#[async_trait::async_trait]
impl LocalTool for MemoryRecallTool<'_> {
    fn spec(&self) -> ToolSpec {
        ToolSpec::memory_recall()
    }

    async fn call(&self, arguments: &str) -> LocalToolOutcome {
        let parsed = match parse_arguments(arguments, self.scope.is_code()) {
            Ok(parsed) => parsed,
            Err(reason) => {
                return LocalToolOutcome {
                    content: format!("参数不合法：{reason}。请改写 query 后重试一次。"),
                    sources: Vec::new(),
                    ok: false,
                    target: "memory:invalid".to_string(),
                    ui: Vec::new(),
                };
            }
        };

        let limit = parsed
            .limit
            .unwrap_or(self.config.max_results as usize)
            .clamp(1, HARD_LIMIT)
            .min(self.config.max_results.max(1) as usize);

        let query = RecallQuery {
            text: parsed.query,
            scope: self.scope.clone(),
            kinds: parsed.kinds,
            limit,
            now: self.now,
            conversation_id: self.conversation_id.clone(),
            message_id: None,
        };

        match retrieve::recall(self.pool, self.config, query.clone()).await {
            Ok(outcome) => {
                let _ = retrieve::log_hits(self.pool, &query, &outcome.hits).await;
                self.audit(
                    &query,
                    &outcome.hits,
                    outcome.fallback_used,
                    outcome.candidates,
                )
                .await;

                let content = render(&outcome.hits, self.config.max_chars);
                let sources = outcome
                    .hits
                    .iter()
                    .map(|hit| Source::memory(hit.memory.id.clone(), hit.memory.created_at))
                    .collect();

                LocalToolOutcome {
                    content,
                    sources,
                    ok: true,
                    // 审计标签只放条数：查询原文属于用户内容，不进日志。
                    target: format!("memory:hits={}", outcome.hits.len()),
                    ui: Vec::new(),
                }
            }
            Err(err) => {
                tracing::warn!(%err, "记忆检索失败");
                LocalToolOutcome {
                    content: "记忆检索失败。请告诉用户你无法核实，不要猜测具体内容。".to_string(),
                    sources: Vec::new(),
                    ok: false,
                    target: "memory:error".to_string(),
                    ui: Vec::new(),
                }
            }
        }
    }
}

impl MemoryRecallTool<'_> {
    async fn audit(
        &self,
        query: &RecallQuery,
        hits: &[RecallHit],
        fallback: bool,
        candidates: usize,
    ) {
        crate::audit::record(
            self.pool,
            &crate::audit::AuditEntry::new("memory", "memory", "memory.recalled", "ok")
                .target("memory")
                .detail(serde_json::json!({
                    "query_chars": query.text.chars().count(),
                    "candidates": candidates,
                    "hits": hits.len(),
                    "fallback_used": fallback,
                    "top_score": hits.first().map(|hit| f64::from(hit.score.total)),
                })),
        )
        .await;
    }
}

/// 回填文本：编号 + 正文 + 类型/来源/时间，末尾附使用约束。
fn render(hits: &[RecallHit], max_chars: usize) -> String {
    if hits.is_empty() {
        return "没有命中任何记忆。\n\n\
                不要编造具体内容；请明确告诉用户\"我没有相关记忆\"。"
            .to_string();
    }

    let mut text = format!("命中 {} 条（按相关度）：\n", hits.len());
    for (index, hit) in hits.iter().enumerate() {
        let memory = &hit.memory;
        let line = format!(
            "[m{}] {}（{} · {} {}）\n",
            index + 1,
            memory.content,
            memory.kind.as_str(),
            memory.source.as_str(),
            crate::clock::format_date_ms(memory.created_at),
        );
        if text.chars().count() + line.chars().count() > max_chars {
            break;
        }
        text.push_str(&line);
    }

    text.push_str(
        "\n只使用与问题直接相关的条目；不要复述整个列表；\
         没有命中时必须说\"我没有相关记忆\"。",
    );
    text
}

struct ParsedArguments {
    query: String,
    kinds: Vec<MemoryKind>,
    limit: Option<usize>,
}

fn parse_arguments(raw: &str, code_scope: bool) -> Result<ParsedArguments, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|err| format!("不是合法 JSON（{err}）"))?;

    let query = value["query"]
        .as_str()
        .map(str::trim)
        .filter(|query| !query.is_empty())
        .ok_or_else(|| "缺少 query".to_string())?
        .to_string();

    // 查询串同样要过一遍分词：模型偶尔会把整句问题抄进来。
    if tokenize::match_expression(&query).is_empty() {
        return Err("query 里没有可检索的关键词".to_string());
    }

    let mut kinds: Vec<MemoryKind> = value["kinds"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str())
                .filter_map(MemoryKind::parse)
                .collect()
        })
        .unwrap_or_default();

    // 编码场景强制收窄：模型可以少要，但不能越权要生活类记忆。
    if code_scope {
        kinds.retain(|kind| matches!(kind, MemoryKind::Preference | MemoryKind::Project));
        if kinds.is_empty() {
            kinds = vec![MemoryKind::Preference, MemoryKind::Project];
        }
    }

    Ok(ParsedArguments {
        query,
        kinds,
        limit: value["limit"].as_u64().map(|limit| limit as usize),
    })
}
