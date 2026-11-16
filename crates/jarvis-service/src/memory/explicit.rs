//! 「记住…」口头指令：识别 + 类型推断。
//!
//! **纯函数，不碰数据库、不调模型**。写入本身走 [`super::MemoryService::remember_explicit`]，
//! 这里只回答"这句话是不是一条显式记忆指令、要记的是什么、算哪一类"。
//!
//! 为什么要有这条路：会话抽取是"回答结束后由后台模型判断"，用户说「记住…」
//! 却可能因为回答太短、抽取模型认为不值得记、或证据没逐字对上而什么也没留下，
//! 且用户无从得知。显式指令把它变成确定行为。

use protocol::MemoryKind;

/// 触发前缀。**必须按长度倒序匹配**：「请帮我记住」如果让「记住」先匹配，
/// 内容里就会多出「我帮我」这类残渣。
const PREFIXES: &[&str] = &[
    "请帮我记住",
    "帮我记住",
    "请记住",
    "麻烦记住",
    "记下来",
    "记一下",
    "记下",
    "记住",
];

/// 偏好类关键词：判断"这是不是个人口味/习惯"。
const PREFERENCE_WORDS: &[&str] = &[
    "喜欢",
    "不喜欢",
    "讨厌",
    "偏好",
    "习惯",
    "口味",
    "爱吃",
    "爱喝",
    "忌口",
    "不吃",
    "不喝",
];

/// 事件类关键词：带具体时间点或一次性安排。
///
/// 刻意不收「年」「月」这种单独的粒度：『2007 年出生』是稳定身份事实，
/// 归成事件会让画像里的人生信息散落到时间线上。
const EVENT_WORDS: &[&str] = &[
    "明天",
    "后天",
    "昨天",
    "今天",
    "今晚",
    "明早",
    "下周",
    "上周",
    "下个月",
    "上个月",
    "周一会",
    "周二会",
    "周一",
    "周二",
    "周三",
    "周四",
    "周五",
    "周六",
    "周日",
    "星期一",
    "星期二",
    "星期三",
    "星期四",
    "星期五",
    "星期六",
    "星期日",
    "会议",
    "开会",
    "截止",
    "出差",
    "预约",
    "日程",
    "面试",
    "见面",
    "出发",
    "deadline",
];

/// 一条用户消息的识别结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExplicitCommand {
    /// 不是记忆指令，按普通消息处理。
    NotACommand,
    /// 是指令但没说要记什么（只有「记住」或内容不足两个字）。
    MissingContent,
    /// 要记住的内容与推断出的分类。
    Remember { content: String, kind: MemoryKind },
}

/// 识别一句话。
///
/// 规则（与产品约定一致）：
/// - 只认**开头**的前缀，句中出现的「记住」不算；
/// - 前缀后允许跟 `：` `:` `，` `,` `。` `、` 与空白，一并剥掉；
/// - 剩余不足 2 字 → [`ExplicitCommand::MissingContent`]（提示用户补内容）；
/// - 剩余以问号结尾 → [`ExplicitCommand::NotACommand`]：
///   「记住我刚才说的了吗？」是在提问，不是下指令。
pub fn parse(text: &str) -> ExplicitCommand {
    let trimmed = text.trim();
    let Some(rest) = PREFIXES
        .iter()
        .find_map(|prefix| trimmed.strip_prefix(prefix))
    else {
        return ExplicitCommand::NotACommand;
    };

    let content = rest
        .trim_start_matches(|ch: char| {
            ch.is_whitespace() || matches!(ch, '：' | ':' | '，' | ',' | '。' | '、' | '—' | '-')
        })
        .trim();

    if content.chars().count() < 2 {
        return ExplicitCommand::MissingContent;
    }
    if content.ends_with('？') || content.ends_with('?') {
        return ExplicitCommand::NotACommand;
    }

    ExplicitCommand::Remember {
        content: content.to_string(),
        kind: infer_kind(content),
    }
}

/// 按关键词推断分类。
///
/// 偏好优先于事件：『喜欢周五开会』想记的是口味，不是一场会议。
pub fn infer_kind(content: &str) -> MemoryKind {
    if PREFERENCE_WORDS.iter().any(|word| content.contains(word)) {
        return MemoryKind::Preference;
    }
    if EVENT_WORDS.iter().any(|word| content.contains(word)) {
        return MemoryKind::Event;
    }
    MemoryKind::Profile
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_longest_prefix_first() {
        // 「帮我记住」必须先于「记住」匹配，否则内容会多出「我」。
        assert_eq!(
            parse("帮我记住：我对花生过敏"),
            ExplicitCommand::Remember {
                content: "我对花生过敏".to_string(),
                kind: MemoryKind::Profile,
            }
        );
    }

    #[test]
    fn strips_separators_and_spaces() {
        for text in ["记住：报销走飞书", "记住: 报销走飞书", "记住，报销走飞书"]
        {
            match parse(text) {
                ExplicitCommand::Remember { content, .. } => {
                    assert_eq!(content, "报销走飞书", "输入：{text}");
                }
                other => panic!("应识别为指令，实际 {other:?}"),
            }
        }
    }

    #[test]
    fn missing_content_is_reported() {
        assert_eq!(parse("记住"), ExplicitCommand::MissingContent);
        assert_eq!(parse("记住：  "), ExplicitCommand::MissingContent);
        assert_eq!(parse("帮我记住：好"), ExplicitCommand::MissingContent);
    }

    #[test]
    fn question_is_not_a_command() {
        // 用户在问「你还记得吗」，不是在要求保存。
        assert_eq!(parse("记住我刚才说的了吗？"), ExplicitCommand::NotACommand);
        assert_eq!(parse("记住这个了吗?"), ExplicitCommand::NotACommand);
    }

    #[test]
    fn prefix_inside_sentence_is_ignored() {
        assert_eq!(parse("我记住你的建议了"), ExplicitCommand::NotACommand);
        assert_eq!(parse("请你记住这句话"), ExplicitCommand::NotACommand);
    }

    #[test]
    fn infers_kind_from_keywords() {
        assert_eq!(infer_kind("我不喜欢吃香菜"), MemoryKind::Preference);
        assert_eq!(infer_kind("明天下午三点开会"), MemoryKind::Event);
        assert_eq!(infer_kind("我儿子叫小姚，2007 年出生"), MemoryKind::Profile);
        // 偏好优先：这场会只是"讨厌"的宾语。
        assert_eq!(infer_kind("我讨厌周五开会"), MemoryKind::Preference);
    }
}
