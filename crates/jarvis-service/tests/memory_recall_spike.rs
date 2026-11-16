//! MP-01：中文召回基线（手动跑，不进常规回归）。
//!
//! ```text
//! cargo test -p jarvis-service --test memory_recall_spike -- --ignored --nocapture
//! ```
//!
//! 用同一批合成语料（`tests/fixtures/memory_recall_cases.ndjson`：200 条种子记忆 +
//! 30 条查询，其中 10 条是两字短查询）对比三种索引方案：
//!
//! | 方案 | 建表 | 查询侧 |
//! | --- | --- | --- |
//! | A `unicode61` 直索正文 | `tokenize='unicode61'`，存原文 | 整句当短语查 |
//! | B `trigram` | `tokenize='trigram'`，存原文 | 整句当子串查 |
//! | C bigram 预分词（**主选**） | `tokenize='unicode61'`，存 `tokenize_for_index` | `match_expression`（OR 连接） |
//!
//! 门槛（开发方案 10.1）：中文 Top-8 命中 ≥80%，两字查询单独 ≥80%，
//! P90 检索延迟 ≤50ms，索引体积 ≤正文 1.5×。不通过时的回退路径见 4.3。
//!
//! 这不是统计意义上的评测：语料是合成且刻意让查询与目标记忆共享关键词。
//! 它只回答"三种索引里哪一种在中文下能命中、代价多大"。

use std::path::Path;
use std::time::Instant;

use sqlx::sqlite::SqlitePoolOptions;
use sqlx::SqlitePool;

use jarvis_service::memory::tokenize;

const FIXTURE: &str = include_str!("fixtures/memory_recall_cases.ndjson");

/// 每条查询重复次数：单次耗时会受调度抖动影响，取多次分位数。
const REPS: usize = 5;

#[derive(Debug)]
struct Seed {
    id: String,
    content: String,
}

#[derive(Debug)]
struct Case {
    query: String,
    expect: Vec<String>,
    two_char: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scheme {
    Unicode61,
    Trigram,
    Bigram,
}

impl Scheme {
    const ALL: [Self; 3] = [Self::Unicode61, Self::Trigram, Self::Bigram];

    fn name(self) -> &'static str {
        match self {
            Self::Unicode61 => "A unicode61",
            Self::Trigram => "B trigram",
            Self::Bigram => "C bigram",
        }
    }

    /// 建表语句必须是字面量（sqlx 0.9 的 `SqlSafeStr` 不接受运行时拼接的 SQL）。
    fn ddl(self) -> &'static str {
        match self {
            Self::Unicode61 | Self::Bigram => {
                "CREATE VIRTUAL TABLE spike_fts \
                 USING fts5(id UNINDEXED, body, tokenize='unicode61')"
            }
            Self::Trigram => {
                "CREATE VIRTUAL TABLE spike_fts \
                 USING fts5(id UNINDEXED, body, tokenize='trigram')"
            }
        }
    }

    /// 每套方案一个独立库文件，名字不能只靠 tokenizer（A 与 C 共用 unicode61）。
    fn slug(self) -> &'static str {
        match self {
            Self::Unicode61 => "unicode61-raw",
            Self::Trigram => "trigram",
            Self::Bigram => "bigram",
        }
    }

    /// 索引里存什么：A/B 存原文，C 存预分词串。
    fn indexed_text(self, content: &str) -> String {
        match self {
            Self::Unicode61 | Self::Trigram => tokenize::normalize_for_match(content),
            Self::Bigram => tokenize::tokenize_for_index(content),
        }
    }

    /// 查询侧表达式。A/B 只能把整句当短语/子串，C 用 OR 连接词条。
    fn query(self, raw: &str) -> String {
        match self {
            Self::Unicode61 | Self::Trigram => {
                format!(
                    "\"{}\"",
                    tokenize::normalize_for_match(raw).replace('"', "\"\"")
                )
            }
            Self::Bigram => tokenize::match_expression(raw),
        }
    }
}

#[derive(Debug)]
struct Report {
    scheme: Scheme,
    cases: usize,
    /// Top-8 里出现了至少一条期望记忆的查询数。
    hits: usize,
    /// 期望集合的平均召回率（多期望时按比例算）。
    recall: f64,
    two_char_cases: usize,
    two_char_hits: usize,
    p50_us: u128,
    p90_us: u128,
    /// 索引字节 / 正文字节。
    index_ratio: f64,
    /// 索引绝对字节数与每行摊到的索引字节（短记忆下这比 ratio 更能说明真实开销）。
    index_bytes: u64,
    bytes_per_row: f64,
    query_errors: usize,
}

