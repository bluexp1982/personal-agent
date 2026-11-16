//! 自动抽取：队列、模型调用、五道闸、批次。
//!
//! 范式照抄 `recording/summary.rs`：`Semaphore` 限并发 + `running` 集合防重入 +
//! 日调用计数。区别只有一个：抽取失败**绝不能**影响对话——`submit` 立即返回，
//! 失败只写一条审计与 warn 日志。
//!
//! 五道闸（开发方案 6.6）：
//! 1. 证据：`quote` 必须是源文本归一化后的子串；`support_span` 越界**降级为候选**而不是丢弃；
//! 2. 敏感度：命中密钥/证件号丢弃，命中隐私类降级为 `private`；
//! 3. 置信度：低于阈值进候选，不参与读取；
//! 4. 去重：同主体 + 同内容合并证据，不新增行；
//! 5. 预算：日调用数、单条长度、候选积压，任一超限就不抽。

use std::collections::HashSet;
use std::sync::Arc;

use protocol::{
    EvidenceSource, MemoryKind, MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource,
    MemoryStatus, TimeScope,
};
use sqlx::SqlitePool;
use tokio::sync::{Mutex, Semaphore};

use super::gates::{self, Decision, GateConfig, RawCandidate, RejectReason};
use super::store::{EvidenceDraft, MemoryDraft, MemoryStore};
use super::{entity, privacy, tokenize, MemoryError, MemoryService};
use crate::clock::{format_date_ms, now_ms};

/// 抽取用的系统提示。要求“只抽有原文依据的断言”，并要求 support_span 可校验。
pub const EXTRACT_SYSTEM_PROMPT: &str =
    "你在从一段对话/任务记录里抽取\"值得长期记住的事实\"。只输出 JSON 数组，不要解释。

要求：
1. 只能抽取有原文依据的断言，evidence_quote 必须逐字复制原文的连续片段；
2. support_span 必须指出断言依赖 evidence_quote 里的哪一小段，且必须是它的子串；
3. 一条断言只表达一件事，不超过 500 字；
4. 偏好/品味/习惯 → kind=preference；稳定身份事实 → kind=profile；
   某个时间发生的事 → kind=event；仓库约定与决策 → kind=project；
5. 不确定就不要抽。抽错比漏抽代价大。

每条对象字段：assertion、subject、predicate、time_scope（可选 {from,to,label}）、
evidence_quote、support_span、confidence（0~1）、kind。";

/// 一次抽取任务。
#[derive(Debug, Clone)]
pub struct ExtractJob {
    pub batch_id: String,
    pub trace_id: String,
    pub source: ExtractSource,
}

#[derive(Debug, Clone)]
pub enum ExtractSource {
    Session {
        conversation_id: String,
        user_message_id: String,
        assistant_message_id: String,
    },
    Task {
        task_id: String,
    },
    Recording {
        recording_id: String,
    },
    CodeTask {
        task_id: String,
    },
}

impl ExtractSource {
    fn kind(&self) -> EvidenceSource {
        match self {
            Self::Session { .. } => EvidenceSource::Message,
            Self::Task { .. } => EvidenceSource::Task,
            Self::Recording { .. } => EvidenceSource::Recording,
            Self::CodeTask { .. } => EvidenceSource::CodeTask,
        }
    }
}

/// 限并发 + 防重入。
#[derive(Debug)]
pub struct ExtractQueue {
    semaphore: Arc<Semaphore>,
    running: Arc<Mutex<HashSet<String>>>,
}

impl ExtractQueue {
    pub fn new(max_concurrency: usize) -> Self {
        Self {
            semaphore: Arc::new(Semaphore::new(max_concurrency.max(1))),
            running: Arc::new(Mutex::new(HashSet::new())),
        }
    }
}

