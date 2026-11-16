//! 心跳：没人提问时也在维护记忆。
//!
//! 与 `ticker.rs` 并列而不是合并：那个是 5 秒一轮的审批/悬空任务安全网，
//! 合并会让安全网变慢。这里是 15 分钟一轮的"巡检 + 沉淀"，独立开关、独立状态。
//!
//! 一轮做三件事：
//! 1. **临近项扫描**：`due_at` 落在未来 24 小时内的生效记忆；
//! 2. **夜间整理**（03:00 后首个心跳）：转 [`crate::memory::maintenance`]；
//! 3. **投递**：四因子打分 → 静音过滤 → 每日额度截断 → 去重 → 送到提醒会话。
//!
//! 每步都可注入时间（`run_once_at`），测试不 sleep。

use std::time::Duration;

use protocol::NotificationCategory;
use serde_json::json;
use sqlx::SqlitePool;

use crate::clock::now_ms;
use crate::memory::maintenance::{OrganizeError, OrganizeReport};
use crate::state::AppState;

/// 一轮巡检的统计，写审计用。
#[derive(Debug, Clone, Default)]
pub struct HeartbeatReport {
    pub due: usize,
    pub todo: usize,
    pub nightly: usize,
    pub delivered: usize,
    pub muted: usize,
    /// 没有可用会话/设备时留在队列里的条数。
    pub queued: usize,
    /// 夜间沉淀投递出去的抽取任务数（录音 + 编码任务）。
    pub sedimented: usize,
    /// 夜间被衰减归档的记忆条数。
    pub decayed: usize,
    /// 夜间被归并（重复度更高 → 并入更完整的一条）的记忆条数。
    pub consolidated: usize,
}

#[derive(Debug, Clone)]
struct Candidate {
    category: NotificationCategory,
    dedupe_key: String,
    memory_id: Option<String>,
    title: String,
    body: String,
    score: f64,
    factors: serde_json::Value,
}

/// 起一个后台周期任务。只有 `memory.enabled && memory.heartbeat.enabled` 时才调用它。
pub fn spawn(state: AppState) -> tokio::task::JoinHandle<()> {
    let interval =
        Duration::from_millis(state.config.memory.heartbeat.scan_interval_ms.max(60_000));

    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            let report = run_once_at(&state, now_ms()).await;
            tracing::debug!(
                due = report.due,
                nightly = report.nightly,
                delivered = report.delivered,
                decayed = report.decayed,
                "记忆心跳完成"
            );
        }
    })
}

