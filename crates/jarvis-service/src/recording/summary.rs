//! 录音总结：把转写稿归纳成会议纪要。
//!
//! - 只有录音已结束、全部分段 ready 的录音才会在 [`super::refresh`] 里被置为
//!   `pending`；这里消费 `pending`，失败只影响总结，不影响录音与转写。
//! - 模型沿用 `llm` 配置，不单独持有密钥。
//! - 总结正文落 `recordings.summary`，TTS 音频由 [`super::audio_jobs`] 按需生成。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use sqlx::SqlitePool;
use tokio::sync::Semaphore;

use crate::clock::now_ms;
use crate::config::Config;
use crate::model::CompletionModel;
use protocol::SummaryStyle;

use super::store::RecordingStore;

const MINUTES_SYSTEM_PROMPT: &str =
    "你是会议纪要助手。只依据用户提供的录音转写稿整理，不要补充稿子里没有的事实。\
输出 Markdown，严格使用以下三个二级标题，不要额外开场白：\n\
## 概要\n\
用 2–3 句话说明这段录音在讨论什么。\n\
## 关键要点\n\
用 3–6 条短句列出重要信息、决定和分歧。\n\
## 待办 / 结论\n\
列出明确的待办（谁、做什么、何时）；没有明确待办时写「未提及明确待办」。\
如果转写稿信息不足，在对应小节写「转写稿未提及」，不要编造。";

const BRIEF_SYSTEM_PROMPT: &str =
    "你是录音摘要助手。只依据用户提供的录音转写稿，用 3–5 句话说明这段录音在说什么。\
不要编造稿子里没有的事实，不要列标题，不要逐句复述，控制在约 150–350 字。\
如果转写稿信息不足，直接说明「转写稿信息不足」，不要猜测。";

const DETAILED_SYSTEM_PROMPT: &str =
    "你是录音摘要助手。只依据用户提供的录音转写稿，按讨论话题分段归纳。\
输出 Markdown，每个话题用一个二级标题，例如 `## 话题名`，标题下用 2–4 句话概括该话题。\
不要带时间戳，不要逐句复述原文，不要添加稿子里没有的事实；没有明确话题时按内容自然分段。";

fn system_prompt(style: SummaryStyle) -> &'static str {
    match style {
        SummaryStyle::Minutes => MINUTES_SYSTEM_PROMPT,
        SummaryStyle::Brief => BRIEF_SYSTEM_PROMPT,
        SummaryStyle::Detailed => DETAILED_SYSTEM_PROMPT,
    }
}

#[derive(Debug)]
pub struct SummaryJobs {
    pool: SqlitePool,
    /// 后台队列自己持有一份模型：它没有请求上下文可以借用。
    ///
    /// 用 `RwLock` 是为了切换模型时不用重启服务：下一份待总结的录音就用新模型。
    model: std::sync::RwLock<Option<Arc<dyn CompletionModel>>>,
    /// 写入 `recordings.summary_model` 的模型名，与模型同一个快照更新。
    model_name: std::sync::RwLock<String>,
    slots: Arc<Semaphore>,
    running: Arc<Mutex<HashSet<String>>>,
    max_input_chars: usize,
    max_tokens: u32,
    enabled: bool,
    default_style: SummaryStyle,
    store: RecordingStore,
}

impl SummaryJobs {
    /// 装配一个还没有模型的队列。
    ///
    /// 模型不在构造时解析，而是由 `AppState::new` 用 hub 的当前快照通过
    /// [`Self::set_model`] 注入。理由：解析密钥要读 `model-secrets.json`，
    /// 在这里再实现一遍就成了"运行时一套判据、摘要另一套判据"——切到
    /// 一份只有客户端密钥的配置时，摘要会以为自己没有模型。
    pub fn new(pool: SqlitePool, config: &Config) -> Arc<Self> {
        Self::with_optional_model(pool, config, None)
    }

    /// 测试注入假模型用；生产路径走 [`Self::new`]。
    pub fn with_model(
        pool: SqlitePool,
        config: &Config,
        model: Arc<dyn CompletionModel>,
    ) -> Arc<Self> {
        Self::with_optional_model(pool, config, Some(model))
    }

    fn with_optional_model(
        pool: SqlitePool,
        config: &Config,
        model: Option<Arc<dyn CompletionModel>>,
    ) -> Arc<Self> {
        let slots = Arc::new(Semaphore::new(config.summary.max_concurrency.max(1)));
        Arc::new(Self {
            pool,
            model: std::sync::RwLock::new(model),
            model_name: std::sync::RwLock::new(config.llm.model.clone()),
            slots,
            running: Arc::new(Mutex::new(HashSet::new())),
            max_input_chars: config.summary.max_input_chars.max(1_000),
            max_tokens: config.summary.max_tokens.max(1),
            enabled: config.summary.enabled,
            default_style: config.summary.default_style,
            store: RecordingStore::new(config.recordings_dir()),
        })
    }

