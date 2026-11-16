//! 总结语音的后台合成。
//!
//! 总结生成后不立即合成：用户可能只看文字。首次请求播放时才置 `pending`，
//! 这里消费并把音频缓存到录音目录；总结重新生成会先清掉旧音频。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use sqlx::SqlitePool;
use tokio::sync::Semaphore;

use crate::clock::now_ms;
use crate::config::Config;

use super::store::RecordingStore;
use super::tts::{self, SpeechSynthesizer};

#[derive(Debug)]
pub struct SummaryAudioJobs {
    pool: SqlitePool,
    tts: Option<Arc<dyn SpeechSynthesizer>>,
    slots: Arc<Semaphore>,
    running: Arc<Mutex<HashSet<String>>>,
    store: RecordingStore,
    max_chars: usize,
}

impl SummaryAudioJobs {
    pub fn new(pool: SqlitePool, config: &Config) -> Arc<Self> {
        Self::with_optional_synthesizer(pool, config, tts::from_config(config))
    }

    /// 测试注入假 TTS 用；生产路径走 [`Self::new`]。
    pub fn with_synthesizer(
        pool: SqlitePool,
        config: &Config,
        synthesizer: Arc<dyn SpeechSynthesizer>,
    ) -> Arc<Self> {
        Self::with_optional_synthesizer(pool, config, Some(synthesizer))
    }

    fn with_optional_synthesizer(
        pool: SqlitePool,
        config: &Config,
        tts: Option<Arc<dyn SpeechSynthesizer>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            pool,
            tts,
            slots: Arc::new(Semaphore::new(1)),
            running: Arc::new(Mutex::new(HashSet::new())),
            store: RecordingStore::new(config.recordings_dir()),
            max_chars: config.tts.max_text_chars.max(100),
        })
    }

    pub fn available(&self) -> bool {
        self.tts.is_some()
    }

    pub fn model(&self) -> Option<&str> {
        self.tts.as_ref().map(|tts| tts.model())
    }

    pub fn voice(&self) -> Option<&str> {
        self.tts.as_ref().map(|tts| tts.voice())
    }

    pub fn format(&self) -> Option<&str> {
        self.tts.as_ref().map(|tts| tts.format())
    }

    pub fn start(self: &Arc<Self>) {
        let pool = self.pool.clone();
        let this = Arc::clone(self);
        tokio::spawn(async move {
            if let Err(err) = sqlx::query(
                "UPDATE recordings SET summary_audio_status = 'pending' \
                 WHERE summary_audio_status = 'running'",
            )
            .execute(&pool)
            .await
            {
                tracing::warn!(%err, "回收中断的总结语音合成失败");
            }
            loop {
                this.process_pending().await;
                tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
            }
        });
    }

    pub async fn process_pending(&self) {
        loop {
            let Some(id) = claim_pending(&self.pool).await else {
                break;
            };
            let Some(tts) = self.tts.clone() else {
                let _ = mark_failed(&self.pool, &id, "服务端未开启语音合成").await;
                continue;
            };
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
            self.run_one(&id, tts.as_ref()).await;
            self.running
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&id);
        }
    }

    async fn run_one(&self, recording_id: &str, tts: &dyn SpeechSynthesizer) {
        type Row = (String, String, Option<i64>, Option<String>);
        let row = sqlx::query_as::<_, Row>(
            "SELECT summary, summary_status, summary_updated_at, summary_audio_path \
             FROM recordings WHERE id = ?",
        )
        .bind(recording_id)
        .fetch_optional(&self.pool)
        .await;

        let (summary, status, version, old_path) = match row {
            Ok(Some(row)) => row,
            Ok(None) => {
                let _ = mark_failed(&self.pool, recording_id, "录音已被删除").await;
                return;
            }
            Err(err) => {
                tracing::error!(%err, recording_id, "读取待合成语音的总结失败");
                let _ = mark_failed(&self.pool, recording_id, "读取总结失败").await;
                return;
            }
        };

        if status != "ready" || summary.trim().is_empty() {
            let _ = mark_failed(&self.pool, recording_id, "总结还没生成好").await;
            return;
        }

        let (text, truncated) = speech_text(&summary, self.max_chars);
        if text.trim().is_empty() {
            let _ = mark_failed(&self.pool, recording_id, "总结没有可朗读的内容").await;
            return;
        }

        let started = std::time::Instant::now();
        match tts.synthesize(&text).await {
            Ok(bytes) => {
                // 合成期间用户可能点了「重新生成总结」：旧版本的音频不能覆盖新状态。
                let current = sqlx::query_as::<_, (String, Option<i64>)>(
                    "SELECT summary_status, summary_updated_at FROM recordings WHERE id = ?",
                )
                .bind(recording_id)
                .fetch_optional(&self.pool)
                .await;
                let unchanged = matches!(
                    current,
                    Ok(Some((ref current_status, current_version)))
                        if current_status == "ready" && current_version == version
                );
                if !unchanged {
                    let _ = reset_audio(&self.pool, recording_id).await;
                    return;
                }

                let relative = match self
                    .store
                    .write_summary_audio(recording_id, tts.format(), &bytes)
                    .await
                {
                    Ok(relative) => relative,
                    Err(err) => {
                        tracing::error!(%err, recording_id, "保存总结语音失败");
                        let _ = mark_failed(&self.pool, recording_id, "保存语音文件失败").await;
                        return;
                    }
                };

                if let Some(old) = old_path {
                    if old != relative {
                        if let Ok(path) = self.store.path_of(&old) {
                            let _ = tokio::fs::remove_file(path).await;
                        }
                    }
                }

                let _ = sqlx::query(
                    "UPDATE recordings SET summary_audio_path = ?, summary_audio_status = 'ready', \
                     summary_audio_error = NULL, summary_audio_bytes = ?, summary_audio_format = ?, \
                     summary_audio_updated_at = ?, summary_audio_truncated = ?, updated_at = ? \
                     WHERE id = ?",
                )
                .bind(&relative)
                .bind(bytes.len() as i64)
                .bind(tts.format())
                .bind(now_ms())
                .bind(i64::from(truncated))
                .bind(now_ms())
                .bind(recording_id)
                .execute(&self.pool)
                .await;

                tracing::info!(
                    recording_id,
                    elapsed_ms = started.elapsed().as_millis(),
                    bytes = bytes.len(),
                    "总结语音已合成"
                );
            }
            Err(err) => {
                tracing::warn!(%err, recording_id, "总结语音合成失败");
                let _ = mark_failed(&self.pool, recording_id, err.message()).await;
            }
        }
    }
}

