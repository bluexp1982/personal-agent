//! HTML 的最小化处理：字符集解码 + 正文抽取 + 结果页解析用的词法单元。
//!
//! 为什么手写而不是引入 `scraper` / `html5ever`：
//!
//! - 这里只需要两件事——跳过 `script`/`style` 子树取可见文本、从结果页里抠出
//!   "链接 + 标题 + 摘要"；不需要 CSS 选择器、不需要可变 DOM；
//! - 全量 DOM 的构建成本（依赖树、编译时间、二进制体积）与收益不成比例，
//!   与 `skills` 里手写 frontmatter 解析器是同一个取舍：受控的最小解析器更好审；
//! - 唯一"不完美"的地方是容错：非法嵌套按栈深度近似处理，正文抽取本身不需要
//!   精确树形结构，跳过子树只看标签名是否配对即可。

use std::borrow::Cow;

use encoding_rs::Encoding;

/// 一个 HTML 词法单元。属性保留原始字符串，取值由 [`attr`] / [`has_class`] 解析。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Token {
    Open {
        name: String,
        attrs: String,
        self_closing: bool,
    },
    Close {
        name: String,
    },
    Text(String),
}

/// 正文抽取时整段跳过的元素：内容不是给人读的，或者全是导航噪声。
const SKIP_TAGS: &[&str] = &[
    "script", "style", "noscript", "template", "svg", "iframe", "canvas", "object", "embed",
    "form", "nav", "footer", "aside",
];

/// 需要断行的块级元素：不加换行会把标题、列表、正文挤成一整段。
const BLOCK_TAGS: &[&str] = &[
    "p",
    "div",
    "br",
    "hr",
    "li",
    "ul",
    "ol",
    "tr",
    "table",
    "section",
    "article",
    "main",
    "blockquote",
    "pre",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
];

// ---------------------------------------------------------------------------
// 字符集
// ---------------------------------------------------------------------------

/// 按响应头 charset → `<meta charset>` → UTF-8 兜底解码。
///
/// 返回 `(文本, 是否有替换字符)`：第二个值为 true 表示编码没认出来或字节非法，
/// 调用方要把"可能有乱码"写进摘要，而不是假装读到了正文。
pub(crate) fn decode_body(bytes: &[u8], content_type: Option<&str>) -> (String, bool) {
    let label = content_type
        .and_then(charset_label)
        .or_else(|| sniff_charset(bytes));

    let encoding = label
        .as_deref()
        .and_then(|label| Encoding::for_label(label.as_bytes()));

    match encoding {
        Some(encoding) => {
            let (text, _, had_errors) = encoding.decode(bytes);
            (text.into_owned(), had_errors)
        }
        None => {
            let (text, _, had_errors) = encoding_rs::UTF_8.decode(bytes);
            (text.into_owned(), had_errors)
        }
    }
}

fn charset_label(content_type: &str) -> Option<String> {
    let lower = content_type.to_ascii_lowercase();
    let start = lower.find("charset=")? + "charset=".len();
    let rest = &lower[start..];
    let end = rest
        .find(|c: char| c == ';' || c.is_whitespace() || c == '"' || c == '\'')
        .unwrap_or(rest.len());
    let label = rest[..end].trim();
    if label.is_empty() {
        None
    } else {
        Some(label.to_string())
    }
}

/// 从文档头部猜字符集：只看前 2 KiB，避免为了 `<meta>` 扫描整个响应。
fn sniff_charset(bytes: &[u8]) -> Option<String> {
    let head = &bytes[..bytes.len().min(2048)];
    let text = String::from_utf8_lossy(head).to_ascii_lowercase();
    charset_label(&text)
}

// ---------------------------------------------------------------------------
// 词法
// ---------------------------------------------------------------------------

