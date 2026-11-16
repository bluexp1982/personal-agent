//! 检索用分词：**写入与查询共用同一份实现**。
//!
//! 为什么自己切词：SQLite 自带的 `unicode61` 分词器把连续汉字视为一个词条，
//! 中文两字查询（"报销"）在"上个月把报销流程迁到了飞书"里永远命中 0；
//! `trigram` 又要求查询至少 3 个字符。做法是写入时把正文切成 bigram 存进
//! `content_tokens` 派生列，索引仍用 `unicode61`，查询侧用同一个函数切。
//!
//! 口径：
//! 1. 归一化：全角转半角、ASCII 统一小写、连续空白压缩为单个空格；
//! 2. 汉字按 2 字滑窗切（"报销系统" → `报销 销系 系统`），单字串保留该字；
//! 3. ASCII 字母与数字按原样保留，词间空格分隔；
//! 4. 其余字符（标点、emoji）视为分隔符，不进索引。

/// 归一化：全角转半角、ASCII 小写、空白压缩。
///
/// 也用于证据校验的"归一化后互为子串"判断，因此**不改变字符顺序、不插入分隔**，
/// 只做逐字符映射与空白折叠，保证子串关系在归一化后仍然成立。
pub fn normalize_for_match(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_space = false;

    for ch in text.chars() {
        let ch = half_width(ch);
        if ch.is_whitespace() {
            // 只有已经写入过内容时才记一个待补空格，避免首部空格。
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        if ch.is_ascii_uppercase() {
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }

    out
}

/// 索引串：汉字 bigram + ASCII 原样，空格分隔。
///
/// 写入 `memories.content_tokens` 与拼 `MATCH` 表达式都用它，两边不一致会让
/// 召回率静默掉到接近零且极难察觉。
pub fn tokenize_for_index(text: &str) -> String {
    let normalized = normalize_for_match(text);
    let mut tokens: Vec<String> = Vec::new();
    let mut han: Vec<char> = Vec::new();
    let mut latin = String::new();

    for ch in normalized.chars() {
        match ch {
            '\u{3400}'..='\u{4DBF}' | '\u{4E00}'..='\u{9FFF}' | '\u{F900}'..='\u{FAFF}' => {
                flush_latin(&mut latin, &mut tokens);
                han.push(ch);
            }
            ch if ch.is_ascii_alphanumeric() => {
                flush_han(&mut han, &mut tokens);
                latin.push(ch);
            }
            _ => {
                flush_han(&mut han, &mut tokens);
                flush_latin(&mut latin, &mut tokens);
            }
        }
    }
    flush_han(&mut han, &mut tokens);
    flush_latin(&mut latin, &mut tokens);

    tokens.join(" ")
}

/// 判断"是不是同一句话"的粗归一化：去空白、去引号、去句读、全角转半角、小写。
///
/// 与 [`normalize_for_match`] 的分工：那个用于检索匹配（保留空格作为词边界），
/// 这个用于**去重判等**——`用户出生于1982年` 与 `用户出生于 1982 年`、
/// `"老爷"` 与 `“老爷”` 都该被视为同一句话。
pub fn normalize_content(text: &str) -> String {
    normalize_for_match(text)
        .chars()
        .filter(|ch| {
            !ch.is_whitespace()
                && !matches!(
                    ch,
                    '"' | '\''
                        | '“'
                        | '”'
                        | '‘'
                        | '’'
                        | '「'
                        | '」'
                        | '『'
                        | '』'
                        | '`'
                        | '。'
                        | '，'
                        | '、'
                        | '；'
                        | '：'
                        | '！'
                        | '？'
                        | '.'
                        | ','
                        | ';'
                        | ':'
                        | '!'
                        | '?'
                )
        })
        .collect()
}

/// 归并的最小长度：短于这个长度的断言被包含是常态（"老爷""1982"），
/// 拿去归并会误伤，所以不参与包含关系判定。
pub const SUBSUME_MIN_CHARS: usize = 6;

/// 归并的"覆盖率"门槛：shorter 的字符二元组有这么多出现在 longer 里，
/// 就认为它表达的信息已被 longer 包含。
pub const SUBSUME_COVERAGE: f64 = 0.8;

/// 否定词：shorter 里有、longer 里没有，就不能归并——`不喜欢香菜` 与
/// `喜欢香菜` 的二元组覆盖率是 0.67，但 `不喜欢` / `不` 这类差异一旦丢掉
/// 就是把意思改反了，所以单独兜一道。
const NEGATIONS: &[char] = &['不', '没', '别', '非', '无'];

/// `longer` 是否覆盖 `shorter`（两者都必须是 [`normalize_content`] 的输出）。
///
/// 两条判据取或：
/// 1. **严格子串**：`八字桥村` 这类真嵌套；
/// 2. **二元组覆盖率 ≥ 0.8**：`用户的老家是浙江省嘉兴市南湖区八字桥村` 与
///    `用户的老家在嘉兴市南湖区八字桥村` 只差一个"是/在"，严格子串不成立，
///    但字符二元组有 87% 重合——这是"详略不同"的常见形态。
///
/// 它不做语义判断：`用户是浙江嘉兴人` 与上面的详细地址是同一事实的不同粒度，
/// 但二元组只重合 57%，抓不到——这类留给人工合并或二期向量召回。
pub fn covers(longer: &str, shorter: &str) -> bool {
    if longer == shorter {
        return false;
    }
    if shorter.chars().count() < SUBSUME_MIN_CHARS {
        return false;
    }
    if negation_conflict(longer, shorter) {
        return false;
    }
    if longer.contains(shorter) {
        return true;
    }
    bigram_coverage(longer, shorter) >= SUBSUME_COVERAGE
}

/// shorter 的字符二元组里，有多大比例出现在 longer 中。
fn bigram_coverage(longer: &str, shorter: &str) -> f64 {
    let long: Vec<char> = longer.chars().collect();
    let short: Vec<char> = shorter.chars().collect();
    if short.len() < 2 {
        return 0.0;
    }

    let total = short.len() - 1;
    let mut hit = 0usize;
    for window in short.windows(2) {
        if long.windows(2).any(|pair| pair == window) {
            hit += 1;
        }
    }

    hit as f64 / total as f64
}

fn negation_conflict(longer: &str, shorter: &str) -> bool {
    NEGATIONS
        .iter()
        .any(|negation| shorter.contains(*negation) && !longer.contains(*negation))
}

/// 一条记忆的索引串：`content + subject + predicate` 一起切。
///
/// 主体与谓语单独成词，是为了"问句里只出现人名"也能命中（正文可能只写"卡在价格"）。
pub fn tokenize_fields(content: &str, subject: Option<&str>, predicate: Option<&str>) -> String {
    let mut parts: Vec<&str> = Vec::with_capacity(3);
    parts.push(content);
    if let Some(subject) = subject {
        parts.push(subject);
    }
    if let Some(predicate) = predicate {
        parts.push(predicate);
    }
    tokenize_for_index(&parts.join(" "))
}

/// FTS5 `MATCH` 表达式：切出的词条去重后用 `OR` 连接，每个词条加双引号。
///
/// 加引号是为了让词条永远按字符串字面量解释（否则 `AND` / `NOT` / `*` 之类
/// 会被当成 FTS5 语法）。全空输入返回空串，调用方据此跳过查询。
pub fn match_expression(text: &str) -> String {
    let tokenized = tokenize_for_index(text);
    let mut unique: Vec<&str> = Vec::new();
    for token in tokenized.split_whitespace() {
        if unique.contains(&token) {
            continue;
        }
        unique.push(token);
    }

    unique
        .iter()
        .map(|token| format!("\"{}\"", token.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" OR ")
}

fn half_width(ch: char) -> char {
    match ch {
        '\u{3000}' => ' ',
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(ch as u32 - 0xFEE0).unwrap_or(ch),
        other => other,
    }
}

fn flush_han(han: &mut Vec<char>, tokens: &mut Vec<String>) {
    match han.len() {
        0 => {}
        1 => tokens.push(han[0].to_string()),
        _ => tokens.extend(
            han.windows(2)
                .map(|window| window.iter().collect::<String>()),
        ),
    }
    han.clear();
}

fn flush_latin(latin: &mut String, tokens: &mut Vec<String>) {
    if !latin.is_empty() {
        tokens.push(std::mem::take(latin));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_width_case_and_whitespace() {
        assert_eq!(normalize_for_match("  ＡＢＣ\u{3000}１２３  "), "abc 123");
        assert_eq!(normalize_for_match("报销   流程"), "报销 流程");
    }

    #[test]
    fn normalization_preserves_substring_relation() {
        // 证据校验依赖这条性质：原文是子串，归一化后仍是子串。
        let source = "我  一般周三 下午有空".to_string();
        let quote = "周三 下午";
        let normalized_source = normalize_for_match(&source);
        let normalized_quote = normalize_for_match(quote);
        assert!(normalized_source.contains(&normalized_quote));
    }

    #[test]
    fn splits_chinese_into_bigrams() {
        assert_eq!(tokenize_for_index("报销系统"), "报销 销系 系统");
        assert_eq!(tokenize_for_index("杭州"), "杭州");
        // 单字串保留单字，否则一个字的记忆完全不可检索。
        assert_eq!(tokenize_for_index("辣"), "辣");
    }

    #[test]
    fn keeps_ascii_runs_whole() {
        assert_eq!(tokenize_for_index("用 Rust 写"), "用 rust 写");
        assert_eq!(tokenize_for_index("HHKB 键盘"), "hhkb 键盘");
    }

    #[test]
    fn punctuation_is_a_separator() {
        assert_eq!(tokenize_for_index("报销，走飞书。"), "报销 走飞 飞书");
        assert_eq!(tokenize_for_index(""), "");
    }

    #[test]
    fn match_expression_dedupes_and_quotes() {
        assert_eq!(match_expression("报销"), "\"报销\"");
        assert_eq!(match_expression("报销 报销"), "\"报销\"");
        assert_eq!(match_expression("杭州"), "\"杭州\"");
        assert_eq!(match_expression(""), "");
    }

    #[test]
    fn fields_add_subject_and_predicate() {
        let tokens = tokenize_fields("卡在价格", Some("A 公司"), Some("续约"));
        assert!(tokens.contains("a"));
        assert!(tokens.contains("公司"));
        assert!(tokens.contains("价格"));
        assert!(tokens.contains("续约"));
    }
}

#[cfg(test)]
mod subsumption_tests {
    use super::*;

    fn norm(text: &str) -> String {
        normalize_content(text)
    }

    #[test]
    fn longer_address_covers_shorter() {
        // 只差"是/在"：严格子串不成立，靠二元组覆盖率命中。
        let long = norm("用户的老家是浙江省嘉兴市南湖区八字桥村。");
        let short = norm("用户的老家在嘉兴市南湖区八字桥村。");
        assert!(covers(&long, &short));

        let mid = norm("用户的老家是浙江嘉兴南湖区");
        assert!(covers(&long, &mid), "同一地址的简写应被覆盖");
    }

    #[test]
    fn negation_is_never_covered() {
        let long = norm("用户喜欢吃香菜。");
        let short = norm("用户不喜欢香菜");
        assert!(!covers(&long, &short), "否定词丢失会把意思改反");
    }

    #[test]
    fn unrelated_content_is_not_covered() {
        let a = norm("用户的老家是浙江省嘉兴市南湖区八字桥村。");
        let b = norm("用户希望被称呼为老爷。");
        assert!(!covers(&a, &b));
    }

    #[test]
    fn identical_content_is_not_covered() {
        // 完全相同由去重闸处理；covers 只管"包含且更长"，避免同一句话
        // 在归并时被互相归档。
        let a = norm("用户是浙江嘉兴人。");
        assert!(!covers(&a, &a));
    }

    #[test]
    fn short_assertion_is_exempt() {
        // "老爷" 只有 2 字：被包含是常态，不能据此归档。
        let long = norm("用户希望被称呼为老爷。");
        let short = norm("老爷");
        assert!(!covers(&long, &short));
    }
}