pub async fn ensure_audio(
    state: &crate::state::AppState,
    recording_id: &str,
) -> Result<protocol::RecordingDetail, super::RecordingError> {
    if !state.summary_audio.available() {
        return Err(super::RecordingError::TtsUnavailable);
    }
    let Some(detail) = super::detail(&state.pool, recording_id).await? else {
        return Err(super::RecordingError::NotFound);
    };
    if detail.summary.status != protocol::SummaryStatus::Ready
        || detail.summary.text.trim().is_empty()
    {
        return Err(super::RecordingError::SummaryNotReady(
            "总结还没生成好".to_string(),
        ));
    }

    // 已经在排队/合成中：再次点播放只返回当前状态，不要把它重置成 pending，
    // 否则合成完成后会再被 claim 一次，产生重复的 TTS 调用。
    if matches!(
        detail.summary.audio_status,
        protocol::SummaryAudioStatus::Pending | protocol::SummaryAudioStatus::Running
    ) {
        return Ok(detail);
    }

    if detail.summary.audio_status == protocol::SummaryAudioStatus::Ready {
        let path = sqlx::query_scalar::<_, Option<String>>(
            "SELECT summary_audio_path FROM recordings WHERE id = ?",
        )
        .bind(recording_id)
        .fetch_optional(&state.pool)
        .await?
        .flatten();
        let store = RecordingStore::new(state.config.recordings_dir());
        let exists = match path
            .as_deref()
            .and_then(|relative| store.path_of(relative).ok())
        {
            Some(path) => tokio::fs::try_exists(path).await.unwrap_or(false),
            None => false,
        };
        if exists {
            return Ok(detail);
        }
        // 数据库说 ready、文件却没了：当作未合成，重新排队。
        reset_audio(&state.pool, recording_id).await?;
    }

    sqlx::query(
        "UPDATE recordings SET summary_audio_status = 'pending', summary_audio_error = NULL, \
         updated_at = ? WHERE id = ?",
    )
    .bind(now_ms())
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    super::detail(&state.pool, recording_id)
        .await?
        .ok_or(super::RecordingError::NotFound)
}

/// 已读出的总结语音：下载要字节，算峰值要格式，缓存要版本号。
///
/// 三样都来自同一次 `detail` 查询，避免 handler 里再查一遍。
#[derive(Debug)]
pub struct LoadedSummaryAudio {
    pub bytes: Vec<u8>,
    pub format: String,
    pub updated_at: Option<i64>,
}

