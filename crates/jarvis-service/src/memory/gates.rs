//! 准入五道闸（**纯函数**，不碰数据库、不调模型）。
//!
//! 顺序与开发方案 6.6 一致：证据 → 敏感度 → 置信度 → （去重由 store 执行）→ 预算。
//! 这里额外给出第 4 道闸用的 `dedupe_key`，把"归一化"这一步留在纯函数里，
//! 数据库那半边只负责按 key 查。
//!
//! 判定只有三种结果：
//! - `Active`：可以直接生效；
//! - `Candidate`：进候选，等用户确认（证据缺 `support_span`、置信度不足都落这里）；
//! - `Reject`：丢弃，**并且没有"稍后重试"**——被拒的断言不会进库。

use super::privacy::{self, Classification};
use super::tokenize;

/// 闸的阈值。与配置里的 `memory.extract.*` 一一对应，由调用方填。
#[derive(Debug, Clone, Copy)]
pub struct GateConfig {
    pub confidence_threshold: f32,
    pub max_content_chars: usize,
    pub max_input_chars: usize,
    pub daily_calls: u32,
    pub pending_limit: usize,
}

impl Default for GateConfig {
    fn default() -> Self {
        Self {
            confidence_threshold: 0.6,
            max_content_chars: 500,
            max_input_chars: 12_000,
            daily_calls: 50,
            pending_limit: 200,
        }
    }
}

/// 模型吐出来的一条候选（已解析成结构体，未经验证）。
#[derive(Debug, Clone)]
pub struct RawCandidate {
    pub assertion: String,
    pub subject: Option<String>,
    pub predicate: Option<String>,
    pub evidence_quote: String,
    pub support_span: Option<String>,
    pub confidence: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    EmptyAssertion,
    TooLong,
    QuoteMismatch,
    Secret,
}