    /// 换掉总结用的模型。切换模型配置时由 `AppState::apply_llm` 调用。
    pub fn set_model(&self, model: Option<Arc<dyn CompletionModel>>, name: &str) {
        *self
            .model
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = model;
        *self
            .model_name
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = name.to_string();
    }

    fn current_model(&self) -> Option<Arc<dyn CompletionModel>> {
        self.model
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn current_model_name(&self) -> String {
        self.model_name
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// 现在能不能总结：开关打开 **且** 有模型。
    ///
    /// 每次现取：切到一份没有密钥的配置时，队列要立刻停止领新任务，
    /// 而不是拿旧模型继续跑。
    pub fn available(&self) -> bool {
        self.enabled && self.current_model().is_some()
    }

    /// 写进录音记录的模型名；不可用时为 `None`。
    pub fn model(&self) -> Option<String> {
        self.available().then(|| self.current_model_name())
    }

    /// 启动消费循环。`running` 状态在上个进程被杀后需要回收。
    pub fn start(self: &Arc<Self>) {
        let pool = self.pool.clone();
        let this = Arc::clone(self);
        tokio::spawn(async move {
            if let Err(err) = sqlx::query(
                "UPDATE recordings SET summary_status = 'pending' WHERE summary_status = 'running'",
            )
            .execute(&pool)
            .await
            {
                tracing::warn!(%err, "回收中断的录音总结失败");
            }
            loop {
                this.process_pending().await;
                tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
            }
        });
    }

    /// 处理当前所有 pending 录音。测试可直接调用，不必等轮询。
    pub async fn process_pending(&self) {
        if !self.enabled {
            let _ = sqlx::query(
                "UPDATE recordings SET summary_status = 'failed', \
                 summary_error = '服务端未开启总结', updated_at = ? \
                 WHERE summary_status = 'pending'",
            )
            .bind(now_ms())
            .execute(&self.pool)
            .await;
            return;
        }
        loop {
            let Some(id) = claim_pending(&self.pool).await else {
                break;
            };
            if self.current_model().is_none() {
                let _ = mark_failed(&self.pool, &id, "服务端未配置总结模型").await;
                continue;
            }
            let _permit = match self.slots.acquire().await {
                Ok(permit) => permit,
                Err(_) => break,
            };
            {
                let mut running = self
                    .running
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if !running.insert(id.clone()) {
                    continue;
                }
            }
            self.run_one(&id).await;
            self.running
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&id);
        }
    }

    async fn run_one(&self, recording_id: &str) {
        // 一开始就取快照：这一条录音从头到尾用同一个模型，中途切换也不会
        // 出现"前半段旧模型、后半段新模型"这种分不清来源的总结。
        let Some(model) = self.current_model() else {
            return;
        };
        let model_name = self.current_model_name();

        let row = sqlx::query_as::<_, (String, Option<i64>, String, Option<String>)>(
            "SELECT status, completed_at, text, summary_style_preference \
             FROM recordings WHERE id = ?",
        )
        .bind(recording_id)
        .fetch_optional(&self.pool)
        .await;
        let (status, completed_at, text, style) = match row {
            Ok(Some(row)) => row,
            Ok(None) => {
                let _ = mark_failed(&self.pool, recording_id, "录音已被删除").await;
                return;
            }
            Err(err) => {
                tracing::error!(%err, recording_id, "读取待总结录音失败");
                let _ = mark_failed(&self.pool, recording_id, "读取录音失败").await;
                return;
            }
        };

        if status != "ready" || completed_at.is_none() {
            let _ = mark_failed(&self.pool, recording_id, "全部分段转写完成后才能生成总结").await;
            return;
        }
        let text = text.trim();
        if text.is_empty() {
            let _ = mark_failed(&self.pool, recording_id, "没有可总结的转写内容").await;
            return;
        }

        let style = style
            .as_deref()
            .and_then(SummaryStyle::parse)
            .unwrap_or(self.default_style);
        let input = truncate_at_sentence(text, self.max_input_chars);
        let prompt = format!("以下是录音转写稿：\n\n{input}\n\n请按要求整理。");
        let started = std::time::Instant::now();
        let result = model
            .complete(system_prompt(style), &prompt, Some(self.max_tokens))
            .await;

        match result {
            Ok(completion) => {
                let summary = completion.text.trim();
                if summary.is_empty() {
                    let _ = mark_failed(&self.pool, recording_id, "模型没有返回总结内容").await;
                    return;
                }
                // 生成期间用户可能点了重新生成或重新转写：只有仍然属于当前这次
                // running 的总结才能落库，否则会把旧结果盖到新状态上。
                let state = sqlx::query_as::<_, (String, String)>(
                    "SELECT status, summary_status FROM recordings WHERE id = ?",
                )
                .bind(recording_id)
                .fetch_optional(&self.pool)
                .await;
                match state {
                    Ok(Some((recording_status, summary_status)))
                        if recording_status == "ready" && summary_status == "running" => {}
                    Ok(_) => return,
                    Err(err) => {
                        tracing::warn!(%err, recording_id, "校验总结版本失败");
                        return;
                    }
                }
                // 先让旧语音失效，再落新总结：避免客户端在两条语句之间看到
                // "新总结 ready + 旧音频 ready" 并播放上一版内容。
                clear_audio(&self.pool, &self.store, recording_id).await;
                if let Err(err) = set_ready(
                    &self.pool,
                    recording_id,
                    summary,
                    style,
                    &model_name,
                    completion.completion_tokens,
                )
                .await
                {
                    tracing::error!(%err, recording_id, "写入录音总结失败");
                    let _ = mark_failed(&self.pool, recording_id, "写入总结失败").await;
                    return;
                }
                tracing::info!(
                    recording_id,
                    elapsed_ms = started.elapsed().as_millis(),
                    "录音总结已生成"
                );
            }
            Err(err) => {
                tracing::warn!(%err, recording_id, "录音总结生成失败");
                let _ = mark_failed(&self.pool, recording_id, &friendly_model_error(&err)).await;
            }
        }
    }
}

async fn claim_pending(pool: &SqlitePool) -> Option<String> {
    let candidates = sqlx::query_scalar::<_, String>(
        "SELECT id FROM recordings WHERE summary_status = 'pending' ORDER BY updated_at ASC LIMIT 4",
    )
    .fetch_all(pool)
    .await
    .ok()?;
    for id in candidates {
        let affected = sqlx::query(
            "UPDATE recordings SET summary_status = 'running', updated_at = ? \
             WHERE id = ? AND summary_status = 'pending'",
        )
        .bind(now_ms())
        .bind(&id)
        .execute(pool)
        .await
        .ok()?
        .rows_affected();
        if affected > 0 {
            return Some(id);
        }
    }
    None
}

async fn set_ready(
    pool: &SqlitePool,
    recording_id: &str,
    summary: &str,
    style: SummaryStyle,
    model: &str,
    _completion_tokens: u32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE recordings SET summary = ?, summary_status = 'ready', summary_error = NULL, \
         summary_style = ?, summary_model = ?, summary_updated_at = ?, updated_at = ? \
         WHERE id = ?",
    )
    .bind(summary)
    .bind(style.as_str())
    .bind(model)
    .bind(now_ms())
    .bind(now_ms())
    .bind(recording_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_failed(
    pool: &SqlitePool,
    recording_id: &str,
    error: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE recordings SET summary_status = 'failed', summary_error = ?, \
         summary_updated_at = ?, updated_at = ? WHERE id = ?",
    )
    .bind(error)
    .bind(now_ms())
    .bind(now_ms())
    .bind(recording_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn clear_audio(pool: &SqlitePool, store: &RecordingStore, recording_id: &str) {
    let path = sqlx::query_scalar::<_, Option<String>>(
        "SELECT summary_audio_path FROM recordings WHERE id = ?",
    )
    .bind(recording_id)
    .fetch_optional(pool)
    .await
    .ok()
    .flatten()
    .flatten();

    if let Some(relative) = path {
        if let Ok(path) = store.path_of(&relative) {
            let _ = tokio::fs::remove_file(path).await;
        }
    }

    let _ = sqlx::query(
        "UPDATE recordings SET summary_audio_path = NULL, summary_audio_status = 'none', \
         summary_audio_error = NULL, summary_audio_bytes = 0, summary_audio_format = NULL, \
         summary_audio_updated_at = NULL, summary_audio_truncated = 0 WHERE id = ?",
    )
    .bind(recording_id)
    .execute(pool)
    .await;
}

fn truncate_at_sentence(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let head: String = text.chars().take(limit).collect();
    let cut = head
        .char_indices()
        .rev()
        .find(|(_, ch)| matches!(ch, '。' | '！' | '？' | '\n'))
        .map(|(index, ch)| index + ch.len_utf8())
        .unwrap_or(head.len());
    head[..cut].to_string()
}

fn friendly_model_error(error: &str) -> String {
    let trimmed = error.trim();
    if trimmed.chars().count() > 180 {
        format!("{}…", trimmed.chars().take(180).collect::<String>())
    } else if trimmed.is_empty() {
        "总结生成失败".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_keeps_sentence_boundary() {
        let text = "第一句。第二句。第三句。";
        let cut = truncate_at_sentence(text, 8);
        assert!(cut.ends_with('。'));
        assert!(cut.chars().count() <= 8);
    }

    #[test]
    fn short_text_is_unchanged() {
        assert_eq!(truncate_at_sentence("很短", 100), "很短");
    }
}
