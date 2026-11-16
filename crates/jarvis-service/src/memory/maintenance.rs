//! 记忆整理：把「夜间那套动作」从心跳的时间条件里拆出来。
//!
//! 两个调用方共用同一份实现：
//! - `heartbeat` 的夜间分支（03:00 后、距上次 ≥20 小时）；
//! - `POST /api/memories/organize`（用户在记忆页点「整理」）。
//!
//! 四步都有限量，且**单步失败不中断**：整理是后台维护，不该因为一条脏数据停摆。
//! 「什么时候整理」是调用方的事；本模块只回答「整理一次要做哪些事」。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

use protocol::MaintenanceReportView;

use super::entity;
use super::extract::{ExtractJob, ExtractSource};
use super::MemoryService;

/// 每类每轮最多投递几条。刚打开自动抽取时历史录音可能上百条，
/// 一次全投递会瞬间烧完日额度；限量 + 水位推进把工作分摊到多次。
const SEDIMENT_LIMIT: i64 = 5;

/// 每轮最多归档多少条。异常数据不该让一次整理长时间持锁。
const DECAY_LIMIT: usize = 500;

/// 每轮最多归并多少条。
const CONSOLIDATE_LIMIT: usize = 100;

/// 沉淀水位：**已经投递到哪个时刻**。手动与夜间都写。
const KEY_LAST_ORGANIZED_AT: &str = "last_organized_at";

/// 最近一次整理的条数概览，供状态接口回读。
const KEY_LAST_REPORT: &str = "last_organized_report";

/// 自动整理的节流起点。只有心跳写它——手动整理不该把当晚的自动整理挤掉。
const KEY_LAST_NIGHTLY_AT: &str = "last_nightly_at";

/// 一次整理的统计。字段都是条数，不含任何正文。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrganizeReport {
    pub recomputed: u32,
    pub failed: u32,
    pub sedimented: u32,
    pub decayed: u32,
    pub consolidated: u32,
    /// 没有可用模型时快照重算会被跳过：其余三步照常，客户端据此换文案。
    pub model_available: bool,
}

impl OrganizeReport {
    pub fn view(self) -> MaintenanceReportView {
        MaintenanceReportView {
            recomputed: self.recomputed,
            failed: self.failed,
            sedimented: self.sedimented,
            decayed: self.decayed,
            consolidated: self.consolidated,
            model_available: self.model_available,
        }
    }

    /// 四步都没动到数据：客户端提示「没有需要整理的内容」。
    pub fn is_empty(self) -> bool {
        self.recomputed == 0
            && self.failed == 0
            && self.sedimented == 0
            && self.decayed == 0
            && self.consolidated == 0
    }
}

#[derive(Debug, thiserror::Error)]
pub enum OrganizeError {
    #[error("记忆功能未启用")]
    Disabled,
    #[error("正在整理，请稍候")]
    Busy,
}

/// 整理闸门的持有凭证。
///
/// 复位放在 `Drop` 里：panic 或提前返回都不会把闸门永久占住，进程重启也自然复位。
#[derive(Debug)]
pub struct OrganizeLease {
    flag: Arc<AtomicBool>,
}

impl Drop for OrganizeLease {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::SeqCst);
    }
}

impl MemoryService {
    /// 是否有一轮整理正在跑。
    pub fn organizing(&self) -> bool {
        self.organizing.load(Ordering::SeqCst)
    }