/// 跑一轮。任何一步失败都只记日志：心跳不该因为一条脏数据停摆。
pub async fn run_once_at(state: &AppState, now: i64) -> HeartbeatReport {
    let mut report = HeartbeatReport::default();
    if !state.config.memory.enabled || !state.config.memory.heartbeat.enabled {
        return report;
    }

    // 设置在 `memory` 层：`digest()` 与心跳读的是同一份权威值。
    let settings = crate::memory::settings::load(&state.pool).await;
    let mut candidates = Vec::new();

    match scan_due(&state.pool, now).await {
        Ok(mut items) => {
            report.due = items.len();
            candidates.append(&mut items);
        }
        Err(err) => tracing::warn!(%err, "临近项扫描失败"),
    }

    // 过期项：已经过了截止时间还没处理的事，归入"待办推进"。
    match scan_overdue(&state.pool, now).await {
        Ok(mut items) => {
            report.todo = items.len();
            candidates.append(&mut items);
        }
        Err(err) => tracing::warn!(%err, "过期项扫描失败"),
    }

    // 夜间整理：03:00 之后、且距上次超过 20 小时。整理内容本身在
    // `memory::maintenance`——手动「整理」按钮走的是同一份实现。
    let hour = crate::clock::hour_of_day_ms(now);
    if hour >= state.config.memory.heartbeat.nightly_after_hour
        && nightly_due(&state.pool, now).await
    {
        match state.memory.organize(now).await {
            Ok(organized) => {
                report.nightly = organized.recomputed as usize;
                report.sedimented = organized.sedimented as usize;
                report.decayed = organized.decayed as usize;
                report.consolidated = organized.consolidated as usize;

                candidates.push(Candidate {
                    category: NotificationCategory::DigestReport,
                    dedupe_key: format!("digest_report:{}", crate::clock::format_date_ms(now)),
                    memory_id: None,
                    title: "昨晚整理了记忆".to_string(),
                    body: nightly_body(organized),
                    score: 0.5,
                    factors: json!({
                        "nightly": organized.recomputed,
                        "decayed": organized.decayed,
                        "consolidated": organized.consolidated,
                    }),
                });

                // 节流水位只在真的跑完时推进：被占用跳过的一轮不算"整理过"。
                crate::memory::maintenance::mark_nightly(&state.pool, now).await;
            }
            // 手动整理正占着闸门：今晚跳过，下一轮心跳会再判定一次。
            Err(OrganizeError::Busy) => {
                tracing::debug!("上一轮整理还没结束，跳过本次夜间整理");
            }
            Err(OrganizeError::Disabled) => {}
        }
    }

    // 过期清标：挂在心跳上，进程重启后也能收敛。
    if let Err(err) = crate::grants::expire_due(&state.pool, now).await {
        tracing::warn!(%err, "清理过期执行授权失败");
    }

    // 先聚合再截断：否则"每日 2 条"会被同类条目占满，用户看到的是三条
    // 同一件事的提醒，而不是三件不同的事。
    let mut candidates = aggregate(candidates, now);

    candidates.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // 先算分再截断：截断之后还要留得住"为什么没推"。
    for candidate in candidates {
        let category = candidate.category.as_str();
        if settings.mute.iter().any(|item| item == category) {
            report.muted += 1;
            enqueue(&state.pool, &candidate, "muted", now).await;
            // 静音也要留痕：用户问"为什么没提醒我"时，审计要能回答。
            crate::memory::audit_reject(
                &state.pool,
                "memory.muted",
                json!({
                    "category": category,
                    "score": candidate.score,
                    "dedupe_key": candidate.dedupe_key,
                }),
            )
            .await;
            continue;
        }

        if report.delivered >= settings.daily_limit as usize {
            enqueue(&state.pool, &candidate, "queued", now).await;
            report.queued += 1;
            continue;
        }

        match deliver(state, &candidate, now).await {
            Ok(Delivery::Sent) => {
                report.delivered += 1;
                crate::memory::audit_reject(
                    &state.pool,
                    "memory.notified",
                    json!({
                        "category": category,
                        "score": candidate.score,
                        "dedupe_key": candidate.dedupe_key,
                    }),
                )
                .await;
            }
            // 24 小时内已经提醒过同一件事：什么都不做，也不再计数。
            Ok(Delivery::Duplicate) => {}
            Ok(Delivery::NoTarget) => {
                enqueue(&state.pool, &candidate, "queued", now).await;
                report.queued += 1;
            }
            Err(err) => {
                tracing::warn!(%err, "记忆提醒投递失败");
                enqueue(&state.pool, &candidate, "queued", now).await;
                report.queued += 1;
            }
        }
    }

    crate::memory::maintenance::write_json(&state.pool, "last_scan_at", json!(now)).await;

    crate::memory::audit_reject(
        &state.pool,
        "memory.heartbeat_run",
        json!({
            "due": report.due,
            "todo": report.todo,
            "nightly": report.nightly,
            "delivered": report.delivered,
            "muted": report.muted,
            "todo": report.todo,
            "sedimented": report.sedimented,
            "decayed": report.decayed,
            "consolidated": report.consolidated,
        }),
    )
    .await;

    report
}

/// 类别的中文名。通知标题里用它，避免把线缆值直接给用户看。
fn category_label(category: NotificationCategory) -> &'static str {
    match category {
        NotificationCategory::Due => "到期提醒",
        NotificationCategory::Todo => "待办推进",
        NotificationCategory::DigestReport => "整理报告",
    }
}