/// 把 HTML 切成 `Open` / `Close` / `Text` 三类单元。
///
/// 注释、`<!doctype>`、`<?xml?>` 直接丢弃；属性值里的 `>` 不会提前结束标签。
pub(crate) fn tokens(input: &str) -> Vec<Token> {
    let mut out = Vec::new();
    let mut rest = input;

    while !rest.is_empty() {
        let Some(start) = rest.find('<') else {
            push_text(&mut out, rest);
            break;
        };

        if start > 0 {
            push_text(&mut out, &rest[..start]);
        }

        let tail = &rest[start..];

        if tail.starts_with("<!--") {
            match tail.find("-->") {
                Some(end) => rest = &tail[end + 3..],
                None => break,
            }
            continue;
        }

        if tail.starts_with("<!") || tail.starts_with("<?") {
            match tail.find('>') {
                Some(end) => rest = &tail[end + 1..],
                None => break,
            }
            continue;
        }

        if let Some(after) = tail.strip_prefix("</") {
            let Some(end) = after.find('>') else { break };
            let name = tag_name(after[..end].trim());
            if !name.is_empty() {
                out.push(Token::Close { name });
            }
            rest = &after[end + 1..];
            continue;
        }

        let Some(end) = find_tag_end(tail) else { break };
        let inner = &tail[1..end];
        let trimmed = inner.trim_end();
        let self_closing = trimmed.ends_with('/');
        let body = trimmed.trim_end_matches('/');
        let name_end = body.find(|c: char| c.is_whitespace()).unwrap_or(body.len());
        let name = tag_name(&body[..name_end]);
        let attrs = body[name_end..].trim().to_string();

        if !name.is_empty() {
            out.push(Token::Open {
                name,
                attrs,
                self_closing,
            });
        }
        rest = &tail[end + 1..];
    }

    out
}

fn push_text(out: &mut Vec<Token>, raw: &str) {
    if raw.is_empty() {
        return;
    }
    // 纯空白的文本节点也要留：它承担着 `<span>foo</span> <span>bar</span>`
    // 之间的分隔，丢掉会把两个词粘成一个。空白统一由 `compact` 折叠。
    //
    // 先解码再合并：`a &amp; <!-- c --> b` 会被切成两段 Text。
    let decoded = decode_entities(raw);
    match out.last_mut() {
        Some(Token::Text(previous)) => previous.push_str(&decoded),
        _ => out.push(Token::Text(decoded.into_owned())),
    }
}

fn tag_name(raw: &str) -> String {
    raw.trim()
        .split(|c: char| c.is_whitespace() || c == '/')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase()
}

/// 找到开标签的结束 `>`，跳过引号内的内容。
fn find_tag_end(tail: &str) -> Option<usize> {
    let mut quote: Option<char> = None;

    for (index, ch) in tail.char_indices().skip(1) {
        match quote {
            Some(current) if ch == current => quote = None,
            Some(_) => {}
            None if ch == '"' || ch == '\'' => quote = Some(ch),
            None if ch == '>' => return Some(index),
            None => {}
        }
    }

    None
}

/// 为每个 `Open` 找到配对的 `Close` 下标；未闭合的指向 `tokens.len()`。
///
/// 有了它，"某个元素覆盖的区间"就是一段连续切片，解析结果页时不用自己维护深度。
pub(crate) fn matching_close(tokens: &[Token]) -> Vec<usize> {
    let mut matching = vec![tokens.len(); tokens.len()];
    let mut stack: Vec<usize> = Vec::new();

    for (index, token) in tokens.iter().enumerate() {
        match token {
            Token::Open { self_closing, .. } => {
                if !self_closing {
                    stack.push(index);
                }
            }
            Token::Close { .. } => {
                if let Some(open) = stack.pop() {
                    matching[open] = index;
                }
            }
            Token::Text(_) => {}
        }
    }

    matching
}

// ---------------------------------------------------------------------------
// 属性
// ---------------------------------------------------------------------------

/// 取一个属性的值（已做实体解码）。找不到返回 `None`。
pub(crate) fn attr(attrs: &str, name: &str) -> Option<String> {
    attribute_pairs(attrs)
        .into_iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value)
}

/// `class` 里是否包含指定类名（大小写不敏感，按空白切分）。
pub(crate) fn has_class(attrs: &str, class: &str) -> bool {
    let Some(value) = attr(attrs, "class") else {
        return false;
    };
    value
        .split_whitespace()
        .any(|item| item.eq_ignore_ascii_case(class))
}

