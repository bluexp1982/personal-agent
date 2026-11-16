//! 敏感度分级与脱敏（纯函数，不做网络、不碰数据库）。
//!
//! 三档语义：
//! - `Normal`：正常写入，可进摘要；
//! - `Private`：写入但永不进常驻摘要（仍可在显式召回时按需命中）；
//! - `Secret`：**拒绝入库**。密钥、整条就是身份证/银行卡号的内容，落库即泄露。
//!
//! **脱敏在写入时做，不在读取时做**：读取时脱敏意味着原文已经落盘。
//!
//! 不引 `regex` crate（本模块不允许新增依赖），模式判定全部手写。手写的代价是
//! 覆盖范围不如正则完整，收益是不引入第二条正则引擎与编译期成本；命中表集中
//! 在下面几个函数里，便于审计。

/// 敏感度分档。`Secret` 只出现在"拒绝路径"，不会写入 `memories.sensitivity`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Classification {
    Normal,
    Private,
    Secret,
}

/// 一次脱敏命中的位置（字节区间），用于审计里只记"遮蔽了几处"而不记内容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MaskHit {
    /// `id` / `bank_card` / `password`
    pub kind: &'static str,
    pub start: usize,
    pub end: usize,
}

/// 健康、财务、家庭类关键词：命中即私密（入库但不进摘要）。
const PRIVATE_KEYWORDS: &[&str] = &[
    "病历",
    "诊断",
    "处方",
    "住院",
    "手术",
    "体检报告",
    "抑郁症",
    "焦虑症",
    "工资",
    "薪资",
    "年终奖",
    "房贷",
    "车贷",
    "贷款",
    "欠款",
    "信用卡",
    "离婚",
    "抚养权",
    "社保",
    "公积金",
];

/// 口令类关键词：值必须被脱敏。
const PASSWORD_WORDS: &[&str] = &["password", "passwd", "密码", "口令"];

/// 判定这条文本能不能入库、要不要脱敏。
pub fn classify(text: &str) -> Classification {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Classification::Normal;
    }

    if has_private_key_block(trimmed) || has_api_key(trimmed) {
        return Classification::Secret;
    }
    // 整条内容就是证件号 / 卡号：没有上下文可脱敏，直接拒绝。
    if is_bare_credential(trimmed) {
        return Classification::Secret;
    }
    if has_id_number(trimmed) || has_bank_card(trimmed) {
        return Classification::Private;
    }
    if has_password_pair(trimmed) || has_private_keyword(trimmed) {
        return Classification::Private;
    }

    Classification::Normal
}

pub fn is_secret(text: &str) -> bool {
    matches!(classify(text), Classification::Secret)
}

/// 写入前调用：把证件号、卡号、口令的值替换成 `[已屏蔽]`。
///
/// 返回替换后的文本与命中位置；命中位置只用于审计计数。
pub fn mask(text: &str) -> (String, Vec<MaskHit>) {
    let mut spans: Vec<MaskHit> = Vec::new();

    // 1) 口令：关键词 + 分隔符 + 值。
    let lower = text.to_lowercase();
    for word in PASSWORD_WORDS {
        let mut search_from = 0usize;
        while let Some(found) = lower[search_from..].find(word) {
            let keyword_start = search_from + found;
            let keyword_end = keyword_start + word.len();
            if let Some((value_start, value_end)) = password_value_range(text, keyword_end) {
                spans.push(MaskHit {
                    kind: "password",
                    start: value_start,
                    end: value_end,
                });
            }
            search_from = keyword_end;
        }
    }

    // 2) 证件号与卡号。
    for (start, end, kind) in credential_spans(text) {
        spans.push(MaskHit { kind, start, end });
    }

    if spans.is_empty() {
        return (text.to_string(), spans);
    }

    spans.sort_by_key(|hit| hit.start);
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    let mut hits: Vec<MaskHit> = Vec::new();
    for hit in spans {
        // 重叠的命中只保留第一个，避免切片错位。
        if hit.start < cursor {
            continue;
        }
        out.push_str(&text[cursor..hit.start]);
        out.push_str("[已屏蔽]");
        cursor = hit.end;
        hits.push(hit);
    }
    out.push_str(&text[cursor..]);

    (out, hits)
}

fn has_private_key_block(text: &str) -> bool {
    text.contains("PRIVATE KEY-----") && text.contains("-----BEGIN")
}

fn has_api_key(text: &str) -> bool {
    // `sk-` 后至少 16 位字母数字；`AKIA` 后 16 位大写字母数字。
    let bytes = text.as_bytes();
    for (index, window) in bytes.windows(3).enumerate() {
        if window == b"sk-" {
            let rest = &text[index + 3..];
            if alnum_run_len(rest) >= 16 {
                return true;
            }
        }
    }
    for (index, window) in bytes.windows(4).enumerate() {
        if window == b"AKIA" {
            let rest = &text[index + 4..];
            let candidate: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric())
                .collect();
            if candidate.len() >= 16
                && candidate
                    .chars()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            {
                return true;
            }
        }
    }
    false
}

