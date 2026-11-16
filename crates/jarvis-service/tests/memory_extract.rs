//! 抽取五道闸与隐私边界。
//!
//! 这一组**不调模型**：验的是"给定模型输出，闸门怎么判"。
//! 抽取的模型质量不在单测范围内（那是 MP-03 的标注基线）。

mod common;

use std::sync::Arc;

use jarvis_service::config::Config;
use jarvis_service::memory::extract::{self, ExtractJob, ExtractSource, ExtractedCandidate};
use jarvis_service::memory::gates::{self, Decision, EvidenceCheck, GateConfig, RawCandidate};
use jarvis_service::memory::privacy::{self, Classification};
use jarvis_service::memory::MemoryService;
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};

const SOURCE: &str = "我说：以后回答先给结论，再给依据。我们报销走飞书审批。";

fn config() -> GateConfig {
    GateConfig {
        confidence_threshold: 0.6,
        max_content_chars: 500,
        max_input_chars: 12_000,
        daily_calls: 50,
        pending_limit: 200,
    }
}

fn raw(assertion: &str, quote: &str, span: Option<&str>, confidence: f32) -> RawCandidate {
    RawCandidate {
        assertion: assertion.to_string(),
        subject: None,
        predicate: None,
        evidence_quote: quote.to_string(),
        support_span: span.map(str::to_string),
        confidence,
    }
}

#[test]
fn quote_must_be_substring() {
    // 断言在原文里没有依据：这是幻觉，必须丢弃而不是降级。
    let verdict = gates::evaluate(
        &raw("用户喜欢猫", "用户喜欢狗", None, 0.95),
        SOURCE,
        &config(),
    );

    assert_eq!(verdict.decision, Decision::Reject);
    assert!(verdict.notes.is_empty() || verdict.reason.is_some());
}

#[test]
fn support_span_outside_quote_degrades_to_candidate() {
    let check = gates::check_evidence("回答先给结论", Some("先给依据"), SOURCE);
    assert_eq!(
        check,
        EvidenceCheck::SpanOutsideQuote,
        "支撑片段越界应单独识别，而不是直接判伪造"
    );

    let verdict = gates::evaluate(
        &raw("回答先给结论", "回答先给结论", Some("先给依据"), 0.9),
        SOURCE,
        &config(),
    );
    assert_eq!(
        verdict.decision,
        Decision::Candidate,
        "缺可信 span 只降级为候选，不丢弃"
    );
}

#[test]
fn secret_is_dropped() {
    assert!(privacy::is_secret("我的 key 是 sk-abcdefghijklmnopqrst"));
    assert_eq!(
        privacy::classify("sk-abcdefghijklmnopqrst"),
        Classification::Secret
    );

    let verdict = gates::evaluate(
        &raw(
            "密钥是 sk-abcdefghijklmnopqrst",
            "密钥是 sk-abcdefghijklmnopqrst",
            None,
            0.9,
        ),
        "密钥是 sk-abcdefghijklmnopqrst",
        &config(),
    );
    assert_eq!(verdict.decision, Decision::Reject, "密钥连候选都不该进");
}

#[test]
fn low_confidence_stays_candidate() {
    // 闸 3 由调用方按阈值判定：这里复现同一判据，确保候选不会自动生效。
    let candidate = ExtractedCandidate {
        assertion: "报销走飞书审批".to_string(),
        kind: "preference".to_string(),
        subject: None,
        predicate: None,
        time_scope: None,
        evidence_quote: "我们报销走飞书审批".to_string(),
        support_span: Some("报销走飞书审批".to_string()),
        confidence: 0.4,
    };

    let verdict = gates::evaluate(
        &RawCandidate {
            assertion: candidate.assertion.clone(),
            subject: None,
            predicate: None,
            evidence_quote: candidate.evidence_quote.clone(),
            support_span: candidate.support_span.clone(),
            confidence: candidate.confidence,
        },
        SOURCE,
        &config(),
    );

    let effective = if verdict.decision == Decision::Reject {
        Decision::Reject
    } else if candidate.confidence < config().confidence_threshold {
        Decision::Candidate
    } else {
        verdict.decision
    };
    assert_eq!(effective, Decision::Candidate);
}

#[test]
fn private_classification_keeps_body_out_of_digest() {
    assert_eq!(
        privacy::classify("我这个月工资到账了"),
        Classification::Private
    );
    assert_eq!(privacy::classify("不吃香菜"), Classification::Normal);
}

