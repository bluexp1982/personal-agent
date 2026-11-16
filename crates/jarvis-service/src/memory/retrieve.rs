//! 召回：候选集 + 五维打分 + 召回日志。
//!
//! 候选集口径（开发方案 4.3 / 6.5）：
//! 1. 先走 FTS5（写入侧做过 bigram 预分词，中文两字查询也能命中）；
//! 2. 命中数不足 `limit` 时才触发 LIKE 兜底，且**必须**同时带结构化过滤
//!    （`status IN ('active','stale')` + 作用域）与时间窗，最多扫 500 行；
//! 3. 全表 LIKE 既不设限也不带过滤，写入一多就会把列表拖慢，这里不允许。
//!
//! 打分权重来自 `memory.recall.weights`（默认 0.45 / 0.20 / 0.15 / 0.10 / 0.10）。

use protocol::{Memory, MemoryKind};
use sqlx::SqlitePool;

use super::store::MemoryRow;
use super::{privacy, tokenize, MemoryError};
use crate::config::MemoryRecallConfig;

/// LIKE 兜底最多扫多少行。超出的部分不参与打分：宁可少召回，也不做无界扫。
const LIKE_FALLBACK_LIMIT: usize = 500;

/// LIKE 兜底的时间窗：两年前的记忆基本不会再被问到。
const LIKE_FALLBACK_DAYS: i64 = 730;

/// 检索作用域。
///
/// `Code` 与 `Work` 的差别只在"允许哪些 kinds"与"私密记忆是否可见"，
/// 判定集中在 [`privacy::visible_in_scope`]，这里不重复写条件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecallScope {
    Work { project_id: Option<String> },
    Code { project_id: Option<String> },
}

impl RecallScope {
    /// 按会话模式构造：Git 项目会话只看得见工程偏好与当前仓库的项目约定。
    pub fn for_mode(code: bool, project_id: Option<String>) -> Self {
        if code {
            Self::Code { project_id }
        } else {
            Self::Work { project_id }
        }
    }

    pub fn project_id(&self) -> Option<&str> {
        match self {
            Self::Work { project_id } | Self::Code { project_id } => project_id.as_deref(),
        }
    }

    pub fn is_code(&self) -> bool {
        matches!(self, Self::Code { .. })
    }
}