/// 同类聚合：同一类别在本次扫描里命中 ≥2 条时合成一条汇总。
///
/// 纯函数，不碰数据库：聚合规则要能被单测直接钉住。
/// 只合并 ≥2 条的组——单条保持原有 `dedupe_key`，否则"同一事项 24h 内
/// 只提醒一次"会退化成"同一类别每天只提醒一次"。
fn aggregate(candidates: Vec<Candidate>, now: i64) -> Vec<Candidate> {
    let mut groups: std::collections::BTreeMap<&'static str, Vec<Candidate>> =
        std::collections::BTreeMap::new();
    for candidate in candidates {
        groups
            .entry(candidate.category.as_str())
            .or_default()
            .push(candidate);
    }

    let mut out: Vec<Candidate> = Vec::new();
    for (code, mut items) in groups {
        if items.len() < 2 {
            out.append(&mut items);
            continue;
        }

        items.sort_by(|left, right| {
            right
                .score
                .partial_cmp(&left.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let category = items[0].category;
        let count = items.len();
        let head: Vec<String> = items
            .iter()
            .take(3)
            .map(|item| item.title.clone())
            .collect();

        out.push(Candidate {
            category,
            // 按类别 + 按天去重：汇总条目一天只该出现一次。
            dedupe_key: format!("agg:{code}:{}", crate::clock::format_date_ms(now)),
            memory_id: None,
            title: format!("{} · {count} 条", category_label(category)),
            body: format!("{} 等 {count} 条", head.join("、")),
            // 汇总条目取组内最高分：它代表这组里最紧急的那件事，
            // 不该因为"合并"而被排到后面。
            score: items[0].score,
            factors: json!({ "count": count }),
        });
    }

    out
}

/// 未来 24 小时内到期的生效记忆。
async fn scan_due(pool: &SqlitePool, now: i64) -> Result<Vec<Candidate>, sqlx::Error> {
    let window = 24 * 3_600_000;
    let rows: Vec<(String, String, i64, f64)> = sqlx::query_as(
        "SELECT id, content, due_at, importance FROM memories \
         WHERE deleted_at IS NULL AND status = 'active' AND sensitivity = 'normal' \
           AND due_at IS NOT NULL AND due_at >= ? AND due_at <= ? \
         ORDER BY due_at ASC LIMIT 50",
    )
    .bind(now)
    .bind(now + window)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|(id, content, due_at, importance)| {
            let hours_left = ((due_at - now) as f64 / 3_600_000.0).max(0.0);
            let urgency = (1.0 - hours_left / 24.0).clamp(0.0, 1.0);
            let score = 0.4 * urgency + 0.3 * importance + 0.2 * 0.5 + 0.1 * 0.6;

            Candidate {
                category: NotificationCategory::Due,
                // 同一件事 24 小时内只提醒一次：键里带日期而不是精确时间。
                dedupe_key: format!("due:{id}:{}", crate::clock::format_date_ms(now)),
                memory_id: Some(id),
                title: "记忆里有件事快到期了".to_string(),
                body: format!("{content}（{}）", crate::clock::format_date_ms(due_at)),
                score,
                factors: json!({
                    "urgency": urgency,
                    "importance": importance,
                    "staleness": 0.5,
                    "confidence": 0.6,
                }),
            }
        })
        .collect())
}

/// 整理报告的通知正文。
///
/// 没配模型时快照重算会被跳过，这时候只说"重算 0 个"会让用户以为整理没用；
/// 换成一句明确的说明，并给出仍然生效的两步结果。
fn nightly_body(organized: OrganizeReport) -> String {
    if organized.model_available {
        format!(
            "重算了 {} 个主体的状态，{} 个失败稍后重试。",
            organized.recomputed, organized.failed
        )
    } else {
        format!(
            "未配置模型，实体状态没有重算；归档 {} 条、归并 {} 条。",
            organized.decayed, organized.consolidated
        )
    }
}

/// 已经过了截止时间但仍生效的记忆 → "待办推进"。
///
/// 与 `scan_due` 互斥：那边只看 `due_at >= now`，这边只看 `due_at < now`，
/// 同一件事不会同时进两个类别。
async fn scan_overdue(pool: &SqlitePool, now: i64) -> Result<Vec<Candidate>, sqlx::Error> {
    let rows: Vec<(String, String, i64, f64)> = sqlx::query_as(
        "SELECT id, content, due_at, importance FROM memories \
         WHERE deleted_at IS NULL AND status = 'active' AND sensitivity = 'normal' \
           AND due_at IS NOT NULL AND due_at < ? \
         ORDER BY due_at ASC LIMIT 50",
    )
    .bind(now)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|(id, content, due_at, importance)| {
            let overdue_days = ((now - due_at) as f64 / 86_400_000.0).max(0.0);
            // 过期越久越"陈旧"，但封顶：一件事过期一个月不该比今天刚过的更吵。
            let staleness = (overdue_days / 7.0).clamp(0.0, 1.0);
            let score = 0.4 * 1.0 + 0.3 * importance + 0.2 * staleness + 0.1 * 0.6;

            Candidate {
                category: NotificationCategory::Todo,
                dedupe_key: format!("todo:{id}:{}", crate::clock::format_date_ms(now)),
                memory_id: Some(id),
                title: "这件事已经过期了".to_string(),
                body: format!("{content}（原定 {}）", crate::clock::format_date_ms(due_at)),
                score,
                factors: json!({
                    "urgency": 1.0,
                    "importance": importance,
                    "staleness": staleness,
                    "confidence": 0.6,
                }),
            }
        })
        .collect())
}