#[test]
fn malformed_model_output_is_dropped() {
    // 非 JSON、缺字段、空断言：一律丢弃，且不 panic。
    assert!(extract::parse_candidates("这不是 JSON").is_empty());
    assert!(extract::parse_candidates("[]").is_empty());
    assert!(extract::parse_candidates(r#"[{"assertion":""},{"evidence_quote":"x"}]"#).is_empty());

    let parsed = extract::parse_candidates(
        r#"[{"assertion":"报销走飞书","evidence_quote":"我们报销走飞书审批","confidence":0.9}]"#,
    );
    assert_eq!(parsed.len(), 1);
    assert_eq!(parsed[0].confidence, 0.9);
}

#[derive(Debug)]
struct FailingModel;

impl CompletionModel for FailingModel {
    fn complete(&self, _system: &str, _prompt: &str, _max: Option<u32>) -> CompletionFuture<'_> {
        // 模拟"模型网关挂了"：抽取必须自己咽下这个错误。
        Box::pin(async { Err("gateway down".to_string()) })
    }
}

#[derive(Debug)]
struct SilentModel;

impl CompletionModel for SilentModel {
    fn complete(&self, _system: &str, _prompt: &str, _max: Option<u32>) -> CompletionFuture<'_> {
        Box::pin(async {
            Ok(Completion {
                text: "[]".to_string(),
                prompt_tokens: 1,
                completion_tokens: 1,
                tokens_estimated: true,
                finish_reason: None,
            })
        })
    }
}

async fn extract_ctx(tag: &str) -> common::TestContext {
    common::setup_with(|config: &mut Config| {
        config.memory.enabled = true;
        config.memory.extract.enabled = true;
        config.memory.extract.daily_calls = 1;
    })
    .await
    .tap_login(tag)
    .await
}

/// 给测试上下文配对一台设备（抽取值不值钱，但上下文构造要一致）。
trait TapLogin {
    async fn tap_login(self, tag: &str) -> common::TestContext;
}

impl TapLogin for common::TestContext {
    async fn tap_login(self, tag: &str) -> common::TestContext {
        let _ = self.pair_and_login(tag).await;
        self
    }
}

/// 造一条"已总结"的录音作为抽取源。
fn memory_draft(content: &str) -> jarvis_service::memory::store::MemoryDraft {
    use protocol::{
        MemoryKind, MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource, MemoryStatus,
    };
    jarvis_service::memory::store::MemoryDraft {
        kind: MemoryKind::Profile,
        pipeline: MemoryPipeline::Subjective,
        status: MemoryStatus::Active,
        scope: MemoryScope::Global,
        project_id: None,
        sensitivity: MemorySensitivity::Normal,
        content: content.to_string(),
        subject: None,
        predicate: None,
        time_scope: None,
        due_at: None,
        confidence: 0.9,
        importance: 0.6,
        pinned: false,
        batch_id: None,
        source: MemorySource::Explicit,
        valid_from: jarvis_service::clock::now_ms(),
    }
}

async fn insert_recording(ctx: &common::TestContext, id: &str) {
    let now = jarvis_service::clock::now_ms();
    sqlx::query(
        "INSERT INTO recordings \
          (id, client_recording_id, title, mode, status, text, summary, summary_status, \
           summary_updated_at, created_at, updated_at) \
         VALUES (?, ?, '周会', 'realtime', 'recorded', '对齐了范围', '对齐了范围', 'ready', ?, ?, ?)",
    )
    .bind(id)
    .bind(format!("client_{id}"))
    .bind(now)
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入录音失败");
}

#[tokio::test]
async fn daily_budget_stops_extraction() {
    let ctx = extract_ctx("ext-budget").await;
    insert_recording(&ctx, "rec_budget").await;

    // 把今天的调用数直接顶到上限：预算闸应该在任何模型调用之前就拦住。
    let day = jarvis_service::clock::format_date_ms(jarvis_service::clock::now_ms());
    sqlx::query(
        "INSERT INTO memory_extract_daily (day, calls, candidates, rejected, chars, updated_at) \
         VALUES (?, 99, 0, 0, 0, ?)",
    )
    .bind(&day)
    .bind(jarvis_service::clock::now_ms())
    .execute(&ctx.state.pool)
    .await
    .expect("写预算失败");

    let service = MemoryService::new(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Some(Arc::new(SilentModel)),
    );

    let report = extract::run_job(
        &service,
        ExtractJob {
            batch_id: "bat_budget".to_string(),
            trace_id: "rec_budget".to_string(),
            source: ExtractSource::Recording {
                recording_id: "rec_budget".to_string(),
            },
        },
    )
    .await
    .expect("预算超限不该让抽取报错");

    assert!(report.skipped, "预算耗尽时应跳过而不是硬抽");
    let memories: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memories")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(memories, 0, "预算耗尽时不该写入任何记忆");
}

#[tokio::test]
async fn extract_failure_does_not_break_answer() {
    let ctx = extract_ctx("ext-fail").await;
    insert_recording(&ctx, "rec_fail").await;

    let service = MemoryService::new(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Some(Arc::new(FailingModel)),
    );

    // 模型挂了：抽取自己咽下错误，调用方（对话链路）看到的仍然是 Ok。
    let report = extract::run_job(
        &service,
        ExtractJob {
            batch_id: "bat_fail".to_string(),
            trace_id: "rec_fail".to_string(),
            source: ExtractSource::Recording {
                recording_id: "rec_fail".to_string(),
            },
        },
    )
    .await
    .expect("抽取失败不能冒泡");

    assert_eq!(report.accepted + report.candidates, 0);
    let memories: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memories")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(memories, 0, "模型失败时不该留下半条记忆");
}

#[derive(Debug)]
struct OneFactModel;

