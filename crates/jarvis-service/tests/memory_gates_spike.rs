//! MP-03：证据校验与准入闸的误杀率（手动跑，不进常规回归）。
//!
//! ```text
//! cargo test -p jarvis-service --test memory_gates_spike -- --ignored --nocapture
//! ```
//!
//! **验的是闸，不是模型**：fixture 里每行是一条"模型可能吐出的候选"，人工标注成
//! `active` / `candidate` / `reject` / `private`。这里不调用模型，因此统计的是
//! "闸门会不会把对的判错、把错的放过"，不含模型本身的抽取质量。
//!
//! 门槛（开发方案 10.1 MP-03）：误杀率 ≤20%（`active` 被判成非 `active` 的比例）。

use std::collections::BTreeMap;

use jarvis_service::memory::gates::{self, Decision, GateConfig, RawCandidate, RejectReason};
use jarvis_service::memory::privacy::Classification;

const FIXTURE: &str = include_str!("fixtures/memory_extract_cases.ndjson");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Label {
    Active,
    Candidate,
    Reject,
    Private,
}

impl Label {
    fn parse(raw: &str) -> Self {
        match raw {
            "active" => Self::Active,
            "candidate" => Self::Candidate,
            "reject" => Self::Reject,
            "private" => Self::Private,
            other => panic!("未知标注：{other}"),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Candidate => "candidate",
            Self::Reject => "reject",
            Self::Private => "private",
        }
    }
}

#[derive(Debug)]
struct Case {
    id: String,
    label: Label,
    reason: Option<String>,
    source: String,
    raw: RawCandidate,
}

#[derive(Debug, Default)]
struct Tally {
    total: usize,
    correct: usize,
    /// 被判成"更保守"的结果（active → candidate）：不计为错误，但单独统计。
    downgraded: usize,
    errors: Vec<String>,
}

#[test]
#[ignore = "MP-03 闸门误杀率：手动跑，需要 --nocapture 看结论表"]
fn gate_false_positive_spike() {
    let cases = load_fixture();
    assert_eq!(cases.len(), 36, "标注用例应为 36 条");

    let config = GateConfig::default();
    let mut by_label: BTreeMap<&'static str, Tally> = BTreeMap::new();

    for case in &cases {
        let verdict = gates::evaluate(&case.raw, &case.source, &config);
        let tally = by_label.entry(case.label.name()).or_default();
        tally.total += 1;

        let actual = match case.label {
            Label::Private => format!("{:?}", verdict.sensitivity),
            _ => format!("{:?}", verdict.decision),
        };

        let (ok, downgraded) = judge(case, &verdict);
        if ok {
            tally.correct += 1;
        } else {
            tally.errors.push(format!(
                "{}（标注 {}，实际 {}，reason={:?}，notes={:?}）",
                case.id,
                case.label.name(),
                actual,
                verdict.reason.map(RejectReason::code),
                verdict
                    .notes
                    .iter()
                    .map(|note| note.code())
                    .collect::<Vec<_>>()
            ));
        }
        if downgraded {
            tally.downgraded += 1;
        }
    }

    eprintln!();
    eprintln!("## MP-03 准入闸判定（36 条人工标注的模型输出样例）");
    eprintln!();
    eprintln!("| 标注 | 用例数 | 判定正确 | 误判 | 降级 | 正确率 |");
    eprintln!("| --- | --- | --- | --- | --- | --- |");
    for (label, tally) in &by_label {
        eprintln!(
            "| {} | {} | {} | {} | {} | {:.0}% |",
            label,
            tally.total,
            tally.correct,
            tally.total - tally.correct,
            tally.downgraded,
            tally.correct as f64 * 100.0 / tally.total as f64
        );
    }

    eprintln!();
    eprintln!("误判明细：");
    let mut any_error = false;
    for (label, tally) in &by_label {
        for error in &tally.errors {
            any_error = true;
            eprintln!("- [{label}] {error}");
        }
    }
    if !any_error {
        eprintln!("- 无");
    }

    eprintln!();
    eprintln!("注意：这验证的是闸门判定，不含模型抽取质量；语义压缩类误判（如把");
    eprintln!("“工资”改写成“月薪”）由敏感度闸的双侧判定兜住，不计入误杀。");

    let active = by_label.get("active").expect("缺少 active 用例");
    let false_kill = active.total - active.correct;
    let false_kill_rate = false_kill as f64 / active.total as f64;
    assert!(
        false_kill_rate <= 0.2,
        "误杀率 {:.0}% 超过 20% 门槛，按 10.1 需放宽为归一化后 80% 覆盖率",
        false_kill_rate * 100.0
    );

    let rejects = by_label.get("reject").expect("缺少 reject 用例");
    assert_eq!(
        rejects.correct, rejects.total,
        "被拒用例有漏放：幻觉或密钥类候选不得通过"
    );
}

/// 返回 `(是否判定正确, 是否属于保守降级)`。
fn judge(case: &Case, verdict: &gates::GateVerdict) -> (bool, bool) {
    match case.label {
        Label::Active => match verdict.decision {
            Decision::Active => (true, false),
            Decision::Candidate => (false, true),
            Decision::Reject => (false, false),
        },
        Label::Candidate => (verdict.decision == Decision::Candidate, false),
        Label::Reject => {
            let reason_ok = match (&case.reason, verdict.reason) {
                (Some(expected), Some(actual)) => expected == actual.code(),
                (None, _) => true,
                (Some(_), None) => false,
            };
            (verdict.decision == Decision::Reject && reason_ok, false)
        }
        Label::Private => (verdict.sensitivity == Classification::Private, false),
    }
}

fn load_fixture() -> Vec<Case> {
    let mut cases = Vec::new();
    for (index, line) in FIXTURE.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let value: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|err| panic!("第 {} 行不是合法 JSON：{err}", index + 1));

        cases.push(Case {
            id: value["id"].as_str().expect("缺 id").to_string(),
            label: Label::parse(value["label"].as_str().expect("缺 label")),
            reason: value["reason"].as_str().map(str::to_string),
            source: value["source"].as_str().expect("缺 source").to_string(),
            raw: RawCandidate {
                assertion: value["assertion"]
                    .as_str()
                    .expect("缺 assertion")
                    .to_string(),
                subject: value["subject"].as_str().map(str::to_string),
                predicate: value["predicate"].as_str().map(str::to_string),
                evidence_quote: value["quote"].as_str().expect("缺 quote").to_string(),
                support_span: value["span"].as_str().map(str::to_string),
                confidence: value["confidence"].as_f64().expect("缺 confidence") as f32,
            },
        });
    }
    cases
}
