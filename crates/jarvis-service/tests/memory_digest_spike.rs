//! MP-02：digest 预算实测（手动跑，不进常规回归）。
//!
//! ```text
//! cargo test -p jarvis-service --test memory_digest_spike -- --ignored --nocapture
//! ```
//!
//! 口径说明（与开发方案 10.1 的差异）：原 MP-02 要测"三档字数 × 20 轮的首 token
//! 时间"，那需要真实模型调用。本轮约定为**零模型费用**，因此这里只测方案自己能
//! 控制的那一半：**分区选择 + 渲染的耗时与产出长度**。生成侧的首 token 增量按
//! 注入字数推算，不在这里实测（结论表会写明）。
//!
//! 目标：单次 build <10ms（摘要必须在 `spawn` 之前同步完成，否则拖首字）。

use std::time::Instant;

use jarvis_service::memory::digest::{
    self, DigestContext, DigestEntry, DigestKind, DigestMode, DigestSource,
};

/// 每档重复次数。
const REPS: usize = 200;

const DAY: i64 = 86_400_000;
const NOW: i64 = 1_700_000_000_000;

#[derive(Debug)]
struct Row {
    total: usize,
    p50_us: f64,
    p90_us: f64,
    chars: usize,
    items: usize,
    truncated: bool,
    pinned_overflow: bool,
    per_item_chars: f64,
}

#[test]
#[ignore = "MP-02 digest 预算实测：手动跑，需要 --nocapture 看结论表"]
fn digest_budget_spike() {
    let entries = synthetic_entries(300);
    let mut rows = Vec::new();

    for total in [800usize, 1200, 2000] {
        rows.push(measure(&entries, total));
    }

    eprintln!();
    eprintln!("## MP-02 digest 分区选择 + 渲染（300 条候选，每档 {REPS} 次）");
    eprintln!();
    eprintln!("| budget_chars | P50 | P90 | 实际字数 | 条目数 | 每条均摊 | 截断 | 置顶溢出 |");
    eprintln!("| --- | --- | --- | --- | --- | --- | --- | --- |");
    for row in &rows {
        eprintln!(
            "| {} | {:.3}ms | {:.3}ms | {} | {} | {:.1} 字 | {} | {} |",
            row.total,
            row.p50_us / 1000.0,
            row.p90_us / 1000.0,
            row.chars,
            row.items,
            row.per_item_chars,
            if row.truncated { "是" } else { "否" },
            if row.pinned_overflow { "是" } else { "否" },
        );
    }
    eprintln!();
    eprintln!("目标：单次 build <10ms（spawn 之前同步完成，不拖首字）。");
    eprintln!("注意：只测选择与渲染；DB 查询耗时在 MP-09 落地后补测回填。");

    for row in &rows {
        assert!(
            row.p90_us < 10_000.0,
            "budget={} 的 P90 为 {:.3}ms，超过 10ms 目标",
            row.total,
            row.p90_us / 1000.0
        );
        assert!(row.chars <= row.total, "渲染结果超过了总预算");
    }
}

fn measure(entries: &[DigestEntry], total: usize) -> Row {
    let budget = digest::DigestBudget::scaled(total);
    let ctx = DigestContext::at(Some(DigestMode::Work), Some("ws_demo".to_string()), NOW);

    let mut timings = Vec::with_capacity(REPS);
    let mut last = None;
    for _ in 0..REPS {
        let started = Instant::now();
        let result = digest::select(entries, &budget, &ctx);
        timings.push(started.elapsed().as_micros() as f64);
        last = Some(result);
    }

    timings.sort_by(f64::total_cmp);
    let p50 = timings[timings.len() / 2];
    let p90 = timings[(timings.len() * 9 / 10).min(timings.len() - 1)];

    match last.expect("至少跑一次") {
        Ok(digest) => Row {
            total,
            p50_us: p50,
            p90_us: p90,
            chars: digest.chars,
            items: digest.memory_ids.len(),
            truncated: digest.truncated,
            pinned_overflow: false,
            per_item_chars: digest.chars as f64 / digest.memory_ids.len().max(1) as f64,
        },
        Err(err) => {
            eprintln!("budget={total} 选择失败：{err}");
            Row {
                total,
                p50_us: p50,
                p90_us: p90,
                chars: 0,
                items: 0,
                truncated: false,
                pinned_overflow: true,
                per_item_chars: 0.0,
            }
        }
    }
}

/// 300 条候选：60 画像 / 100 偏好 / 80 事件 / 60 项目，其中 6 条置顶。
fn synthetic_entries(count: usize) -> Vec<DigestEntry> {
    let mut entries = Vec::with_capacity(count);
    for index in 0..count {
        let kind = match index % 10 {
            0..=1 => DigestKind::Profile,
            2..=5 => DigestKind::Preference,
            6..=7 => DigestKind::Event,
            _ => DigestKind::Project,
        };
        let content = format!(
            "{}{}这条记忆用来说明一个具体事实并带上足够长度以便触发预算",
            kind_label(kind),
            index
        );
        entries.push(DigestEntry {
            id: format!("mem_{index:04}"),
            kind,
            content,
            source: match index % 4 {
                0 => DigestSource::Explicit,
                1 => DigestSource::Session,
                2 => DigestSource::Recording,
                _ => DigestSource::Task,
            },
            // 事件与近期项集中在最近 30 天内，其余分散到更早。
            at: NOW - (index as i64 % 40) * DAY,
            pinned: index % 50 == 0,
            importance: 0.3 + (index % 7) as f32 * 0.1,
            project_id: match kind {
                DigestKind::Project => Some("ws_demo".to_string()),
                _ => None,
            },
            private: index % 23 == 0,
        });
    }
    entries
}

fn kind_label(kind: DigestKind) -> &'static str {
    match kind {
        DigestKind::Profile => "画像",
        DigestKind::Preference => "偏好",
        DigestKind::Event => "事件",
        DigestKind::Project => "项目",
    }
}