#[tokio::test]
#[ignore = "MP-01 中文召回基线：手动跑，需要 --nocapture 看结论表"]
async fn chinese_recall_spike() {
    assert_fts5_available().await;

    let (seeds, cases) = load_fixture();
    assert_eq!(seeds.len(), 200, "种子记忆应为 200 条");
    assert_eq!(cases.len(), 30, "查询用例应为 30 条");
    assert_eq!(
        cases.iter().filter(|case| case.two_char).count(),
        10,
        "两字短查询应为 10 条"
    );

    let dir = tempfile::tempdir().expect("创建临时目录失败");
    let mut reports = Vec::new();
    for scheme in Scheme::ALL {
        reports.push(run_scheme(scheme, &seeds, &cases, dir.path()).await);
    }

    print_report(&reports);
    assert!(
        reports
            .iter()
            .any(|report| report.hits * 100 / report.cases >= 80),
        "三种方案的中文 Top-8 命中率都低于 80%，按 4.3 需回退到 LIKE + 结构化过滤"
    );
}

/// FTS5 是整套方案的前提：不可用就没有讨论其余三种方案的余地。
async fn assert_fts5_available() {
    let pool = mem_pool().await;
    let enabled: i64 = sqlx::query_scalar("SELECT sqlite_compileoption_used('ENABLE_FTS5')")
        .fetch_one(&pool)
        .await
        .expect("查询编译选项失败");
    assert_eq!(enabled, 1, "SQLite 未编译进 FTS5，4.3 的方案全部不可用");
}

async fn mem_pool() -> SqlitePool {
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("打开内存库失败")
}

fn load_fixture() -> (Vec<Seed>, Vec<Case>) {
    let mut seeds = Vec::new();
    let mut cases = Vec::new();

    for (index, line) in FIXTURE.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let value: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|err| panic!("第 {} 行不是合法 JSON：{err}", index + 1));

        match value["type"].as_str() {
            Some("memory") => seeds.push(Seed {
                id: value["id"].as_str().expect("memory 缺 id").to_string(),
                content: value["content"]
                    .as_str()
                    .expect("memory 缺 content")
                    .to_string(),
            }),
            Some("case") => cases.push(Case {
                query: value["query"].as_str().expect("case 缺 query").to_string(),
                expect: value["expect"]
                    .as_array()
                    .expect("case 缺 expect")
                    .iter()
                    .map(|id| id.as_str().expect("expect 项不是字符串").to_string())
                    .collect(),
                two_char: value["tags"]
                    .as_array()
                    .is_some_and(|tags| tags.iter().any(|tag| tag.as_str() == Some("two_char"))),
            }),
            other => panic!("未知的 fixture 行类型：{other:?}"),
        }
    }

    (seeds, cases)
}