async fn nightly_due(pool: &SqlitePool, now: i64) -> bool {
    let last = crate::memory::maintenance::last_nightly_at(pool).await;
    now - last >= 20 * 3_600_000
}

/// 写一条通知。`dedupe_key` 唯一索引保证同一事项只留一条。
async fn enqueue(pool: &SqlitePool, candidate: &Candidate, status: &str, now: i64) {
    let result = sqlx::query(
        "INSERT OR IGNORE INTO memory_notifications \
          (id, category, dedupe_key, memory_id, title, body, score, factors_json, status, \
           deliver_at, message_id, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)",
    )
    .bind(crate::ids::new_id("ntf"))
    .bind(candidate.category.as_str())
    .bind(&candidate.dedupe_key)
    .bind(&candidate.memory_id)
    .bind(&candidate.title)
    .bind(&candidate.body)
    .bind(candidate.score)
    .bind(candidate.factors.to_string())
    .bind(status)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await;

    if let Err(err) = result {
        tracing::warn!(%err, "记忆提醒入队失败");
    }
}

/// 一次投递的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Delivery {
    /// 已投递（消息写进了提醒会话）。
    Sent,
    /// 去重键已存在：同一件事 24 小时内不再提醒。
    Duplicate,
    /// 没有可用会话或设备：留在队列里，等下次有目标再投。
    NoTarget,
}

/// 投递到"提醒会话"：优先复用已有的，没有就新建一个 WORK 会话。
///
/// **先去重再发消息**：唯一索引 `dedupe_key` 就是"同一事项只提醒一次"的闸门。
/// 顺序反了的话，消息已经写进会话、行却被忽略，用户第二天还会再看到一遍。
///
/// 没有可用项目或设备时返回 [`Delivery::NoTarget`]，调用方把通知留在 `queued`——
/// 不硬造外键，也不替用户挑一个不存在的设备。
async fn deliver(
    state: &AppState,
    candidate: &Candidate,
    now: i64,
) -> Result<Delivery, sqlx::Error> {
    let Some((conversation_id, _device_id)) = reminder_target(state).await? else {
        return Ok(Delivery::NoTarget);
    };

    // 先占位（status 仍是 queued）：命中唯一索引说明已经提醒过。
    let inserted = sqlx::query(
        "INSERT OR IGNORE INTO memory_notifications \
          (id, category, dedupe_key, memory_id, title, body, score, factors_json, status, \
           deliver_at, message_id, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', NULL, NULL, ?, ?)",
    )
    .bind(crate::ids::new_id("ntf"))
    .bind(candidate.category.as_str())
    .bind(&candidate.dedupe_key)
    .bind(&candidate.memory_id)
    .bind(&candidate.title)
    .bind(&candidate.body)
    .bind(candidate.score)
    .bind(candidate.factors.to_string())
    .bind(now)
    .bind(now)
    .execute(&state.pool)
    .await?
    .rows_affected();

    if inserted == 0 {
        return Ok(Delivery::Duplicate);
    }

    let message_id = crate::ids::new_id("msg");
    crate::conversation::append_assistant_with_sources(
        &state.pool,
        &message_id,
        &conversation_id,
        &format!("{}\n\n{}", candidate.title, candidate.body),
        &[],
        &[],
        &[],
        // 提醒消息没有工具调用，也就没有生成产物与执行过程。
        &[],
        &[],
        crate::conversation::MessageMetrics::new(0, None).with_finish_reason(protocol::FINISH_STOP),
    )
    .await
    .map_err(|err| sqlx::Error::Protocol(format!("写提醒消息失败: {err}")))?;

    // 消息写成功才转 delivered；写失败时行停在 queued，用户能看到"还没送到"。
    sqlx::query(
        "UPDATE memory_notifications SET status = 'delivered', message_id = ?, deliver_at = ?, \
           updated_at = ? WHERE dedupe_key = ?",
    )
    .bind(&message_id)
    .bind(now)
    .bind(now)
    .bind(&candidate.dedupe_key)
    .execute(&state.pool)
    .await?;

    Ok(Delivery::Sent)
}

