//! 统一时间源：全项目用 Unix 毫秒时间戳，避免 SQLite 日期字符串的解析差异。

use std::time::{SystemTime, UNIX_EPOCH};

/// 当前时间（Unix 毫秒）。
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        // 系统时间早于 1970 属于环境异常；退化为 0 而不是 panic，
        // 让上层依据 expires_at 判定过期。
        .unwrap_or(0)
}

/// 把 Unix 毫秒格式化成 `YYYY-MM-DD HH:MM:SS`（UTC）。
///
/// 不引日期库：引用标注只需要一个稳定的、可读的时间串，
/// 用 Howard Hinnant 的 civil-from-days 算法 20 行就够。
pub fn format_ms(ms: i64) -> String {
    let seconds = ms.div_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let remainder = seconds.rem_euclid(86_400);

    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
        remainder / 3_600,
        (remainder % 3_600) / 60,
        remainder % 60
    )
}

/// 把 Unix 毫秒格式化成 `YYYY-MM-DD`（UTC）。
///
/// 记忆摘要里"来源 · 时间"只到天：精确到秒对模型没有信息增量，只会多占预算。
pub fn format_date_ms(ms: i64) -> String {
    let days = ms.div_euclid(1000).div_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}")
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };

    (year + i64::from(month <= 2), month as u32, day as u32)
}

/// Unix 毫秒 → 当天的小时（0..24，**UTC**）。
///
/// 心跳的"凌晨整理"只需要一个稳定的钟点；项目里没有时区库，
/// 用 UTC 会与本地时间差几个小时，因此调用方传入的是已经加上本地偏移的时刻。
pub fn hour_of_day_ms(ms: i64) -> u32 {
    let seconds = ms.div_euclid(1000).rem_euclid(86_400);
    (seconds / 3_600) as u32
}

#[cfg(test)]
mod format_tests {
    use super::format_ms;

    #[test]
    fn formats_epoch() {
        assert_eq!(format_ms(0), "1970-01-01 00:00:00");
    }

    #[test]
    fn formats_known_timestamp() {
        // 2023-11-14T22:13:20Z
        assert_eq!(format_ms(1_700_000_000_000), "2023-11-14 22:13:20");
    }

    #[test]
    fn handles_leap_day() {
        // 2024-02-29T12:00:00Z
        assert_eq!(format_ms(1_709_208_000_000), "2024-02-29 12:00:00");
    }
}