fn alnum_run_len(text: &str) -> usize {
    text.chars()
        .take_while(|c| c.is_ascii_alphanumeric())
        .count()
}

fn is_bare_credential(text: &str) -> bool {
    let compact: String = text
        .chars()
        .filter(|c| !matches!(c, ' ' | '-' | '\t'))
        .collect();
    if compact.len() == 18 && looks_like_id(&compact) {
        return true;
    }
    (16..=19).contains(&compact.len())
        && compact.chars().all(|c| c.is_ascii_digit())
        && luhn_ok(&compact)
}

/// 文本里的证件号与卡号：`(start, end, kind)`，字节区间。
///
/// 身份证末位可能是 `X`，而 `X` 不是数字，所以"17 位数字 + X"要单独拼成一个整体。
fn credential_spans(text: &str) -> Vec<(usize, usize, &'static str)> {
    let mut spans = Vec::new();
    for (start, end) in digit_runs(text) {
        let mut credential_end = end;
        if end - start == 17 {
            if let Some(next) = text[end..].chars().next() {
                if next == 'X' || next == 'x' {
                    credential_end = end + next.len_utf8();
                }
            }
        }

        if credential_end - start == 18 && looks_like_id(&text[start..credential_end]) {
            spans.push((start, credential_end, "id"));
            continue;
        }
        let digits = &text[start..end];
        if (16..=19).contains(&digits.len()) && luhn_ok(digits) {
            spans.push((start, end, "bank_card"));
        }
    }
    spans
}

fn has_id_number(text: &str) -> bool {
    credential_spans(text)
        .iter()
        .any(|(_, _, kind)| *kind == "id")
}

fn has_bank_card(text: &str) -> bool {
    credential_spans(text)
        .iter()
        .any(|(_, _, kind)| *kind == "bank_card")
}

fn has_password_pair(text: &str) -> bool {
    let lower = text.to_lowercase();
    PASSWORD_WORDS.iter().any(|word| {
        let mut search_from = 0usize;
        while let Some(found) = lower[search_from..].find(word) {
            let keyword_end = search_from + found + word.len();
            if password_value_range(text, keyword_end).is_some() {
                return true;
            }
            search_from = keyword_end;
        }
        false
    })
}

fn has_private_keyword(text: &str) -> bool {
    PRIVATE_KEYWORDS.iter().any(|word| text.contains(word))
}

/// 关键词之后紧跟分隔符与值：返回值的字节区间。
fn password_value_range(text: &str, from: usize) -> Option<(usize, usize)> {
    let rest = &text[from..];
    let separator = rest
        .char_indices()
        .find(|(_, ch)| matches!(ch, ':' | '：' | '=' | '＝'))?;
    if separator.0 > 4 {
        // 关键词与分隔符之间隔着太多字，说明不是"密码：xxx"这种写法。
        return None;
    }

    let after = from + separator.0 + separator.1.len_utf8();
    let value: String = text[after..]
        .chars()
        .skip_while(|ch| ch.is_whitespace())
        .take_while(|ch| !ch.is_whitespace())
        .collect();
    if value.is_empty() {
        return None;
    }

    let value_start = text[after..].find(&value).map(|offset| after + offset)?;
    Some((value_start, value_start + value.len()))
}

/// 连续 ASCII 数字段的字节区间。
fn digit_runs(text: &str) -> Vec<(usize, usize)> {
    let mut runs = Vec::new();
    let mut start: Option<usize> = None;
    for (index, ch) in text.char_indices() {
        if ch.is_ascii_digit() {
            if start.is_none() {
                start = Some(index);
            }
        } else if let Some(begin) = start.take() {
            runs.push((begin, index));
        }
    }
    if let Some(begin) = start {
        runs.push((begin, text.len()));
    }
    runs
}

/// 18 位：前 17 位数字 + 末位数字或 X（大小写均可）。
fn looks_like_id(run: &str) -> bool {
    if run.len() != 18 {
        return false;
    }
    let mut chars = run.chars();
    let head: String = chars.by_ref().take(17).collect();
    let tail = chars.next().unwrap_or(' ');
    head.chars().all(|c| c.is_ascii_digit())
        && (tail.is_ascii_digit() || tail == 'X' || tail == 'x')
}

/// Luhn 校验：卡号最后一位是校验位。
fn luhn_ok(digits: &str) -> bool {
    if digits.len() < 2 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }

    let mut sum = 0u32;
    let mut double = false;
    for ch in digits.chars().rev() {
        let mut value = ch.to_digit(10).unwrap_or(0);
        if double {
            value *= 2;
            if value > 9 {
                value -= 9;
            }
        }
        sum += value;
        double = !double;
    }
    sum.is_multiple_of(10)
}