/// 抽出来的候选（模型输出的最小契约）。
#[derive(Debug, Clone)]
pub struct ExtractedCandidate {
    pub assertion: String,
    pub kind: String,
    pub subject: Option<String>,
    pub predicate: Option<String>,
    pub time_scope: Option<TimeScope>,
    pub evidence_quote: String,
    pub support_span: Option<String>,
    pub confidence: f32,
}

#[derive(Debug, Clone, Default)]
pub struct ExtractReport {
    pub batches: usize,
    pub accepted: usize,
    pub candidates: usize,
    pub rejected: usize,
    pub skipped: bool,
}

impl MemoryService {
    /// 投递一次抽取。**立即返回**：失败与 panic 都不冒泡到对话。
    pub fn submit_extract(&self, job: ExtractJob) {
        if !self.extract_enabled() {
            return;
        }
        let service = self.clone();
        tokio::spawn(async move {
            match super::extract::run_job(&service, job).await {
                Ok(report) => {
                    tracing::debug!(
                        batches = report.batches,
                        accepted = report.accepted,
                        candidates = report.candidates,
                        rejected = report.rejected,
                        "记忆抽取完成"
                    );
                }
                Err(err) => tracing::warn!(%err, "记忆抽取失败"),
            }
        });
    }
}

/// 跑一次抽取。`Err` 只用于"整个批次失败"，单条候选的问题走审计。
pub async fn run_job(
    service: &MemoryService,
    job: ExtractJob,
) -> Result<ExtractReport, MemoryError> {
    let config = service.config().extract.clone();

    // 防重入：同一个 batch_id 只跑一次。
    {
        let mut running = service.extract_queue().running.lock().await;
        if !running.insert(job.batch_id.clone()) {
            return Ok(ExtractReport::default());
        }
    }

    let _permit = service
        .extract_queue()
        .semaphore
        .acquire()
        .await
        .map_err(|_| MemoryError::ModelUnavailable)?;

    let result = run_inner(service, &job, &config).await;

    service
        .extract_queue()
        .running
        .lock()
        .await
        .remove(&job.batch_id);

    result
}

async fn run_inner(
    service: &MemoryService,
    job: &ExtractJob,
    config: &crate::config::MemoryExtractConfig,
) -> Result<ExtractReport, MemoryError> {
    let pool = service.pool();
    let now = now_ms();

    let segments = match load_source_text(pool, job).await {
        Ok(segments) => segments,
        Err(err) => {
            // 读不到源文本属于"整批失败"：必须留痕，否则用户只会看到"聊了但没记忆"。
            super::audit_reject(
                pool,
                "memory.extract_failed",
                serde_json::json!({
                    "source_kind": job.source.kind().as_str(),
                    "error_code": "source_error",
                }),
            )
            .await;
            return Err(err);
        }
    };
    if segments.is_empty() {
        return Ok(ExtractReport::default());
    }

    // 闸 5：预算与积压。超限就直接不抽，不排队堆积。
    if let Err(reason) = check_budget(pool, config).await? {
        super::audit_reject(
            pool,
            "memory.extract_skipped",
            serde_json::json!({
                "reason": reason,
                "source_kind": job.source.kind().as_str(),
            }),
        )
        .await;
        return Ok(ExtractReport {
            skipped: true,
            ..ExtractReport::default()
        });
    }

    let model = service.model().ok_or(MemoryError::ModelUnavailable)?;

    let mut report = ExtractReport::default();
    let mut chunk_index = 0usize;

    for (source_id, text) in segments {
        for chunk in split_input(&text, config.max_input_chars) {
            let batch_id = if chunk_index == 0 {
                job.batch_id.clone()
            } else {
                format!("{}-{chunk_index}", job.batch_id)
            };
            chunk_index += 1;
            report.batches += 1;

            let prompt = format!(
                "原始记录（{}）：\n<record>\n{}\n</record>",
                format_date_ms(now),
                chunk
            );
            let completion = match model
                .complete(EXTRACT_SYSTEM_PROMPT, &prompt, Some(1200))
                .await
            {
                Ok(completion) => completion,
                Err(err) => {
                    // 闸 5 之外的失败：整批放弃，只记原因码。
                    super::audit_reject(
                        pool,
                        "memory.extract_failed",
                        serde_json::json!({
                            "source_kind": job.source.kind().as_str(),
                            "error_code": "model_error",
                        }),
                    )
                    .await;
                    tracing::warn!(%err, "抽取调用模型失败");
                    return Ok(report);
                }
            };

            for candidate in parse_candidates(&completion.text) {
                match persist(
                    service, &candidate, &chunk, &batch_id, &source_id, job, config, now,
                )
                .await?
                {
                    Decision::Active => report.accepted += 1,
                    Decision::Candidate => report.candidates += 1,
                    Decision::Reject => report.rejected += 1,
                }
            }
        }
    }

    // 记一天一次：放在最后，失败批不计入额度。
    record_daily_call(pool, report.batches).await?;
    Ok(report)
}