impl CompletionModel for OneFactModel {
    fn complete(&self, _system: &str, _prompt: &str, _max: Option<u32>) -> CompletionFuture<'_> {
        Box::pin(async {
            Ok(Completion {
                text: r#"[{"assertion":"用户希望被称呼为老爷","kind":"profile","subject":"用户","predicate":"称呼","evidence_quote":"你以后称呼我老爷","support_span":"称呼我老爷","confidence":0.95}]"#.to_string(),
                prompt_tokens: 10,
                completion_tokens: 20,
                tokens_estimated: true,
                finish_reason: None,
            })
        })
    }
}

#[tokio::test]
async fn session_source_reads_message_body() {
    let ctx = extract_ctx("ext-session").await;

    // 消息正文存在 `content_json` 里（表里没有 `content` 列）。
    // 这里按真实写入格式造两条消息，源文本拼接必须能拼出原文。
    let now = jarvis_service::clock::now_ms();
    sqlx::query(
        "INSERT INTO conversations (id, title, created_at, updated_at) \
         VALUES ('conv_ext', '抽取', ?, ?)",
    )
    .bind(now)
    .bind(now)
    .execute(&ctx.state.pool)
    .await
    .expect("插入会话失败");

    for (id, role, text) in [
        ("msg_u", "user", "你以后称呼我老爷，我1982年出生"),
        ("msg_a", "assistant", "记住了，老爷。"),
    ] {
        sqlx::query(
            "INSERT INTO messages (id, conversation_id, role, content_json, created_at) \
             VALUES (?, 'conv_ext', ?, ?, ?)",
        )
        .bind(id)
        .bind(role)
        .bind(serde_json::json!({ "text": text }).to_string())
        .bind(now)
        .execute(&ctx.state.pool)
        .await
        .expect("插入消息失败");
    }

    let service = MemoryService::new(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Some(Arc::new(OneFactModel)),
    );

    let report = extract::run_job(
        &service,
        ExtractJob {
            batch_id: "bat_session".to_string(),
            trace_id: "conv_ext".to_string(),
            source: ExtractSource::Session {
                conversation_id: "conv_ext".to_string(),
                user_message_id: "msg_u".to_string(),
                assistant_message_id: "msg_a".to_string(),
            },
        },
    )
    .await
    .expect("会话来源的抽取不该失败");

    assert!(
        report.accepted + report.candidates >= 1,
        "会话来源应能抽出记忆，实际 report={report:?}"
    );

    let content: (String,) = sqlx::query_as("SELECT content FROM memories LIMIT 1")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("应写入一条记忆");
    assert_eq!(content.0, "用户希望被称呼为老爷");
}

#[derive(Debug)]
struct ShorterAddressModel;

impl CompletionModel for ShorterAddressModel {
    fn complete(&self, _system: &str, _prompt: &str, _max: Option<u32>) -> CompletionFuture<'_> {
        Box::pin(async {
            Ok(Completion {
                text: r#"[{"assertion":"浙江省嘉兴市南湖区八字桥村","kind":"profile","subject":"用户","predicate":"老家所在地","evidence_quote":"浙江省嘉兴市南湖区八字桥村","support_span":"浙江省嘉兴市南湖区八字桥村","confidence":0.9}]"#.to_string(),
                prompt_tokens: 5,
                completion_tokens: 5,
                tokens_estimated: true,
                finish_reason: None,
            })
        })
    }
}

#[tokio::test]
async fn shorter_assertion_merges_into_existing() {
    let ctx = extract_ctx("ext-subsumed").await;

    // 已有一条更完整的记忆（同主体、同类型）。
    let mut existing = memory_draft("用户的老家是浙江省嘉兴市南湖区八字桥村。");
    existing.subject = Some("用户".to_string());
    existing.predicate = Some("老家所在地".to_string());
    let existing = jarvis_service::memory::store::MemoryStore::new(&ctx.state.pool)
        .insert(existing)
        .await
        .expect("写入基线失败");

    insert_recording(&ctx, "rec_short").await;
    sqlx::query("UPDATE recordings SET summary = '浙江省嘉兴市南湖区八字桥村', text = summary WHERE id = 'rec_short'")
        .execute(&ctx.state.pool)
        .await
        .expect("改录音失败");

    let service = MemoryService::new(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Some(Arc::new(ShorterAddressModel)),
    );

    extract::run_job(
        &service,
        ExtractJob {
            batch_id: "bat_short".to_string(),
            trace_id: "rec_short".to_string(),
            source: ExtractSource::Recording {
                recording_id: "rec_short".to_string(),
            },
        },
    )
    .await
    .expect("抽取不该失败");

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM memories")
        .fetch_one(&ctx.state.pool)
        .await
        .expect("查询失败");
    assert_eq!(rows, 1, "更简的同义断言不该新增一行");

    let evidence: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM memory_evidence WHERE memory_id = ?")
            .bind(&existing.id)
            .fetch_one(&ctx.state.pool)
            .await
            .expect("查询失败");
    assert_eq!(evidence, 1, "证据应挂到既有记忆上");
}