async fn run_scheme(scheme: Scheme, seeds: &[Seed], cases: &[Case], dir: &Path) -> Report {
    let path = dir.join(format!("spike-{}.db", scheme.slug()));
    let pool = jarvis_service::db::connect(&path)
        .await
        .expect("打开数据库失败");

    sqlx::query("CREATE TABLE spike_memories (id TEXT PRIMARY KEY, content TEXT NOT NULL)")
        .execute(&pool)
        .await
        .expect("建基础表失败");

    let mut content_bytes = 0usize;
    for seed in seeds {
        content_bytes += seed.content.len();
        sqlx::query("INSERT INTO spike_memories (id, content) VALUES (?, ?)")
            .bind(&seed.id)
            .bind(&seed.content)
            .execute(&pool)
            .await
            .expect("写入种子记忆失败");
    }

    let base_bytes = db_bytes(&pool).await;

    sqlx::query(scheme.ddl())
        .execute(&pool)
        .await
        .expect("建 FTS5 虚表失败");

    for seed in seeds {
        sqlx::query("INSERT INTO spike_fts (id, body) VALUES (?, ?)")
            .bind(&seed.id)
            .bind(scheme.indexed_text(&seed.content))
            .execute(&pool)
            .await
            .expect("写入 FTS 索引失败");
    }

    checkpoint(&pool).await;
    let indexed_bytes = db_bytes(&pool).await;
    let index_bytes = indexed_bytes.saturating_sub(base_bytes);
    let index_ratio = index_bytes as f64 / content_bytes as f64;

    let mut hits = 0usize;
    let mut recall_sum = 0.0f64;
    let mut two_char_cases = 0usize;
    let mut two_char_hits = 0usize;
    let mut timings = Vec::with_capacity(cases.len() * REPS);
    let mut query_errors = 0usize;

    for case in cases {
        let expression = scheme.query(&case.query);
        let mut matched_best: Vec<String> = Vec::new();

        for _ in 0..REPS {
            let started = Instant::now();
            let result: Result<Vec<(String,)>, sqlx::Error> = sqlx::query_as(
                "SELECT id FROM spike_fts WHERE spike_fts MATCH ? ORDER BY bm25(spike_fts) LIMIT 8",
            )
            .bind(&expression)
            .fetch_all(&pool)
            .await;
            timings.push(started.elapsed().as_micros());

            match result {
                Ok(rows) => {
                    if matched_best.is_empty() {
                        matched_best = rows.into_iter().map(|(id,)| id).collect();
                    }
                }
                Err(err) => {
                    query_errors += 1;
                    eprintln!("  [{}] 查询失败 {:?}: {err}", scheme.name(), case.query);
                }
            }
        }

        let matched = matched_best
            .iter()
            .filter(|id| case.expect.contains(id))
            .count();
        if matched > 0 {
            hits += 1;
            if case.two_char {
                two_char_hits += 1;
            }
        }
        recall_sum += matched as f64 / case.expect.len() as f64;
        if case.two_char {
            two_char_cases += 1;
        }
    }

    pool.close().await;

    Report {
        scheme,
        cases: cases.len(),
        hits,
        recall: recall_sum / cases.len() as f64,
        two_char_cases,
        two_char_hits,
        p50_us: percentile(&mut timings, 50),
        p90_us: percentile(&mut timings, 90),
        index_ratio,
        index_bytes,
        bytes_per_row: index_bytes as f64 / seeds.len() as f64,
        query_errors,
    }
}

async fn checkpoint(pool: &SqlitePool) {
    // WAL 下新写入的页可能还留在 -wal 文件里，量体积前先落主库。
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(pool)
        .await
        .expect("checkpoint 失败");
}

async fn db_bytes(pool: &SqlitePool) -> u64 {
    let pages: i64 = sqlx::query_scalar("SELECT page_count FROM pragma_page_count()")
        .fetch_one(pool)
        .await
        .expect("读取 page_count 失败");
    let page_size: i64 = sqlx::query_scalar("SELECT page_size FROM pragma_page_size()")
        .fetch_one(pool)
        .await
        .expect("读取 page_size 失败");
    pages.max(0) as u64 * page_size.max(0) as u64
}

fn percentile(values: &mut [u128], p: usize) -> u128 {
    if values.is_empty() {
        return 0;
    }
    values.sort_unstable();
    let index = (values.len() * p / 100).min(values.len() - 1);
    values[index]
}

fn print_report(reports: &[Report]) {
    eprintln!();
    eprintln!("## MP-01 中文召回基线（合成语料：200 条种子 / 30 条查询，其中 10 条两字）");
    eprintln!();
    eprintln!("| 方案 | Top-8 命中 | 两字命中 | 平均召回 | P50 | P90 | 索引 | 索引/行 | 索引/正文 | 查询失败 |");
    eprintln!("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |");
    for report in reports {
        eprintln!(
            "| {} | {}/{} ({:.0}%) | {}/{} ({:.0}%) | {:.2} | {:.2}ms | {:.2}ms | {:.0}KB | {:.0}B | {:.2}× | {} |",
            report.scheme.name(),
            report.hits,
            report.cases,
            pct(report.hits, report.cases),
            report.two_char_hits,
            report.two_char_cases,
            pct(report.two_char_hits, report.two_char_cases),
            report.recall,
            report.p50_us as f64 / 1000.0,
            report.p90_us as f64 / 1000.0,
            report.index_bytes as f64 / 1024.0,
            report.bytes_per_row,
            report.index_ratio,
            report.query_errors,
        );
    }
    eprintln!();
    eprintln!("门槛：Top-8 ≥80% / 两字 ≥80% / P90 ≤50ms / 索引 ≤1.5×。");
    eprintln!("注意：语料是合成的，数字只用于方案间横向比较，不代表线上召回率。");
    eprintln!("短正文（约 19 字/条）下 FTS5 的每行固定开销占主导，`索引/正文` 会远大于 1.5，");
    eprintln!("判断 bigram 的放大倍数应看「同方案 vs A 的索引字节比」。");
}

fn pct(part: usize, total: usize) -> f64 {
    if total == 0 {
        0.0
    } else {
        part as f64 * 100.0 / total as f64
    }
}