#[allow(clippy::too_many_arguments)]
async fn persist(
    service: &MemoryService,
    candidate: &ExtractedCandidate,
    source_text: &str,
    batch_id: &str,
    source_id: &str,
    job: &ExtractJob,
    config: &crate::config::MemoryExtractConfig,
    now: i64,
) -> Result<Decision, MemoryError> {
    let pool = service.pool();
    let raw = RawCandidate {
        assertion: candidate.assertion.clone(),
        subject: candidate.subject.clone(),
        predicate: candidate.predicate.clone(),
        evidence_quote: candidate.evidence_quote.clone(),
        support_span: candidate.support_span.clone(),
        confidence: candidate.confidence,
    };

    let verdict = gates::evaluate(
        &raw,
        source_text,
        &GateConfig {
            confidence_threshold: config.confidence_threshold,
            max_content_chars: config.max_content_chars,
            max_input_chars: config.max_input_chars,
            daily_calls: config.daily_calls,
            pending_limit: config.pending_limit,
        },
    );

    if verdict.decision == Decision::Reject {
        let reason = verdict.reason.map(RejectReason::code).unwrap_or("unknown");
        super::audit_reject(
            pool,
            "memory.rejected",
            serde_json::json!({
                "reason": reason,
                "source_kind": job.source.kind().as_str(),
                "source_id": source_id,
            }),
        )
        .await;
        return Ok(Decision::Reject);
    }

    // 闸 4：去重。命中就只追加证据，不新增行。
    let store = MemoryStore::new(pool);
    let subject_norm = candidate
        .subject
        .as_deref()
        .map(tokenize::normalize_for_match)
        .filter(|norm| !norm.is_empty());

    if let Some(existing) = store
        .find_duplicate(subject_norm.as_deref(), &verdict.assertion)
        .await?
    {
        store
            .add_evidence(
                &existing.id,
                EvidenceDraft {
                    source_kind: job.source.kind(),
                    source_id: source_id.to_string(),
                    quote: verdict.quote.clone(),
                    support_span: span_of(&verdict, candidate),
                    created_at: now,
                },
            )
            .await?;
        return Ok(verdict.decision);
    }

    let kind = parse_kind(&candidate.kind);

    // 更简的同义断言：已有一条更完整的记忆覆盖它 → 只追加证据，不新增行。
    // 这是"越说越简"不再制造重复的关键一步（夜间归并是兜底）。
    if matches!(kind, MemoryKind::Preference | MemoryKind::Profile) {
        if let Some(existing) = store
            .find_subsuming(subject_norm.as_deref(), kind, &verdict.assertion)
            .await?
        {
            store
                .add_evidence(
                    &existing.id,
                    EvidenceDraft {
                        source_kind: job.source.kind(),
                        source_id: source_id.to_string(),
                        quote: verdict.quote.clone(),
                        support_span: span_of(&verdict, candidate),
                        created_at: now,
                    },
                )
                .await?;
            return Ok(verdict.decision);
        }
    }

    let sensitivity = match verdict.sensitivity {
        privacy::Classification::Private => MemorySensitivity::Private,
        _ => MemorySensitivity::Normal,
    };
    let status = if verdict.decision == Decision::Active {
        MemoryStatus::Active
    } else {
        MemoryStatus::Candidate
    };

    // 项目类记忆默认绑当前项目；会话来源才有 project，任务来源从任务所属会话取。
    let project_id = project_of(pool, job).await?;
    let scope = if kind == protocol::MemoryKind::Project && project_id.is_some() {
        MemoryScope::Project
    } else {
        MemoryScope::Global
    };

    let memory = store
        .insert(MemoryDraft {
            kind,
            pipeline: MemoryPipeline::Subjective,
            status,
            scope,
            project_id: project_id.clone(),
            sensitivity,
            content: verdict.assertion.clone(),
            subject: candidate.subject.clone(),
            predicate: candidate.predicate.clone(),
            time_scope: candidate.time_scope.clone(),
            due_at: candidate.time_scope.as_ref().and_then(|scope| scope.from),
            confidence: candidate.confidence,
            importance: super::store::importance_for(kind, 1, false, 0),
            pinned: false,
            batch_id: Some(batch_id.to_string()),
            source: MemorySource::Session,
            valid_from: now,
        })
        .await?;

    store
        .add_evidence(
            &memory.id,
            EvidenceDraft {
                source_kind: job.source.kind(),
                source_id: source_id.to_string(),
                quote: verdict.quote.clone(),
                support_span: span_of(&verdict, candidate),
                created_at: now,
            },
        )
        .await?;

    // 主观事实被更新：同主体 + 同谓词的旧生效记忆转"被取代"（行与证据都留着）。
    // 只对 preference/profile 做：事件类事实本来就可以并存，靠 `conflicting` 提示分歧。
    if matches!(kind, MemoryKind::Preference | MemoryKind::Profile) {
        if let (Some(subject), Some(predicate)) = (
            candidate.subject.as_deref().map(str::trim),
            candidate.predicate.as_deref().map(str::trim),
        ) {
            // 先按"同谓词取代"处理，再按"覆盖关系"兜底：谓词写得不一样、
            // 但新说法更完整时，旧的同样该退场。
            match store
                .supersede_conflicting(subject, predicate, &memory.id, &verdict.assertion)
                .await
            {
                Ok(count) if count > 0 => {
                    tracing::info!(
                        superseded = count,
                        memory_id = %memory.id,
                        "新事实取代了旧记忆"
                    );
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(%err, "取代旧记忆失败"),
            }

            // 覆盖关系兜底：谓词不同但新说法更完整时，旧的同样退场。
            match store
                .supersede_subsumed(
                    subject_norm.as_deref(),
                    kind,
                    &memory.id,
                    &verdict.assertion,
                )
                .await
            {
                Ok(count) if count > 0 => {
                    tracing::info!(
                        absorbed = count,
                        memory_id = %memory.id,
                        "新说法覆盖了更简的旧记忆"
                    );
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(%err, "覆盖归并失败"),
            }
        }
    }

    // 有主体才建实体：没有主体的记忆不该硬凑一个"未知实体"。
    if let Some(subject) = candidate
        .subject
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        if let Ok((entity_id, _)) = entity::match_or_create(
            pool,
            entity::EntityDraft {
                entity_type: protocol::EntityType::Person,
                name: subject.to_string(),
                project_id,
                project_path: None,
            },
            &memory.id,
            now,
            0.7,
        )
        .await
        {
            let _ = entity_id;
        }
    }

    super::audit_reject(
        pool,
        "memory.created",
        serde_json::json!({
            "kind": kind.as_str(),
            "pipeline": "subjective",
            "source": "session",
            "chars": verdict.assertion.chars().count(),
            "batch_id": batch_id,
            "has_span": span_of(&verdict, candidate).is_some(),
        }),
    )
    .await;

    Ok(verdict.decision)
}

async fn check_budget(
    pool: &SqlitePool,
    config: &crate::config::MemoryExtractConfig,
) -> Result<Result<(), &'static str>, MemoryError> {
    let day = format_date_ms(now_ms());
    let calls: Option<i64> =
        sqlx::query_scalar("SELECT calls FROM memory_extract_daily WHERE day = ?")
            .bind(&day)
            .fetch_optional(pool)
            .await?;
    if calls.unwrap_or(0) >= i64::from(config.daily_calls) {
        return Ok(Err("daily_budget"));
    }

    let pending: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memories WHERE status = 'candidate'")
            .fetch_one(pool)
            .await?;
    if pending >= config.pending_limit as i64 {
        return Ok(Err("pending_limit"));
    }

    Ok(Ok(()))
}