/// 找"提醒会话"：优先 `title = '记忆提醒'` 的 WORK 会话，其次任意可用设备。
async fn reminder_target(state: &AppState) -> Result<Option<(String, String)>, sqlx::Error> {
    let existing: Option<(String, String)> = sqlx::query_as(
        "SELECT c.id, c.device_id FROM conversations c \
         WHERE c.deleted_at IS NULL AND c.title = '记忆提醒' \
         ORDER BY c.updated_at DESC LIMIT 1",
    )
    .fetch_optional(&state.pool)
    .await?;
    if let Some(found) = existing {
        return Ok(Some(found));
    }

    let device: Option<(String,)> = sqlx::query_as(
        // devices 没有 created_at 列：按配对时间取最早的一台即可。
        "SELECT id FROM devices WHERE revoked_at IS NULL ORDER BY paired_at ASC LIMIT 1",
    )
    .fetch_optional(&state.pool)
    .await?;
    let Some((device_id,)) = device else {
        return Ok(None);
    };

    let project: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM projects WHERE deleted_at IS NULL AND mode = 'work' \
         ORDER BY created_at ASC LIMIT 1",
    )
    .fetch_optional(&state.pool)
    .await?;
    let Some((project_id,)) = project else {
        return Ok(None);
    };

    let now = now_ms();
    let conversation_id = crate::ids::new_id("conv");
    sqlx::query(
        "INSERT INTO conversations (id, project_id, device_id, title, created_at, updated_at) \
         VALUES (?, ?, ?, '记忆提醒', ?, ?)",
    )
    .bind(&conversation_id)
    .bind(&project_id)
    .bind(&device_id)
    .bind(now)
    .bind(now)
    .execute(&state.pool)
    .await?;

    Ok(Some((conversation_id, device_id)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(category: NotificationCategory, title: &str, score: f64) -> Candidate {
        Candidate {
            category,
            dedupe_key: format!("k:{title}"),
            memory_id: Some(title.to_string()),
            title: title.to_string(),
            body: title.to_string(),
            score,
            factors: json!({}),
        }
    }

    #[test]
    fn aggregate_merges_same_category() {
        let merged = aggregate(
            vec![
                candidate(NotificationCategory::Due, "交周报", 0.9),
                candidate(NotificationCategory::Due, "评审会", 0.7),
                candidate(NotificationCategory::Due, "续签合同", 0.5),
            ],
            1_700_000_000_000,
        );

        assert_eq!(merged.len(), 1, "同类三条应合成一条");
        assert!(merged[0].dedupe_key.starts_with("agg:due:"));
        assert!(merged[0].body.contains("等 3 条"));
        assert_eq!(merged[0].score, 0.9, "汇总条目取组内最高分");
        assert_eq!(merged[0].memory_id, None);
    }

    #[test]
    fn aggregate_keeps_single_and_other_categories() {
        let merged = aggregate(
            vec![
                candidate(NotificationCategory::Due, "交周报", 0.9),
                candidate(NotificationCategory::Todo, "过期的事", 0.8),
            ],
            1_700_000_000_000,
        );

        assert_eq!(merged.len(), 2, "不同类别各自保留");
        assert!(
            merged
                .iter()
                .all(|item| !item.dedupe_key.starts_with("agg:")),
            "单条不该被套上聚合前缀，否则按天去重的语义会被改写"
        );
    }
}