impl RejectReason {
    /// 审计里只记这个码，不记正文。
    pub fn code(self) -> &'static str {
        match self {
            Self::EmptyAssertion => "empty_assertion",
            Self::TooLong => "too_long",
            Self::QuoteMismatch => "quote_mismatch",
            Self::Secret => "secret",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateNote {
    /// 没有 `support_span`：只降级为候选，不丢弃（误杀率会高到不可接受）。
    MissingSupportSpan,
    /// `support_span` 不是 `quote` 的子串：同样降级。
    SpanOutsideQuote,
    LowConfidence,
}

impl GateNote {
    pub fn code(self) -> &'static str {
        match self {
            Self::MissingSupportSpan => "missing_span",
            Self::SpanOutsideQuote => "span_outside_quote",
            Self::LowConfidence => "low_confidence",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Active,
    Candidate,
    Reject,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GateVerdict {
    pub decision: Decision,
    pub reason: Option<RejectReason>,
    /// Normal / Private（Secret 只会以 `Reject` 出现）。
    pub sensitivity: Classification,
    pub notes: Vec<GateNote>,
    /// 脱敏后的断言；`Private` 时调用方必须写这一份。
    pub assertion: String,
    pub quote: String,
}

/// 走完前四道闸（第五道预算是 `check_budget`，由调用方在抽取之前判）。
pub fn evaluate(raw: &RawCandidate, source_text: &str, config: &GateConfig) -> GateVerdict {
    let assertion = raw.assertion.trim().to_string();
    let quote = raw.evidence_quote.trim().to_string();

    if assertion.is_empty() {
        return reject(RejectReason::EmptyAssertion, &assertion, &quote);
    }
    if assertion.chars().count() > config.max_content_chars {
        return reject(RejectReason::TooLong, &assertion, &quote);
    }

    // 闸 2 先行：密钥一类的正文连"进候选"都不允许，避免在候选列表里露一次。
    if privacy::is_secret(&assertion) || privacy::is_secret(&quote) {
        return reject(RejectReason::Secret, &assertion, &quote);
    }

    // 闸 1：证据必须真的在原文里，否则就是幻觉。
    //
    // 必须在脱敏**之前**判定：脱敏会改写 quote，改完再比对就永远对不上了。
    let evidence = check_evidence(&quote, raw.support_span.as_deref(), source_text);
    if evidence == EvidenceCheck::QuoteMismatch {
        return reject(RejectReason::QuoteMismatch, &assertion, &quote);
    }

    // 敏感度看断言**和**证据原文：断言常把"工资"改写成"月薪"，
    // 只看断言会漏判；原文里带口令值时也必须一并脱敏。
    let sensitivity = stricter(privacy::classify(&assertion), privacy::classify(&quote));
    let (assertion, quote) = if sensitivity == Classification::Private {
        // 写入时脱敏：原文一旦落盘就收不回来了。
        (privacy::mask(&assertion).0, privacy::mask(&quote).0)
    } else {
        (assertion, quote)
    };

    let mut notes = Vec::new();
    match evidence {
        EvidenceCheck::SpanMissing => notes.push(GateNote::MissingSupportSpan),
        EvidenceCheck::SpanOutsideQuote => notes.push(GateNote::SpanOutsideQuote),
        _ => {}
    }
    if raw.confidence < config.confidence_threshold {
        notes.push(GateNote::LowConfidence);
    }

    let decision = if notes.is_empty() {
        Decision::Active
    } else {
        Decision::Candidate
    };

    GateVerdict {
        decision,
        reason: None,
        sensitivity,
        notes,
        assertion,
        quote,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvidenceCheck {
    Matched,
    SpanMissing,
    SpanOutsideQuote,
    QuoteMismatch,
}

/// 归一化后按子串判定。归一化只做全角/大小写/空白，不改变字符顺序，
/// 所以"原文是子串"这个关系在归一化后仍然成立。
pub fn check_evidence(quote: &str, span: Option<&str>, source_text: &str) -> EvidenceCheck {
    let normalized_source = tokenize::normalize_for_match(source_text);
    let normalized_quote = tokenize::normalize_for_match(quote);

    if normalized_quote.is_empty() || !normalized_source.contains(&normalized_quote) {
        return EvidenceCheck::QuoteMismatch;
    }

    match span {
        None => EvidenceCheck::SpanMissing,
        Some(span) if span.trim().is_empty() => EvidenceCheck::SpanMissing,
        Some(span) => {
            if normalized_quote.contains(&tokenize::normalize_for_match(span)) {
                EvidenceCheck::Matched
            } else {
                EvidenceCheck::SpanOutsideQuote
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetUsage {
    pub daily_calls: u32,
    pub pending_candidates: usize,
    pub input_chars: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BudgetReason {
    DailyCalls,
    Backlog,
    LongInput,
}

impl BudgetReason {
    pub fn code(self) -> &'static str {
        match self {
            Self::DailyCalls => "daily_calls",
            Self::Backlog => "backlog",
            Self::LongInput => "long_input",
        }
    }
}

/// 闸 5：预算。超了**直接不抽**，不排队堆积。
pub fn check_budget(usage: BudgetUsage, config: &GateConfig) -> Result<(), BudgetReason> {
    if usage.input_chars > config.max_input_chars {
        return Err(BudgetReason::LongInput);
    }
    if usage.daily_calls >= config.daily_calls {
        return Err(BudgetReason::DailyCalls);
    }
    if usage.pending_candidates > config.pending_limit {
        return Err(BudgetReason::Backlog);
    }
    Ok(())
}

/// 闸 4 的键：主体归一化 + 索引串。两边都来自同一份 `tokenize`，不会漂移。
pub fn dedupe_key(subject: Option<&str>, content: &str) -> String {
    let subject = subject
        .map(tokenize::normalize_for_match)
        .unwrap_or_default();
    format!("{subject}|{}", tokenize::tokenize_for_index(content))
}

fn stricter(left: Classification, right: Classification) -> Classification {
    match (left, right) {
        (Classification::Secret, _) | (_, Classification::Secret) => Classification::Secret,
        (Classification::Private, _) | (_, Classification::Private) => Classification::Private,
        _ => Classification::Normal,
    }
}

fn reject(reason: RejectReason, assertion: &str, quote: &str) -> GateVerdict {
    GateVerdict {
        decision: Decision::Reject,
        reason: Some(reason),
        sensitivity: Classification::Secret,
        notes: Vec::new(),
        assertion: assertion.to_string(),
        quote: quote.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = "我一般周三下午有空，其他时间都排满了，报销走飞书。";

    fn candidate() -> RawCandidate {
        RawCandidate {
            assertion: "用户周三下午有空".to_string(),
            subject: Some("用户".to_string()),
            predicate: Some("有空".to_string()),
            evidence_quote: "我一般周三下午有空".to_string(),
            support_span: Some("周三下午".to_string()),
            confidence: 0.9,
        }
    }

    #[test]
    fn clean_candidate_is_active() {
        let verdict = evaluate(&candidate(), SOURCE, &GateConfig::default());
        assert_eq!(verdict.decision, Decision::Active);
        assert_eq!(verdict.sensitivity, Classification::Normal);
        assert!(verdict.notes.is_empty());
    }

    #[test]
    fn hallucinated_quote_is_rejected() {
        let mut raw = candidate();
        raw.evidence_quote = "我一般周四下午有空".to_string();
        let verdict = evaluate(&raw, SOURCE, &GateConfig::default());

        assert_eq!(verdict.decision, Decision::Reject);
        assert_eq!(verdict.reason, Some(RejectReason::QuoteMismatch));
    }

    #[test]
    fn missing_span_degrades_to_candidate() {
        let mut raw = candidate();
        raw.support_span = None;
        let verdict = evaluate(&raw, SOURCE, &GateConfig::default());

        assert_eq!(verdict.decision, Decision::Candidate);
        assert_eq!(verdict.notes, vec![GateNote::MissingSupportSpan]);
    }

    #[test]
    fn span_outside_quote_degrades_to_candidate() {
        let mut raw = candidate();
        raw.support_span = Some("报销走飞书".to_string());
        let verdict = evaluate(&raw, SOURCE, &GateConfig::default());

        assert_eq!(verdict.decision, Decision::Candidate);
        assert_eq!(verdict.notes, vec![GateNote::SpanOutsideQuote]);
    }

    #[test]
    fn low_confidence_degrades_to_candidate() {
        let mut raw = candidate();
        raw.confidence = 0.3;
        let verdict = evaluate(&raw, SOURCE, &GateConfig::default());

        assert_eq!(verdict.decision, Decision::Candidate);
        assert_eq!(verdict.notes, vec![GateNote::LowConfidence]);
    }

    #[test]
    fn secret_is_rejected_even_if_quoted_verbatim() {
        let source = "我的 key 是 sk-abcdefghijklmnop1234，别外传";
        let raw = RawCandidate {
            assertion: "用户的 key 是 sk-abcdefghijklmnop1234".to_string(),
            subject: None,
            predicate: None,
            evidence_quote: "我的 key 是 sk-abcdefghijklmnop1234".to_string(),
            support_span: Some("sk-abcdefghijklmnop1234".to_string()),
            confidence: 0.99,
        };
        let verdict = evaluate(&raw, source, &GateConfig::default());

        assert_eq!(verdict.decision, Decision::Reject);
        assert_eq!(verdict.reason, Some(RejectReason::Secret));
    }

    #[test]
    fn private_content_is_masked_before_storage() {
        let source = "我的银行卡密码：Abc12345，记一下";
        let raw = RawCandidate {
            assertion: "银行卡密码：Abc12345".to_string(),
            subject: None,
            predicate: None,
            evidence_quote: "我的银行卡密码：Abc12345".to_string(),
            support_span: Some("密码：Abc12345".to_string()),
            confidence: 0.9,
        };
        let verdict = evaluate(&raw, source, &GateConfig::default());

        assert_eq!(verdict.sensitivity, Classification::Private);
        assert!(verdict.assertion.contains("[已屏蔽]"));
        assert!(!verdict.assertion.contains("Abc12345"));
        assert!(!verdict.quote.contains("Abc12345"));
    }

    #[test]
    fn empty_and_overlong_are_rejected() {
        let mut raw = candidate();
        raw.assertion = "   ".to_string();
        assert_eq!(
            evaluate(&raw, SOURCE, &GateConfig::default()).reason,
            Some(RejectReason::EmptyAssertion)
        );

        let mut raw = candidate();
        raw.assertion = "很长".repeat(300);
        assert_eq!(
            evaluate(&raw, SOURCE, &GateConfig::default()).reason,
            Some(RejectReason::TooLong)
        );
    }

    #[test]
    fn budget_blocks_when_exhausted() {
        let config = GateConfig::default();
        let usage = BudgetUsage {
            daily_calls: 50,
            pending_candidates: 0,
            input_chars: 100,
        };
        assert_eq!(check_budget(usage, &config), Err(BudgetReason::DailyCalls));

        let usage = BudgetUsage {
            daily_calls: 0,
            pending_candidates: 201,
            input_chars: 100,
        };
        assert_eq!(check_budget(usage, &config), Err(BudgetReason::Backlog));

        let usage = BudgetUsage {
            daily_calls: 0,
            pending_candidates: 0,
            input_chars: 12_001,
        };
        assert_eq!(check_budget(usage, &config), Err(BudgetReason::LongInput));
    }

    #[test]
    fn dedupe_key_is_stable_across_width_and_case() {
        assert_eq!(
            dedupe_key(Some("Ａ 公司"), "报销走飞书"),
            dedupe_key(Some("a 公司"), "报销走飞书")
        );
        assert_ne!(
            dedupe_key(None, "报销走飞书"),
            dedupe_key(None, "报销走钉钉")
        );
    }
}
