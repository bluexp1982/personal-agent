//! 录音转写任务。
//!
//! 两类触发共用同一条执行路径：
//! - 实时模式：分段上传的请求内直接调 [`TranscriptionJobs::transcribe_now`]；
//! - 批量模式：`complete` 后 [`TranscriptionJobs::enqueue`] 起后台任务逐段转写。
//!
//! 设计约束：
//! - **同一录音同时只有一个后台任务**（`running` 集合去重），否则同一段会被重复计费；
//! - 全局并发由信号量收敛（上游按 RPM 限流），跨录音共用；
//! - 进程重启后 [`TranscriptionJobs::resume`] 会把"已 complete 但还有 stored 分段"
//!   的录音重新排队，不需要客户端重新点一次。

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use sqlx::SqlitePool;
use tokio::sync::Semaphore;

use crate::clock::now_ms;
use crate::config::Config;

use super::asr::{self, AsrError, SpeechToText};
use super::store::{RecordingStore, StoreError};
use super::{claim_next, fail_pending, refresh, set_segment_failed, set_segment_text};

#[derive(Debug)]
pub struct TranscriptionJobs {
    pool: SqlitePool,
    asr: Option<Arc<dyn SpeechToText>>,
    slots: Arc<Semaphore>,
    running: Arc<Mutex<HashSet<String>>>,
    language: Option<String>,
    store: RecordingStore,
}

impl TranscriptionJobs {
    pub fn new(pool: SqlitePool, config: &Config) -> Arc<Self> {
        let asr = asr::from_config(config);
        let slots = Arc::new(Semaphore::new(config.asr.max_concurrency.max(1)));
        Arc::new(Self {
            pool,
            asr,
            slots,
            running: Arc::new(Mutex::new(HashSet::new())),
            language: config.asr.language.clone(),
            store: RecordingStore::new(config.recordings_dir()),
        })
    }

    /// 是否真的能转写（开启 + 密钥/provider 就绪）。
    pub fn available(&self) -> bool {
        self.asr.is_some()
    }

    /// 模型标识，仅用于展示与日志。
    pub fn model(&self) -> Option<&str> {
        self.asr.as_ref().map(|asr| asr.model())
    }