/// 一次召回请求。
#[derive(Debug, Clone)]
pub struct RecallQuery {
    /// 模型改写后的查询文本（不是用户原句）。
    pub text: String,
    pub scope: RecallScope,
    /// 空 = 该作用域允许的全部类型。
    pub kinds: Vec<MemoryKind>,
    /// 上限 1..=8：再多会挤占推理空间。
    pub limit: usize,
    pub now: i64,
    pub conversation_id: Option<String>,
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct RecallScore {
    pub text: f32,
    pub recency: f32,
    pub importance: f32,
    pub scope: f32,
    pub feedback: f32,
    pub total: f32,
}

#[derive(Debug, Clone)]
pub struct RecallHit {
    pub memory: Memory,
    pub score: RecallScore,
}

#[derive(Debug, Clone)]
pub struct RecallOutcome {
    pub hits: Vec<RecallHit>,
    /// 是否用了 LIKE 兜底。长期观测"FTS 在真实语料下够不够用"靠这个标志。
    pub fallback_used: bool,
    /// 参与打分的候选数（不含被作用域过滤掉的）。
    pub candidates: usize,
}

/// FTS5 的 `bm25()` 返回**负数**，越负越相关；`1/(1+raw)` 会把所有命中都算成 1.0。
///
/// 改成 `|raw|/(1+|raw|)`：完全无关时趋近 0，强相关时趋近 1，且对量级不敏感。
pub fn bm25_to_score(raw: f64) -> f32 {
    let magnitude = raw.abs();
    (magnitude / (1.0 + magnitude)) as f32
}

/// 执行一次召回。失败只返回错误，由调用方决定怎么回填给模型。
pub async fn recall(
    pool: &SqlitePool,
    config: &MemoryRecallConfig,
    query: RecallQuery,
) -> Result<RecallOutcome, MemoryError> {
    let limit = query.limit.clamp(1, 8);
    let expression = tokenize::match_expression(&query.text);
    let mut candidates: Vec<(MemoryRow, Option<f64>)> = Vec::new();
    let mut fallback_used = false;

    if !expression.is_empty() {
        let rows: Vec<RankedRow> = sqlx::query_as(RANKED_SQL)
            .bind(&expression)
            .bind(query.scope.project_id())
            // `(? IS NULL OR kind IN (?…))` 的守卫本身占一个参数位，
            // 漏掉它会让后面的参数整体错位（SQLite 报 datatype mismatch）。
            .bind(kind_slot(&query.kinds, 0))
            .bind(kind_slot(&query.kinds, 0))
            .bind(kind_slot(&query.kinds, 1))
            .bind(kind_slot(&query.kinds, 2))
            .bind(kind_slot(&query.kinds, 3))
            .bind((limit * 5) as i64)
            .fetch_all(pool)
            .await?;

        candidates.extend(rows.into_iter().map(|row| (row.memory, Some(row.score))));
    }

    if candidates.len() < limit {
        fallback_used = true;
        let since = query.now - LIKE_FALLBACK_DAYS * 86_400_000;
        let pattern = format!("%{}%", tokenize::normalize_for_match(&query.text));
        let rows: Vec<MemoryRow> = sqlx::query_as(LIKE_SQL)
            .bind(query.scope.project_id())
            .bind(kind_slot(&query.kinds, 0))
            .bind(kind_slot(&query.kinds, 0))
            .bind(kind_slot(&query.kinds, 1))
            .bind(kind_slot(&query.kinds, 2))
            .bind(kind_slot(&query.kinds, 3))
            .bind(&pattern)
            .bind(&pattern)
            .bind(since)
            .bind(LIKE_FALLBACK_LIMIT as i64)
            .fetch_all(pool)
            .await?;

        // 与 FTS 结果按 id 去重：同一条记忆被两条路径命中只算一次（取更高的文本分）。
        for row in rows {
            if candidates.iter().any(|(existing, _)| existing.id == row.id) {
                continue;
            }
            candidates.push((row, None));
        }
    }

    let candidates_len = candidates.len();
    let mut hits: Vec<RecallHit> = Vec::new();
    for (row, rank) in candidates {
        // 反馈计数只在打分时用得到，`Memory` 里没有这两个字段，转换前先摘出来。
        let useful = row.useful_count;
        let useless = row.useless_count;
        let memory = row.into_memory()?;
        // 唯一的作用域判定处：编码场景在这里被挡掉私密与生活类记忆。
        if !privacy::visible_in_scope(&memory, &query.scope) {
            continue;
        }
        let score = score_of(&memory, useful, useless, rank, config, &query);
        hits.push(RecallHit { memory, score });
    }

    // 排序要确定：同分时按更新时间、再按 id，测试才能断言顺序。
    hits.sort_by(|left, right| {
        right
            .score
            .total
            .partial_cmp(&left.score.total)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| right.memory.updated_at.cmp(&left.memory.updated_at))
            .then_with(|| right.memory.id.cmp(&left.memory.id))
    });
    hits.truncate(limit);

    Ok(RecallOutcome {
        hits,
        fallback_used,
        candidates: candidates_len,
    })
}

/// 把本轮命中记进召回日志。`used` 由回答落库后回填（见 `touch_used`）。
pub async fn log_hits(
    pool: &SqlitePool,
    query: &RecallQuery,
    hits: &[RecallHit],
) -> Result<(), MemoryError> {
    for (index, hit) in hits.iter().enumerate() {
        sqlx::query(
            "INSERT INTO memory_recall_log \
              (id, conversation_id, message_id, query, memory_id, rank, score, used, feedback, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)",
        )
        .bind(crate::ids::new_id("rcl"))
        .bind(&query.conversation_id)
        .bind(&query.message_id)
        .bind(&query.text)
        .bind(&hit.memory.id)
        .bind(index as i64)
        .bind(f64::from(hit.score.total))
        .bind(query.now)
        .execute(pool)
        .await?;
    }

    Ok(())
}

const RANKED_SQL: &str = "SELECT m.*, bm25(memories_fts) AS score \
     FROM memories_fts JOIN memories m ON m.rowid = memories_fts.rowid \
     WHERE memories_fts MATCH ? \
       AND m.deleted_at IS NULL AND m.status IN ('active','stale') \
       AND (m.scope = 'global' OR m.project_id = ?) \
       AND (? IS NULL OR m.kind IN (?, ?, ?, ?)) \
     ORDER BY bm25(memories_fts) LIMIT ?";

const LIKE_SQL: &str = "SELECT * FROM memories \
     WHERE deleted_at IS NULL AND status IN ('active','stale') \
       AND (scope = 'global' OR project_id = ?) \
       AND (? IS NULL OR kind IN (?, ?, ?, ?)) \
       AND (content LIKE ? OR subject LIKE ?) \
       AND created_at >= ? \
     ORDER BY updated_at DESC, id DESC LIMIT ?";