async fn record_daily_call(pool: &SqlitePool, calls: usize) -> Result<(), MemoryError> {
    let day = format_date_ms(now_ms());
    sqlx::query(
        "INSERT INTO memory_extract_daily (day, calls, candidates, rejected, chars, updated_at) \
         VALUES (?, ?, 0, 0, 0, ?) \
         ON CONFLICT(day) DO UPDATE SET calls = calls + excluded.calls, updated_at = excluded.updated_at",
    )
    .bind(&day)
    .bind(calls as i64)
    .bind(now_ms())
    .execute(pool)
    .await?;
    Ok(())
}

async fn project_of(pool: &SqlitePool, job: &ExtractJob) -> Result<Option<String>, MemoryError> {
    match &job.source {
        ExtractSource::Session {
            conversation_id, ..
        } => {
            let row: Option<(Option<String>,)> =
                sqlx::query_as("SELECT project_id FROM conversations WHERE id = ?")
                    .bind(conversation_id)
                    .fetch_optional(pool)
                    .await?;
            Ok(row.and_then(|(id,)| id))
        }
        ExtractSource::Task { task_id } | ExtractSource::CodeTask { task_id } => {
            let row: Option<(Option<String>,)> = sqlx::query_as(
                "SELECT c.project_id FROM tasks t JOIN conversations c ON c.id = t.conversation_id \
                 WHERE t.id = ?",
            )
            .bind(task_id)
            .fetch_optional(pool)
            .await?;
            Ok(row.and_then(|(id,)| id))
        }
        ExtractSource::Recording { .. } => Ok(None),
    }
}