    /// 抢占整理闸门。占不到说明已经有一轮在跑，调用方该直接返回冲突而不是排队。
    pub fn try_begin_organize(&self) -> Option<OrganizeLease> {
        self.organizing
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| OrganizeLease {
                flag: self.organizing.clone(),
            })
    }

    /// 整理一次（自己抢闸门）。心跳夜间分支走这里。
    pub async fn organize(&self, now: i64) -> Result<OrganizeReport, OrganizeError> {
        let lease = self.try_begin_organize().ok_or(OrganizeError::Busy)?;
        self.organize_holding(lease, now).await
    }

    /// 整理一次（闸门已由调用方持有）。手动端点先抢占、再 spawn 后台跑。
    pub async fn organize_holding(
        &self,
        _lease: OrganizeLease,
        now: i64,
    ) -> Result<OrganizeReport, OrganizeError> {
        if !self.config.enabled {
            return Err(OrganizeError::Disabled);
        }

        let mut report = OrganizeReport {
            model_available: self.model().is_some(),
            ..OrganizeReport::default()
        };

        // 1. 实体快照重算：只有脏实体需要重写「当前状态」。
        if let Some(model) = self.model() {
            let limit = self.config.entity.nightly_limit;
            match entity::recompute_dirty(&self.pool, Some(model.as_ref()), limit, now).await {
                Ok(result) => {
                    report.recomputed = result.updated as u32;
                    report.failed = result.failed as u32;
                }
                Err(err) => tracing::warn!(%err, "整理：实体快照重算失败"),
            }
        } else {
            // 没有模型时逐条试只会刷一屏同样的失败日志，直接跳过。
            tracing::debug!("整理：未配置模型，跳过实体快照重算");
        }

        // 2. 沉淀：把上一轮之后新产生的录音与编码任务投递成抽取。
        // 先读水位再做事：投递失败的下一轮还能重试（水位只在全部做完后推进）。
        let since = self.sediment_watermark().await;
        report.sedimented = self.sediment(since).await as u32;

        // 3. 衰减归档：长期没用又不重要的记忆退出日常对话。
        // 只改 status，不删行；每轮限量，避免一次锁库太久。
        let decay_after = i64::from(self.config.heartbeat.decay_after_days) * 86_400_000;
        match self
            .store()
            .decay_archive(
                self.config.heartbeat.decay_max_importance,
                now - decay_after,
                DECAY_LIMIT,
            )
            .await
        {
            Ok(count) => report.decayed = count as u32,
            Err(err) => tracing::warn!(%err, "整理：记忆衰减归档失败"),
        }

        // 4. 归并：同一件事被说得详略不同时，把简的并进完整的那条。
        // 只对 profile/preference 生效，且只归档不删除（证据整行迁移）。
        match self.store().consolidate_subsumed(CONSOLIDATE_LIMIT).await {
            Ok(0) => {}
            Ok(count) => {
                report.consolidated = count as u32;
                super::audit_reject(
                    &self.pool,
                    "memory.consolidated",
                    serde_json::json!({ "merged": count }),
                )
                .await;
            }
            Err(err) => tracing::warn!(%err, "整理：记忆归并失败"),
        }

        // 水位与最近结果：写完才认为这一轮结束，客户端据此判定"跑完了"。
        write_json(&self.pool, KEY_LAST_ORGANIZED_AT, serde_json::json!(now)).await;
        write_json(
            &self.pool,
            KEY_LAST_REPORT,
            serde_json::to_value(report).unwrap_or(serde_json::Value::Null),
        )
        .await;
        super::audit_reject(
            &self.pool,
            "memory.organized",
            serde_json::json!({
                "recomputed": report.recomputed,
                "failed": report.failed,
                "sedimented": report.sedimented,
                "decayed": report.decayed,
                "consolidated": report.consolidated,
                "model_available": report.model_available,
            }),
        )
        .await;

        Ok(report)
    }

    /// `GET /api/memories/state` 的 `maintenance` 节。读失败只降级，不让快照接口失败。
    pub async fn maintenance_view(&self) -> protocol::MaintenanceView {
        let last_organized_at = read_i64(&self.pool, KEY_LAST_ORGANIZED_AT).await;
        let last_report = read_json(&self.pool, KEY_LAST_REPORT)
            .await
            .and_then(|value| serde_json::from_value::<OrganizeReport>(value).ok())
            .map(OrganizeReport::view);

        protocol::MaintenanceView {
            organizing: self.organizing(),
            last_organized_at,
            last_report,
        }
    }

    /// 沉淀水位。老库只有 `last_nightly_at`，回退到它才不会把历史录音重投一遍。
    async fn sediment_watermark(&self) -> i64 {
        match read_i64(&self.pool, KEY_LAST_ORGANIZED_AT).await {
            Some(now) => now,
            None => read_i64(&self.pool, KEY_LAST_NIGHTLY_AT).await.unwrap_or(0),
        }
    }

    /// 夜间/手动整理共用的沉淀：录音总结与成功的编码任务各取最近若干条。
    async fn sediment(&self, since: i64) -> usize {
        let mut count = 0usize;

        let recordings: Vec<(String,)> = match sqlx::query_as(
            "SELECT id FROM recordings \
             WHERE summary_status = 'ready' AND summary IS NOT NULL \
               AND summary_updated_at IS NOT NULL AND summary_updated_at > ? \
             ORDER BY summary_updated_at DESC LIMIT ?",
        )
        .bind(since)
        .bind(SEDIMENT_LIMIT)
        .fetch_all(&self.pool)
        .await
        {
            Ok(rows) => rows,
            Err(err) => {
                tracing::warn!(%err, "整理：查询待沉淀录音失败");
                Vec::new()
            }
        };

        for (recording_id,) in recordings {
            self.submit_extract(ExtractJob {
                batch_id: crate::ids::new_id("bat"),
                trace_id: recording_id.clone(),
                source: ExtractSource::Recording { recording_id },
            });
            count += 1;
        }

        // 编码任务：`skill` 或 `type` 里带 code 的才算，普通事务任务不重复抽
        // （它们已经在任务成功时投递过一次）。
        let tasks: Vec<(String,)> = match sqlx::query_as(
            "SELECT id FROM tasks \
             WHERE state = 'succeeded' AND deleted_at IS NULL AND updated_at > ? \
               AND (COALESCE(skill, '') LIKE '%code%' OR COALESCE(type, '') LIKE '%code%') \
             ORDER BY updated_at DESC LIMIT ?",
        )
        .bind(since)
        .bind(SEDIMENT_LIMIT)
        .fetch_all(&self.pool)
        .await
        {
            Ok(rows) => rows,
            Err(err) => {
                tracing::warn!(%err, "整理：查询待沉淀编码任务失败");
                Vec::new()
            }
        };

        for (task_id,) in tasks {
            self.submit_extract(ExtractJob {
                batch_id: crate::ids::new_id("bat"),
                trace_id: task_id.clone(),
                source: ExtractSource::CodeTask { task_id },
            });
            count += 1;
        }

        count
    }
}