pub async fn load_audio(
    state: &crate::state::AppState,
    recording_id: &str,
) -> Result<LoadedSummaryAudio, super::RecordingError> {
    let Some(detail) = super::detail(&state.pool, recording_id).await? else {
        return Err(super::RecordingError::NotFound);
    };
    if detail.summary.audio_status != protocol::SummaryAudioStatus::Ready {
        return Err(super::RecordingError::SummaryAudioNotReady(
            "语音还在合成或合成失败".to_string(),
        ));
    }
    let relative = sqlx::query_scalar::<_, Option<String>>(
        "SELECT summary_audio_path FROM recordings WHERE id = ?",
    )
    .bind(recording_id)
    .fetch_optional(&state.pool)
    .await?
    .flatten()
    .ok_or_else(|| super::RecordingError::SummaryAudioNotReady("语音文件路径缺失".to_string()))?;

    let store = RecordingStore::new(state.config.recordings_dir());
    let bytes = match store.read_summary_audio(&relative).await {
        Ok(bytes) => bytes,
        Err(super::store::StoreError::Missing) => {
            // 数据库说 ready、文件却没了：重置状态，下一次 ensure 会重新合成。
            let _ = reset_audio(&state.pool, recording_id).await;
            return Err(super::RecordingError::SummaryAudioNotReady(
                "语音文件已丢失，请重新生成".to_string(),
            ));
        }
        Err(err) => {
            return Err(super::RecordingError::Store(format!(
                "读取总结语音失败：{err}"
            )))
        }
    };
    let format = detail
        .summary
        .audio_format
        .unwrap_or_else(|| "mp3".to_string());
    Ok(LoadedSummaryAudio {
        bytes,
        format,
        updated_at: detail.summary.audio_updated_at,
    })
}

async fn claim_pending(pool: &SqlitePool) -> Option<String> {
    let candidates = sqlx::query_scalar::<_, String>(
        "SELECT id FROM recordings WHERE summary_audio_status = 'pending' \
         ORDER BY updated_at ASC LIMIT 4",
    )
    .fetch_all(pool)
    .await
    .ok()?;
    for id in candidates {
        let affected = sqlx::query(
            "UPDATE recordings SET summary_audio_status = 'running', updated_at = ? \
             WHERE id = ? AND summary_audio_status = 'pending'",
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

async fn mark_failed(
    pool: &SqlitePool,
    recording_id: &str,
    error: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE recordings SET summary_audio_status = 'failed', summary_audio_error = ?, \
         summary_audio_updated_at = ?, updated_at = ? WHERE id = ?",
    )
    .bind(truncate(error, 300))
    .bind(now_ms())
    .bind(now_ms())
    .bind(recording_id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn reset_audio(pool: &SqlitePool, recording_id: &str) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE recordings SET summary_audio_status = 'none', summary_audio_error = NULL, \
         summary_audio_path = NULL, summary_audio_bytes = 0, summary_audio_format = NULL, \
         summary_audio_updated_at = NULL, summary_audio_truncated = 0 WHERE id = ?",
    )
    .bind(recording_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Markdown → 可朗读纯文本，并按句末截断。
pub fn speech_text(markdown: &str, max_chars: usize) -> (String, bool) {
    let mut out = String::new();
    for line in markdown.lines() {
        let mut line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('#') {
            line = line.trim_start_matches('#').trim().to_string();
        }
        for prefix in ["- ", "* ", "> "] {
            if let Some(rest) = line.strip_prefix(prefix) {
                line = rest.trim().to_string();
                break;
            }
        }
        // 有序列表的 "1. " 前缀。
        if let Some((head, tail)) = line.split_once(". ") {
            if head.chars().all(|ch| ch.is_ascii_digit()) {
                line = tail.trim().to_string();
            }
        }
        line = line
            .replace("**", "")
            .replace("__", "")
            .replace(['`', '*'], "");
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&line);
    }

    let total = out.chars().count();
    if total <= max_chars {
        return (out, false);
    }
    let head: String = out.chars().take(max_chars).collect();
    let cut = head
        .char_indices()
        .rev()
        .find(|(_, ch)| matches!(ch, '。' | '！' | '？' | '\n'))
        .map(|(index, ch)| index + ch.len_utf8())
        .unwrap_or(head.len());
    (head[..cut].to_string(), true)
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_is_flattened_for_speech() {
        let (text, truncated) = speech_text(
            "## 概要\n这是一段**总结**。\n- 要点一\n- 要点二\n## 待办 / 结论\n未提及明确待办。",
            200,
        );
        assert!(!truncated);
        assert!(text.contains("概要"));
        assert!(text.contains("这是一段总结。"));
        assert!(!text.contains('#'));
        assert!(!text.contains('-'));
        assert!(!text.contains('*'));
    }

    #[test]
    fn long_summary_is_cut_at_sentence() {
        let (text, truncated) = speech_text("第一句。第二句。第三句。", 8);
        assert!(truncated);
        assert!(text.ends_with('。'));
    }
}