/// `class` 里是否有以 `prefix` 开头的类名。
///
/// 结果页常用"类名 + 序号"的写法（Bing 的 `b_lineclamp4`、`b_adLastChild`），
/// 精确匹配会漏掉它们。`prefix` 必须是全小写。
pub(crate) fn has_class_prefix(attrs: &str, prefix: &str) -> bool {
    let Some(value) = attr(attrs, "class") else {
        return false;
    };
    value
        .split_whitespace()
        .any(|item| item.to_ascii_lowercase().starts_with(prefix))
}

fn attribute_pairs(attrs: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = attrs.trim();

    while !rest.is_empty() {
        let key_end = rest
            .find(|c: char| c.is_whitespace() || c == '=' || c == '/')
            .unwrap_or(rest.len());
        if key_end == 0 {
            // 裸的 `/`：跳过一个字节继续，避免死循环。
            rest = &rest[1..];
            continue;
        }

        let key = rest[..key_end].to_ascii_lowercase();
        rest = rest[key_end..].trim_start();

        let mut value = String::new();
        if let Some(after_eq) = rest.strip_prefix('=') {
            let after_eq = after_eq.trim_start();
            let quote = after_eq.chars().next().filter(|c| *c == '"' || *c == '\'');
            match quote {
                Some(quote) => {
                    let inner = &after_eq[quote.len_utf8()..];
                    let end = inner.find(quote).unwrap_or(inner.len());
                    value = inner[..end].to_string();
                    rest = inner[end..].strip_prefix(quote).unwrap_or("").trim_start();
                }
                None => {
                    let end = after_eq.find(char::is_whitespace).unwrap_or(after_eq.len());
                    value = after_eq[..end].to_string();
                    rest = after_eq[end..].trim_start();
                }
            }
        }

        out.push((key, decode_entities(&value).into_owned()));
    }

    out
}

// ---------------------------------------------------------------------------
// 正文
// ---------------------------------------------------------------------------

/// 抽取可见正文：跳过脚本、样式、导航，块级元素断行，空白折叠后按字符数截断。
pub(crate) fn extract_text(html: &str, max_chars: usize) -> String {
    let mut raw = String::new();
    let mut skip_depth = 0usize;

    for token in tokens(html) {
        match token {
            Token::Open {
                name, self_closing, ..
            } => {
                if is_block(&name) && skip_depth == 0 {
                    raw.push('\n');
                }
                if is_skip(&name) && !self_closing {
                    skip_depth += 1;
                }
            }
            Token::Close { name } => {
                if is_skip(&name) {
                    skip_depth = skip_depth.saturating_sub(1);
                } else if is_block(&name) && skip_depth == 0 {
                    raw.push('\n');
                }
            }
            Token::Text(text) => {
                if skip_depth == 0 {
                    // 不再补空格：`<b>浙江</b>省` 补了就会变成"浙江 省"，
                    // 源文件里的空白本身已经在文本节点里。
                    raw.push_str(&text);
                }
            }
        }
    }

    compact(&raw, max_chars)
}

fn is_skip(name: &str) -> bool {
    SKIP_TAGS.contains(&name)
}

fn is_block(name: &str) -> bool {
    BLOCK_TAGS.contains(&name)
}

fn compact(raw: &str, max_chars: usize) -> String {
    let mut out = String::new();

    for line in raw.split('\n') {
        let normalized = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if normalized.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&normalized);
    }

    truncate(&out, max_chars)
}

/// 按字符截断（不是字节），超出时补省略号。
pub(crate) fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(max_chars).collect();
    truncated.push('…');
    truncated
}

// ---------------------------------------------------------------------------
// 实体
// ---------------------------------------------------------------------------

/// 解码常见 HTML 实体。未知实体原样保留——宁可露出 `&foo;`，也不要猜错含义。
pub(crate) fn decode_entities(input: &str) -> Cow<'_, str> {
    if !input.contains('&') {
        return Cow::Borrowed(input);
    }

    let mut out = String::with_capacity(input.len());
    let mut rest = input;

    while let Some(position) = rest.find('&') {
        out.push_str(&rest[..position]);
        let after = &rest[position..];

        let Some(end) = after[1..].find(';').map(|index| index + 1) else {
            out.push_str(after);
            return Cow::Owned(out);
        };

        // 实体名不会超过 10 个字符；超长的多半是正文里的普通 `&`。
        if end > 10 {
            out.push('&');
            rest = &after[1..];
            continue;
        }

        let entity = &after[1..end];
        match entity_char(entity) {
            Some(ch) => out.push(ch),
            None => out.push_str(&after[..=end]),
        }
        rest = &after[end + 1..];
    }

    out.push_str(rest);
    Cow::Owned(out)
}