/// 读心跳 KV 里的整数。缺省或脏数据都按"没有"处理：水位只影响是否重复做事，
/// 不该让整理本身失败。
pub(crate) async fn read_i64(pool: &SqlitePool, key: &str) -> Option<i64> {
    read_json(pool, key)
        .await
        .and_then(|value| serde_json::from_value::<i64>(value).ok())
}

pub(crate) async fn read_json(pool: &SqlitePool, key: &str) -> Option<serde_json::Value> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT value_json FROM memory_heartbeat_state WHERE key = ?")
            .bind(key)
            .fetch_optional(pool)
            .await
            .ok()
            .flatten();

    row.and_then(|(raw,)| serde_json::from_str::<serde_json::Value>(&raw).ok())
}

pub(crate) async fn write_json(pool: &SqlitePool, key: &str, value: serde_json::Value) {
    let result = sqlx::query(
        "INSERT INTO memory_heartbeat_state (key, value_json, updated_at) VALUES (?, ?, ?) \
         ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, \
           updated_at = excluded.updated_at",
    )
    .bind(key)
    .bind(value.to_string())
    .bind(crate::clock::now_ms())
    .execute(pool)
    .await;

    if let Err(err) = result {
        tracing::warn!(%err, key, "整理状态写入失败");
    }
}

/// 自动整理的节流起点（`last_nightly_at`）。心跳只读它判断「今晚是否已经整理过」。
pub(crate) async fn last_nightly_at(pool: &SqlitePool) -> i64 {
    read_i64(pool, KEY_LAST_NIGHTLY_AT).await.unwrap_or(0)
}

/// 心跳夜间分支完成后推进节流水位。
pub(crate) async fn mark_nightly(pool: &SqlitePool, now: i64) {
    write_json(pool, KEY_LAST_NIGHTLY_AT, serde_json::json!(now)).await;
}
