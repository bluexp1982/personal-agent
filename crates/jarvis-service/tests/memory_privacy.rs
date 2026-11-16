//! 隐私边界：密钥不进候选、私密不进摘要但可显式召回、编码场景不见个人记忆。
//!
//! 这一组是纯函数 + 一次 DB 级验证：验的是"闸与过滤器",不是模型抽取质量。

mod common;

use protocol::{
    Memory, MemoryKind, MemoryPipeline, MemoryScope, MemorySensitivity, MemorySource, MemoryStatus,
};
use jarvis_service::memory::digest::{
    self, DigestBudget, DigestContext, DigestEntry, DigestKind, DigestMode, DigestSource,
};
use jarvis_service::memory::gates::{self, Decision, GateConfig, RawCandidate};
use jarvis_service::memory::privacy::{self, Classification};
use jarvis_service::memory::retrieve::RecallScope;

fn memory(
    kind: MemoryKind,
    scope: MemoryScope,
    sensitivity: MemorySensitivity,
    project_id: Option<&str>,
) -> Memory {
    Memory {
        id: "mem_1".to_string(),
        kind,
        pipeline: MemoryPipeline::Subjective,
        status: MemoryStatus::Active,
        scope,
        project_id: project_id.map(str::to_string),
        sensitivity,
        content: "内容".to_string(),
        subject: None,
        entity_id: None,
        predicate: None,
        time_scope: None,
        confidence: 0.9,
        importance: 0.6,
        pinned: false,
        batch_id: None,
        source: MemorySource::Explicit,
        valid_from: 0,
        valid_to: None,
        superseded_by: None,
        use_count: 0,
        conflicting: false,
        created_at: 0,
        updated_at: 0,
    }
}

#[test]
fn secret_patterns_are_rejected() {
    // 密钥、证件号一类的正文连"进候选"都不允许。
    assert!(privacy::is_secret("我的 key 是 sk-abcdefghijklmnopqrst"));
    assert_eq!(
        privacy::classify("sk-abcdefghijklmnopqrst"),
        Classification::Secret
    );

    let verdict = gates::evaluate(
        &RawCandidate {
            assertion: "密钥是 sk-abcdefghijklmnopqrst".to_string(),
            subject: None,
            predicate: None,
            evidence_quote: "密钥是 sk-abcdefghijklmnopqrst".to_string(),
            support_span: None,
            confidence: 0.99,
        },
        "密钥是 sk-abcdefghijklmnopqrst",
        &GateConfig {
            confidence_threshold: 0.6,
            max_content_chars: 500,
            max_input_chars: 12_000,
            daily_calls: 50,
            pending_limit: 200,
        },
    );
    assert_eq!(verdict.decision, Decision::Reject, "密钥必须被丢弃");
}

#[test]
fn private_skips_digest_but_allows_recall_on_demand() {
    // 摘要：私密永不进入。
    let entry = DigestEntry {
        id: "mem_private".to_string(),
        kind: DigestKind::Event,
        content: "这个月工资到账了".to_string(),
        source: DigestSource::Explicit,
        at: 1_700_000_000_000,
        pinned: false,
        importance: 0.9,
        project_id: None,
        private: true,
    };
    let digest = digest::select(
        &[entry],
        &DigestBudget::default(),
        &DigestContext::at(Some(DigestMode::Work), None, 1_700_000_000_000),
    )
    .expect("单条不该溢出");
    assert!(digest.memory_ids.is_empty(), "私密记忆不得进入常驻摘要");

    // 召回：私密记忆在 WORK 会话里可见——用户主动问起时才用，与摘要的规则不同。
    let private = memory(
        MemoryKind::Event,
        MemoryScope::Global,
        MemorySensitivity::Private,
        None,
    );
    assert!(
        privacy::visible_in_scope(&private, &RecallScope::for_mode(false, None)),
        "WORK 会话的显式召回应能看到私密记忆"
    );
}

#[test]
fn code_task_guidance_has_no_personal_memory() {
    let code = RecallScope::for_mode(true, Some("ws_a".to_string()));

    // 个人画像与事件：即使不是私密，也不该进 Git 项目会话。
    for kind in [MemoryKind::Profile, MemoryKind::Event] {
        let item = memory(kind, MemoryScope::Global, MemorySensitivity::Normal, None);
        assert!(
            !privacy::visible_in_scope(&item, &code),
            "{kind:?} 不应进入 编码场景"
        );
    }

    // 工程偏好：可以进。
    let preference = memory(
        MemoryKind::Preference,
        MemoryScope::Global,
        MemorySensitivity::Normal,
        None,
    );
    assert!(privacy::visible_in_scope(&preference, &code));

    // 项目约定：只认当前仓库。
    let same_repo = memory(
        MemoryKind::Project,
        MemoryScope::Project,
        MemorySensitivity::Normal,
        Some("ws_a"),
    );
    assert!(privacy::visible_in_scope(&same_repo, &code));

    let other_repo = memory(
        MemoryKind::Project,
        MemoryScope::Project,
        MemorySensitivity::Normal,
        Some("ws_b"),
    );
    assert!(
        !privacy::visible_in_scope(&other_repo, &code),
        "别的仓库的项目约定不许串味"
    );

    // 私密偏好：即便 kind 允许，私密也不进。
    let private_preference = memory(
        MemoryKind::Preference,
        MemoryScope::Global,
        MemorySensitivity::Private,
        None,
    );
    assert!(!privacy::visible_in_scope(&private_preference, &code));
}