    /// 排队一次批量转写。未配置转写或已在跑时是无操作。
    pub fn enqueue(self: &Arc<Self>, recording_id: String) {
        if self.asr.is_none() {
            return;
        }
        {
            let mut running = self
                .running
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !running.insert(recording_id.clone()) {
                return;
            }
        }

        let this = Arc::clone(self);
        tokio::spawn(async move {
            this.run(&recording_id).await;
            this.running
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&recording_id);
            if let Err(err) = refresh(&this.pool, &recording_id).await {
                tracing::warn!(%err, recording_id, "转写结束后刷新聚合状态失败");
            }
        });
    }

    /// 实时模式：在本次请求内转写一个分段。
    pub async fn transcribe_now(&self, recording_id: &str, seq: u32) -> Result<(), AsrError> {
        let Some(asr) = &self.asr else {
            return Err(AsrError::Unavailable("服务端未开启转写".to_string()));
        };
        let permit = self
            .slots
            .acquire()
            .await
            .map_err(|_| AsrError::Unavailable("转写队列已关闭".to_string()))?;

        let result = self
            .transcribe_claimed(asr.as_ref(), recording_id, seq)
            .await;
        drop(permit);
        if let Err(err) = refresh(&self.pool, recording_id).await {
            tracing::warn!(%err, recording_id, "转写后刷新聚合状态失败");
        }
        result
    }

    async fn transcribe_claimed(
        &self,
        asr: &dyn SpeechToText,
        recording_id: &str,
        seq: u32,
    ) -> Result<(), AsrError> {
        // 实时路径只知道 seq，需要自己抢占；批量路径由 `claim_next` 预先标记。
        let affected = sqlx::query(
            "UPDATE recording_segments SET state = 'transcribing', updated_at = ? \
             WHERE recording_id = ? AND seq = ? AND state IN ('stored', 'failed')",
        )
        .bind(now_ms())
        .bind(recording_id)
        .bind(i64::from(seq))
        .execute(&self.pool)
        .await
        .map_err(|err| AsrError::Failed(format!("更新分段状态失败：{err}")))?
        .rows_affected();

        let state = sqlx::query_scalar::<_, String>(
            "SELECT state FROM recording_segments WHERE recording_id = ? AND seq = ?",
        )
        .bind(recording_id)
        .bind(i64::from(seq))
        .fetch_optional(&self.pool)
        .await
        .map_err(|err| AsrError::Failed(format!("读取分段失败：{err}")))?;

        if affected == 0 && state.as_deref() != Some("transcribing") {
            // 已被别的路径领走或已成功：不重复计费。
            return Ok(());
        }

        let path = sqlx::query_scalar::<_, String>(
            "SELECT path FROM recording_segments WHERE recording_id = ? AND seq = ?",
        )
        .bind(recording_id)
        .bind(i64::from(seq))
        .fetch_optional(&self.pool)
        .await
        .map_err(|err| AsrError::Failed(format!("读取分段路径失败：{err}")))?
        .ok_or_else(|| AsrError::Failed("分段记录已不存在".to_string()))?;

        let wav = match self.store.read_segment(&path).await {
            Ok(bytes) => bytes,
            Err(StoreError::Missing) => {
                let message = "音频文件不存在，可能已被清理";
                let _ = set_segment_failed(&self.pool, recording_id, seq, message).await;
                return Err(AsrError::Failed(message.to_string()));
            }
            Err(err) => {
                let message = format!("读取音频失败：{err}");
                let _ = set_segment_failed(&self.pool, recording_id, seq, &message).await;
                return Err(AsrError::Failed(message));
            }
        };

        match asr.transcribe(&wav, self.language.as_deref()).await {
            Ok(text) => {
                if let Err(err) = set_segment_text(&self.pool, recording_id, seq, &text).await {
                    tracing::error!(%err, recording_id, seq, "写入转写文本失败");
                }
                Ok(())
            }
            Err(err) => {
                let _ = set_segment_failed(&self.pool, recording_id, seq, err.message()).await;
                Err(err)
            }
        }
    }

    async fn run(&self, recording_id: &str) {
        let Some(asr) = &self.asr else {
            return;
        };

        loop {
            let next = match claim_next(&self.pool, recording_id).await {
                Ok(next) => next,
                Err(err) => {
                    tracing::error!(%err, recording_id, "领取待转写分段失败");
                    break;
                }
            };
            let Some((seq, _path)) = next else {
                break;
            };

            // claim_next 已经把状态置为 transcribing，这里直接复用同一条执行路径。
            match self
                .transcribe_claimed(asr.as_ref(), recording_id, seq)
                .await
            {
                Ok(()) => {}
                Err(AsrError::Unavailable(message)) => {
                    tracing::warn!(recording_id, %message, "转写服务不可用，停止本条录音的批量转写");
                    let _ = fail_pending(&self.pool, recording_id, &message).await;
                    break;
                }
                Err(AsrError::Failed(message)) => {
                    tracing::warn!(recording_id, seq, %message, "分段转写失败，继续下一段");
                }
            }
        }
    }

    /// 启动时续跑：已结束但仍有未转写分段的录音重新排队。
    pub fn resume(self: &Arc<Self>) {
        let pool = self.pool.clone();
        let this = Arc::clone(self);
        tokio::spawn(async move {
            // 启动时把两类"半成品"拉回 stored：
            // - `ready` 但文本为空：老版本把空转写当成功；
            // - `transcribing`：上个进程在调用上游时被杀，claim 永远不释放。
            // 即使 ASR 没开启也要做：否则界面会卡在"转写中"。
            let mut stale = sqlx::query_scalar::<_, String>(
                "SELECT DISTINCT recording_id FROM recording_segments \
                 WHERE state = 'transcribing' OR (state = 'ready' AND trim(text) = '')",
            )
            .fetch_all(&pool)
            .await
            .unwrap_or_default();

            // 历史上把"没有语音"当成了失败：这些段不必再花一次上游调用，
            // 直接落成 ready + 空文本，让录音从"部分失败"恢复成"已转写"。
            let no_words = sqlx::query_scalar::<_, String>(
                "SELECT DISTINCT recording_id FROM recording_segments \
                 WHERE state = 'failed' AND error LIKE '%ASR_RESPONSE_HAVE_NO_WORDS%'",
            )
            .fetch_all(&pool)
            .await
            .unwrap_or_default();
            if !no_words.is_empty() {
                match sqlx::query(
                    "UPDATE recording_segments \
                     SET state = 'ready', text = '', error = NULL, updated_at = ? \
                     WHERE state = 'failed' AND error LIKE '%ASR_RESPONSE_HAVE_NO_WORDS%'",
                )
                .bind(now_ms())
                .execute(&pool)
                .await
                {
                    Ok(done) => tracing::info!(
                        count = done.rows_affected(),
                        "把\"没有语音\"的失败分段修正为空转写"
                    ),
                    Err(err) => tracing::warn!(%err, "修正无语音分段失败"),
                }
                stale.extend(no_words);
            }

            match sqlx::query(
                "UPDATE recording_segments SET state = 'stored', updated_at = ? \
                 WHERE (state = 'ready' AND trim(text) = '') OR state = 'transcribing'",
            )
            .bind(now_ms())
            .execute(&pool)
            .await
            {
                Ok(done) if done.rows_affected() > 0 => {
                    tracing::info!(
                        count = done.rows_affected(),
                        "发现未完成/空转写分段，已重新排队"
                    );
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(%err, "重置未完成转写分段失败"),
            }

            for id in &stale {
                if let Err(err) = refresh(&pool, id).await {
                    tracing::warn!(%err, recording_id = %id, "刷新录音状态失败");
                }
            }

            if this.asr.is_none() {
                return;
            }

            let rows = sqlx::query_scalar::<_, String>(
                "SELECT r.id FROM recordings r \
                 JOIN recording_segments s ON s.recording_id = r.id \
                 WHERE r.completed_at IS NOT NULL AND s.state = 'stored' \
                 GROUP BY r.id",
            )
            .fetch_all(&pool)
            .await;

            match rows {
                Ok(ids) if !ids.is_empty() => {
                    tracing::info!(count = ids.len(), "重启后续跑未完成的录音转写");
                    for id in ids {
                        this.enqueue(id);
                    }
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(%err, "扫描未完成的录音转写失败"),
            }
        });
    }
}