/// 取源文本。会话只取 user + assistant 正文，**明确排除 system/tool**。
async fn load_source_text(
    pool: &SqlitePool,
    job: &ExtractJob,
) -> Result<Vec<(String, String)>, MemoryError> {
    match &job.source {
        ExtractSource::Session {
            user_message_id,
            assistant_message_id,
            ..
        } => {
            // 消息表没有 `content` 列：正文是 `content_json` 里的 `text`。
            // 这一句曾经写成 `SELECT ... content`，导致**会话来源的抽取全部静默失败**
            // （SQL 报错被 spawn 里的 warn 吞掉），只有录音/任务来源能产出记忆。
            let rows: Vec<(String, String, String)> = sqlx::query_as(
                "SELECT id, role, content_json FROM messages \
                 WHERE id IN (?, ?) AND role IN ('user','assistant') ORDER BY created_at ASC",
            )
            .bind(user_message_id)
            .bind(assistant_message_id)
            .fetch_all(pool)
            .await?;

            let text = rows
                .iter()
                .map(|(_, role, content_json)| {
                    format!(
                        "[{role}] {}",
                        crate::conversation::content_text(content_json)
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");

            if text.trim().is_empty() {
                return Ok(Vec::new());
            }
            Ok(vec![(user_message_id.clone(), text)])
        }
        ExtractSource::Recording { recording_id } => {
            let row: Option<(Option<String>,)> =
                sqlx::query_as("SELECT summary FROM recordings WHERE id = ?")
                    .bind(recording_id)
                    .fetch_optional(pool)
                    .await?;
            Ok(row
                .and_then(|(summary,)| summary)
                .filter(|summary| !summary.trim().is_empty())
                .map(|summary| vec![(recording_id.clone(), summary)])
                .unwrap_or_default())
        }
        ExtractSource::Task { task_id } | ExtractSource::CodeTask { task_id } => {
            let row: Option<(Option<String>, Option<String>)> =
                sqlx::query_as("SELECT skill, plan_json FROM tasks WHERE id = ?")
                    .bind(task_id)
                    .fetch_optional(pool)
                    .await?;

            let steps: Vec<(String, Option<String>)> = sqlx::query_as(
                "SELECT name, output_json FROM task_steps WHERE task_id = ? ORDER BY seq ASC",
            )
            .bind(task_id)
            .fetch_all(pool)
            .await?;

            let (skill, plan) = row.unwrap_or((None, None));
            let text = format_task_source(skill.as_deref(), plan.as_deref(), &steps);
            if text.trim().is_empty() {
                return Ok(Vec::new());
            }
            Ok(vec![(task_id.clone(), text)])
        }
    }
}

/// 任务来源的抽取文本：技能、计划与各步骤产出。
///
/// 抽成纯函数是为了能直接测：`output_json` 是这里唯一的解析点，也是
/// "把 JSON 信封当正文写进记忆"的唯一入口。升级前它一直是空列，改存
/// `{"summary","at"}` 之后如果直接拼字符串，记忆里会出现成片的花括号。
fn format_task_source(
    skill: Option<&str>,
    plan: Option<&str>,
    steps: &[(String, Option<String>)],
) -> String {
    let mut text = String::new();
    if let Some(skill) = skill {
        text.push_str(&format!("任务技能：{skill}\n"));
    }
    if let Some(plan) = plan {
        text.push_str(&format!("任务计划：{plan}\n"));
    }
    for (name, output) in steps {
        text.push_str(&format!("步骤：{name}\n"));
        // 兼容 `{"summary","at"}` 信封与纯文本（历史数据、其它写入方）。
        if let Some(raw) = output {
            if let Some((summary, _)) = crate::task::parse_step_output(raw) {
                text.push_str(&format!("产出：{summary}\n"));
            }
        }
    }
    text
}

/// 长输入按消息边界切，不截断半句。
fn split_input(text: &str, max_chars: usize) -> Vec<String> {
    let total = text.chars().count();
    if total <= max_chars {
        return vec![text.to_string()];
    }

    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut current_chars = 0;

    for line in text.split_inclusive('\n') {
        let line_chars = line.chars().count();
        if current_chars + line_chars > max_chars && !current.is_empty() {
            chunks.push(std::mem::take(&mut current));
            current_chars = 0;
        }
        current.push_str(line);
        current_chars += line_chars;
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

/// 解析模型输出的 JSON 数组。非 JSON / 字段缺失一律丢弃。
pub fn parse_candidates(raw: &str) -> Vec<ExtractedCandidate> {
    let cleaned = strip_code_fence(raw);
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&cleaned) else {
        return Vec::new();
    };
    let items: Vec<serde_json::Value> = match value.as_array() {
        Some(items) => items.clone(),
        None => return Vec::new(),
    };

    let mut out = Vec::new();
    for item in &items {
        let Some(assertion) = item["assertion"].as_str().map(str::trim) else {
            continue;
        };
        let Some(quote) = item["evidence_quote"].as_str() else {
            continue;
        };
        if assertion.is_empty() || quote.trim().is_empty() {
            continue;
        }

        let time_scope = item
            .get("time_scope")
            .filter(|value| value.is_object())
            .and_then(|value| serde_json::from_value::<TimeScope>(value.clone()).ok());

        out.push(ExtractedCandidate {
            assertion: assertion.to_string(),
            kind: item["kind"].as_str().unwrap_or("preference").to_string(),
            subject: item["subject"].as_str().map(str::to_string),
            predicate: item["predicate"].as_str().map(str::to_string),
            time_scope,
            evidence_quote: quote.to_string(),
            support_span: item["support_span"].as_str().map(str::to_string),
            confidence: item["confidence"].as_f64().unwrap_or(0.5) as f32,
        });
    }
    out
}

/// 模型偶尔会把 JSON 包在 ```json 里。
fn strip_code_fence(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed.starts_with("```") {
        return trimmed.to_string();
    }
    let without_open = trimmed
        .trim_start_matches("```json")
        .trim_start_matches("```");
    without_open.trim_end_matches("```").trim().to_string()
}

fn parse_kind(raw: &str) -> protocol::MemoryKind {
    protocol::MemoryKind::parse(raw).unwrap_or(protocol::MemoryKind::Preference)
}

/// `support_span` 只有在闸 1 没降级时才写；降级意味着 span 不在 quote 里，
/// 存进去会让详情页的高亮静默失效。
fn span_of(verdict: &gates::GateVerdict, candidate: &ExtractedCandidate) -> Option<String> {
    if verdict.notes.is_empty() {
        candidate.support_span.clone()
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_json_array() {
        let raw = r#"[{"assertion":"报销走飞书","kind":"preference","evidence_quote":"我们报销走飞书","support_span":"报销走飞书","confidence":0.9}]"#;
        let parsed = parse_candidates(raw);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].assertion, "报销走飞书");
    }

    #[test]
    fn parses_fenced_json() {
        let raw = "```json\n[{\"assertion\":\"甲\",\"evidence_quote\":\"甲\"}]\n```";
        assert_eq!(parse_candidates(raw).len(), 1);
    }

    #[test]
    fn drops_malformed_items() {
        let raw = r#"[{"assertion":"无依据"},{"evidence_quote":"只有引文"},{"assertion":"好的","evidence_quote":"好的"}]"#;
        let parsed = parse_candidates(raw);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].assertion, "好的");
    }

    #[test]
    fn task_source_reads_step_output_envelope_without_braces() {
        // 过程摘要现在是 {"summary","at"} 信封：拼进记忆的必须是摘要正文。
        let steps = vec![
            (
                "执行编码".to_string(),
                Some(
                    serde_json::json!({
                        "summary": "工具：Bash（只读）git status\n完成：clean",
                        "at": 1_700_000_000_000_i64,
                    })
                    .to_string(),
                ),
            ),
            // 纯文本（历史数据/其它写入方）照旧。
            ("生成方案".to_string(), Some("行程草案".to_string())),
            ("无产出".to_string(), None),
        ];

        let text = format_task_source(Some("trip-plan"), Some("[]"), &steps);
        assert!(text.contains("任务技能：trip-plan"), "{text}");
        assert!(text.contains("步骤：执行编码\n"), "{text}");
        assert!(
            text.contains("产出：工具：Bash（只读）git status\n完成：clean"),
            "{text}"
        );
        assert!(text.contains("产出：行程草案"), "{text}");
        assert!(
            !text.contains('{'),
            "不能把 JSON 信封当正文写进记忆：{text}"
        );
        assert!(
            !text.contains("1700000000000"),
            "时间戳不该进记忆输入：{text}"
        );
    }

    #[test]
    fn splits_by_line_boundary() {
        let text = "第一行内容\n第二行内容\n第三行内容\n";
        let chunks = split_input(text, 14);
        assert!(chunks.len() > 1);
        for chunk in &chunks {
            assert!(chunk.chars().count() <= 14);
        }
        assert_eq!(chunks.join(""), text, "切分不能丢字符");
    }
}