// ---------------------------------------------------------------------------
// 可见性：**唯一的判定处**
// ---------------------------------------------------------------------------

/// 这条记忆能不能在给定作用域里被召回。
///
/// `digest` 与 `retrieve` 都只调这一处。两处各写一份过滤条件，迟早会有一处
/// 漏掉私密或跨仓库——而这两种漏法都不会报错，只会安静地把不该说的说出去。
pub fn visible_in_scope(memory: &protocol::Memory, scope: &super::retrieve::RecallScope) -> bool {
    use super::retrieve::RecallScope;
    use protocol::{MemoryKind, MemoryScope};

    if !matches!(
        memory.status,
        protocol::MemoryStatus::Active | protocol::MemoryStatus::Stale
    ) {
        return false;
    }

    // 项目层记忆只属于它绑定的仓库：跨仓库串味比不召回更糟。
    if memory.scope == MemoryScope::Project {
        let Some(bound) = memory.project_id.as_deref() else {
            // 绑了 scope 却没有 project_id 是脏数据，按不可见处理。
            return false;
        };
        if Some(bound) != scope.project_id() {
            return false;
        }
    }

    if scope.is_code() {
        // 编码任务里只允许工程偏好与当前仓库的项目约定；
        // 个人画像、事件、私密内容一律不进（设计文档 7.5）。
        if memory.sensitivity == protocol::MemorySensitivity::Private {
            return false;
        }
        return matches!(memory.kind, MemoryKind::Preference | MemoryKind::Project);
    }

    let _ = RecallScope::Work { project_id: None };
    true
}

/// 这条记忆能不能进常驻摘要（digest）。
///
/// 与 [`visible_in_scope`] 的差别：摘要不做"按需召回"，私密内容永不进入。
pub fn allowed_in_digest(memory: &protocol::Memory) -> bool {
    memory.status == protocol::MemoryStatus::Active
        && memory.sensitivity != protocol::MemorySensitivity::Private
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_normal() {
        assert_eq!(classify("回答先给结论再给依据"), Classification::Normal);
    }

    #[test]
    fn api_keys_are_secret() {
        assert_eq!(
            classify("我的 key 是 sk-abcdefghijklmnop1234"),
            Classification::Secret
        );
        assert_eq!(
            classify("AWS 访问密钥 AKIAIOSFODNN7EXAMPLE"),
            Classification::Secret
        );
    }

    #[test]
    fn private_key_block_is_secret() {
        assert_eq!(
            classify("-----BEGIN RSA PRIVATE KEY-----\nMIIE..."),
            Classification::Secret
        );
    }

    #[test]
    fn bare_id_number_is_secret() {
        // 11010519491231002X 是结构合法的 18 位号码。
        assert_eq!(classify("11010519491231002X"), Classification::Secret);
    }

    #[test]
    fn id_inside_sentence_is_private_and_masked() {
        let text = "体检时填的身份证号是 11010519491231002X，收好别外传";
        assert_eq!(classify(text), Classification::Private);

        let (masked, hits) = mask(text);
        assert!(masked.contains("[已屏蔽]"));
        assert!(!masked.contains("11010519491231002X"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, "id");
    }

    #[test]
    fn luhn_accepts_valid_card() {
        // 4111111111111111 是通行测试卡号，Luhn 合法。
        assert!(luhn_ok("4111111111111111"));
        assert!(!luhn_ok("4111111111111112"));
        assert_eq!(classify("4111111111111111"), Classification::Secret);
    }

    #[test]
    fn password_value_is_masked() {
        let (masked, hits) = mask("数据库密码：Abc12345");
        assert_eq!(masked, "数据库密码：[已屏蔽]");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, "password");
    }

    #[test]
    fn english_password_is_masked() {
        let (masked, _) = mask("password = hunter2");
        assert_eq!(masked, "password = [已屏蔽]");
    }

    #[test]
    fn keyword_marks_private_without_masking() {
        assert_eq!(classify("这个月的房贷还差三千"), Classification::Private);
        let (masked, hits) = mask("这个月的房贷还差三千");
        assert_eq!(masked, "这个月的房贷还差三千");
        assert!(hits.is_empty());
    }

    #[test]
    fn normal_text_is_untouched_by_mask() {
        let (masked, hits) = mask("时间统一用毫秒");
        assert_eq!(masked, "时间统一用毫秒");
        assert!(hits.is_empty());
    }

    #[test]
    fn does_not_treat_short_numbers_as_cards() {
        assert_eq!(
            classify("服务器是四核八G，跑了 1234 天"),
            Classification::Normal
        );
    }
}