fn entity_char(entity: &str) -> Option<char> {
    if let Some(number) = entity.strip_prefix('#') {
        let code = match number.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => number.parse::<u32>().ok()?,
        };
        return char::from_u32(code);
    }

    let ch = match entity.to_ascii_lowercase().as_str() {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" | "ensp" | "emsp" => ' ',
        "mdash" => '—',
        "ndash" => '–',
        "hellip" => '…',
        "middot" => '·',
        "bull" => '•',
        "copy" => '©',
        "reg" => '®',
        "trade" => '™',
        "times" => '×',
        "divide" => '÷',
        "laquo" => '«',
        "raquo" => '»',
        "ldquo" => '“',
        "rdquo" => '”',
        "lsquo" => '‘',
        "rsquo" => '’',
        "deg" => '°',
        "plusmn" => '±',
        "sect" => '§',
        "para" => '¶',
        "euro" => '€',
        "pound" => '£',
        "yen" => '¥',
        "cent" => '¢',
        _ => return None,
    };
    Some(ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_script_and_style() {
        let html = r#"<html><head><style>.a{color:red}</style></head>
            <body><script>var x = "<p>假正文</p>";</script><p>真正文</p></body></html>"#;
        let text = extract_text(html, 200);
        assert_eq!(text, "真正文");
    }

    #[test]
    fn keeps_block_boundaries() {
        let html = "<div>第一段</div><div>第二段</div>";
        assert_eq!(extract_text(html, 200), "第一段\n第二段");
    }

    #[test]
    fn decodes_entities_and_truncates() {
        let html = "<p>A&amp;B &lt;tag&gt; &#65; &#x42;</p>";
        assert_eq!(extract_text(html, 200), "A&B <tag> A B");

        let long = extract_text("<p>啊啊啊啊啊啊</p>", 3);
        assert_eq!(long, "啊啊啊…");
    }

    #[test]
    fn empty_document_yields_empty_text() {
        assert_eq!(extract_text("", 100), "");
        assert_eq!(extract_text("<script>1</script>", 100), "");
    }

    #[test]
    fn charset_from_header_wins() {
        // GBK 编码的"国中"：B9 FA D6 D0
        let bytes = [0xB9, 0xFA, 0xD6, 0xD0];
        let (text, lossy) = decode_body(&bytes, Some("text/html; charset=gbk"));
        assert_eq!(text, "国中");
        assert!(!lossy);
    }

    #[test]
    fn charset_sniffed_from_meta_when_header_missing() {
        let mut bytes =
            br#"<meta http-equiv="Content-Type" content="text/html; charset=gbk">"#.to_vec();
        bytes.extend_from_slice(&[0xB9, 0xFA]);
        let (text, _) = decode_body(&bytes, Some("text/html"));
        assert!(text.contains("国"), "应能按 meta 里的 gbk 解码: {text}");
    }

    #[test]
    fn invalid_bytes_are_flagged() {
        let (_, lossy) = decode_body(&[0xff, 0xfe, 0xfd], Some("text/html; charset=utf-8"));
        assert!(lossy, "非法 UTF-8 必须标记为可能乱码");
    }

    #[test]
    fn attributes_handle_quotes_and_gt() {
        let attrs =
            r#" rel="nofollow" class='result__a' title="a>b" href="https://example.com/x?y=1""#;
        assert_eq!(
            attr(attrs, "href").as_deref(),
            Some("https://example.com/x?y=1")
        );
        assert!(has_class(attrs, "result__a"));
        assert!(!has_class(attrs, "result__b"));
    }

    #[test]
    fn matching_close_maps_container_ranges() {
        let tokens = tokens("<div><a>x</a></div><p>y</p>");
        let matching = matching_close(&tokens);
        assert_eq!(matching[0], 4, "div 应以 </div> 结束");
        assert_eq!(matching[1], 3, "a 应以 </a> 结束");
        assert_eq!(tokens.len(), 8);
    }
}