/// 四类 `kind` 固定四个槽位：`MemoryKind` 恰好四个取值，动态拼 SQL 反而要绕开 `SqlSafeStr`。
fn kind_slot(kinds: &[MemoryKind], index: usize) -> Option<&'static str> {
    if kinds.is_empty() {
        return None;
    }
    kinds.get(index).map(|kind| kind.as_str())
}

#[derive(Debug, sqlx::FromRow)]
struct RankedRow {
    #[sqlx(flatten)]
    memory: MemoryRow,
    /// FTS5 的 bm25 值（负数，越负越相关）。列名不能叫 `rank`：
    /// `rank` 是 FTS5 的隐藏列名，`AS rank` 会触发 SQLITE_MISMATCH。
    score: f64,
}

fn score_of(
    memory: &Memory,
    useful: i64,
    useless: i64,
    rank: Option<f64>,
    config: &MemoryRecallConfig,
    query: &RecallQuery,
) -> RecallScore {
    let text = match rank {
        Some(raw) => bm25_to_score(raw),
        // LIKE 兜底没有 bm25：给一个固定中位数，不假装知道相关度。
        None => 0.5,
    };

    let days = ((query.now - memory.created_at).max(0) as f64) / 86_400_000.0;
    let half_life = match memory.kind {
        MemoryKind::Event => 30.0,
        MemoryKind::Project => 90.0,
        // 画像与偏好不过期：它们描述的是"这个人是谁"，不是"某天发生了什么"。
        MemoryKind::Profile | MemoryKind::Preference => 3650.0,
    };
    let recency = 0.5f32.powf((days / half_life) as f32);

    let importance = memory.importance.clamp(0.0, 1.0);
    let scope = if memory.scope == protocol::MemoryScope::Project
        && memory.project_id.as_deref() == query.scope.project_id()
        && memory.project_id.is_some()
    {
        1.0
    } else {
        0.6
    };
    let feedback = (0.5 + 0.1 * (useful - useless) as f32).clamp(0.0, 1.0);

    let weights = &config.weights;
    let total = weights.text * text
        + weights.recency * recency
        + weights.importance * importance
        + weights.scope * scope
        + weights.feedback * feedback;

    RecallScore {
        text,
        recency,
        importance,
        scope,
        feedback,
        total,
    }
}

// ---------------------------------------------------------------------------
// "该查没查"的启发式
// ---------------------------------------------------------------------------

/// 一句提问里的召回线索。
///
/// 用于事后观测，不参与任何判定：命中与否都不影响回答，只写一条
/// `memory.unrecalled` 审计，让我们知道"模型该查记忆却没查"的比例。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RecallCue {
    /// 出现人名（常见姓氏 + 1~2 个汉字）。
    pub has_person_name: bool,
    /// 出现时间指代（今天/上周/几号/3 月 5 日）。
    pub has_date: bool,
    /// 出现回指（上次/之前/我说过/还记得）。
    pub has_reference: bool,
}

impl RecallCue {
    /// 是否"明显该查记忆"。
    ///
    /// 判据刻意保守：回指词单独成立（"上次那个"一定是记忆问题）；
    /// 人名与时间要**同时**出现才算——只说"明天"多半在问天气，
    /// 误报会把审计表刷成噪音，反而没人看。
    pub fn should_recall(self) -> bool {
        self.has_reference || (self.has_person_name && self.has_date)
    }
}

/// 回指词：出现即说明"在指代过去说过的东西"。
const REFERENCE_WORDS: &[&str] = &[
    "上次",
    "上回",
    "之前",
    "以前",
    "那次",
    "那个",
    "我说过",
    "我提过",
    "我跟你说",
    "和你说过",
    "还记得",
    "不是说过",
    "继续上次",
    "老样子",
];

/// 时间指代。
const DATE_WORDS: &[&str] = &[
    "今天",
    "明天",
    "后天",
    "昨天",
    "前天",
    "本周",
    "这周",
    "上周",
    "下周",
    "这个月",
    "上个月",
    "下个月",
    "几号",
    "哪天",
    "什么时候",
];

/// 常见姓氏。不做完整姓名库：这里只求"像人名"，不求准确。
const SURNAMES: &[char] = &[
    '张', '王', '李', '赵', '刘', '陈', '杨', '黄', '周', '吴', '徐', '孙', '马', '朱', '胡', '郭',
    '何', '高', '林', '罗', '郑', '梁', '谢', '宋', '唐', '许', '韩', '邓', '冯', '曹', '彭', '曾',
    '肖', '田', '董', '袁', '潘', '蒋', '蔡', '余', '杜', '叶', '程', '苏', '魏', '吕', '丁', '任',
    '沈', '姚', '卢', '姜', '崔', '钟', '谭', '陆', '汪', '范', '金', '石', '廖', '贾', '夏', '韦',
    '付', '方', '白', '邹', '孟', '熊', '秦', '邱', '江', '尹', '薛', '闫', '段', '雷', '侯', '龙',
    '史', '陶', '黎', '贺', '顾', '毛', '郝', '龚', '邵', '万', '钱', '严', '覃', '武', '戴', '莫',
    '孔', '向', '汤',
];

/// 判断一句话里有没有召回线索。
pub fn recall_cue(text: &str) -> RecallCue {
    let normalized = super::tokenize::normalize_for_match(text);

    RecallCue {
        has_person_name: has_person_name(&normalized),
        has_date: DATE_WORDS.iter().any(|word| normalized.contains(word))
            || has_numeric_date(&normalized),
        has_reference: REFERENCE_WORDS.iter().any(|word| normalized.contains(word)),
    }
}

/// 姓氏 + 至少 1 个汉字，且紧跟的字不是"的/说/是/在"这类会把它变普通词的助词。
///
/// 只求"像人名"：常见姓氏发音的字太多（高、金、于……），所以额外用
/// 后接助词来排掉"王的""李说"这种明显不是名字的情况。
fn has_person_name(text: &str) -> bool {
    let chars: Vec<char> = text.chars().filter(|ch| !ch.is_whitespace()).collect();
    for (index, ch) in chars.iter().enumerate() {
        if !SURNAMES.contains(ch) {
            continue;
        }
        let Some(next) = chars.get(index + 1) else {
            continue;
        };
        if matches!(next, '的' | '说' | '是' | '在' | '们' | '和' | '了') || !is_han(*next) {
            continue;
        }
        return true;
    }
    false
}

/// `3 月 5 日` / `3/5` 这类数字日期。
///
/// 先去掉空白：中文习惯写"3 月 5 日"，带空格时按字节邻接判定会漏。
fn has_numeric_date(text: &str) -> bool {
    let chars: Vec<char> = text.chars().filter(|ch| !ch.is_whitespace()).collect();
    chars.windows(2).any(|pair| {
        (pair[0].is_ascii_digit() && matches!(pair[1], '月' | '日' | '号'))
            || (pair[0].is_ascii_digit() && pair[1] == '/')
    })
}

fn is_han(ch: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bm25_keeps_ordering_direction() {
        // FTS5 的 bm25 是负数：-3 比 -0.5 更相关。
        let strong = bm25_to_score(-3.0);
        let weak = bm25_to_score(-0.5);
        assert!(strong > weak, "更相关的那条必须得分更高");
        assert!(weak > 0.0);
        assert!(strong < 1.0);
    }

    #[test]
    fn zero_rank_maps_to_zero() {
        assert_eq!(bm25_to_score(0.0), 0.0);
    }
}

#[cfg(test)]
mod cue_tests {
    use super::*;

    #[test]
    fn reference_word_alone_is_enough() {
        let cue = recall_cue("上次那个方案是怎么定的");
        assert!(cue.has_reference);
        assert!(cue.should_recall(), "回指词单独成立");
    }

    #[test]
    fn plain_question_is_not_a_cue() {
        let cue = recall_cue("明天天气怎么样");
        assert!(!cue.should_recall(), "只问天气不该算\"该查记忆\"");
    }

    #[test]
    fn person_and_date_together_is_a_cue() {
        let cue = recall_cue("王工下周三有空吗");
        assert!(cue.has_person_name);
        assert!(cue.has_date);
        assert!(cue.should_recall());
    }

    #[test]
    fn name_like_word_needs_boundary() {
        // "王的" 这种不是人名：姓氏后面接"的"会被排除。
        assert!(!recall_cue("这个王的配色不好看").has_person_name);
        // 正常的两个字姓名。
        assert!(recall_cue("张三今天来吗").has_person_name);
    }

    #[test]
    fn numeric_date_is_recognized() {
        assert!(recall_cue("3 月 5 日要交材料").has_date);
        assert!(recall_cue("3/5 之前给我").has_date);
    }
}
