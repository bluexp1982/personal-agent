//! 结构化天气查询（Open-Meteo）。
//!
//! 为什么单独做工具而不是让模型自己拼 URL：
//! - 上游是固定两跳（geocoding → forecast），域名写死在代码里，没有 SSRF 面；
//! - 返回形状固定，产物里的"温度 / 降水概率"能被逐项核对；
//! - 来源与采集时间由工具记录，不由模型填写。
//!
//! 地理编码结果缓存 24 小时（城市不会天天搬家），天气本身不缓存——
//! "采集时间"必须是这次真的取回来的时间，否则来源卡片会骗人。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;

use super::{http, now_ms, ToolError, ToolOutput};

const GEOCODING_URL: &str = "https://geocoding-api.open-meteo.com/v1/search";
const FORECAST_URL: &str = "https://api.open-meteo.com/v1/forecast";

/// 地理编码缓存有效期。城市坐标几乎不变，24 小时足够稳妥。
const CACHE_TTL_MS: i64 = 24 * 60 * 60 * 1000;

/// 缓存条数上限：个人使用碰不到，纯粹防止被异常输入撑爆内存。
const CACHE_LIMIT: usize = 256;

#[derive(Debug, Clone)]
struct Place {
    name: String,
    latitude: f64,
    longitude: f64,
    cached_ms: i64,
}

#[derive(Debug, Default)]
pub(crate) struct Weather {
    cache: Mutex<HashMap<String, Place>>,
}

impl Weather {
    pub(crate) async fn lookup(
        &self,
        city: &str,
        days: u8,
        timeout: Duration,
    ) -> Result<ToolOutput, ToolError> {
        let city = city.trim();
        if city.is_empty() {
            return Err(ToolError::Denied("缺少城市名".to_string()));
        }

        let place = self.place(city, timeout).await?;
        let url = forecast_url(place.latitude, place.longitude, days.clamp(1, 7));
        let body = http::get_json(&url, timeout).await?;
        let summary = summarize(&place.name, &body)?;

        Ok(ToolOutput {
            size: summary.len() as i64,
            summary,
            source_url: Some(url),
            fetched_at: now_ms(),
        })
    }

    async fn place(&self, city: &str, timeout: Duration) -> Result<Place, ToolError> {
        let key = city.to_lowercase();
        if let Some(hit) = self.cached(&key) {
            return Ok(hit);
        }

        let body = http::get_json(&geocoding_url(city), timeout).await?;
        let place = parse_place(&body, city)?;
        self.remember(key, place.clone());
        Ok(place)
    }

    fn cached(&self, key: &str) -> Option<Place> {
        let now = now_ms();
        let cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        cache
            .get(key)
            .filter(|place| now - place.cached_ms < CACHE_TTL_MS)
            .cloned()
    }

    fn remember(&self, key: String, place: Place) {
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if cache.len() >= CACHE_LIMIT && !cache.contains_key(&key) {
            // 不做 LRU：满了就清空，个人场景下重新查一次比维护顺序更简单。
            cache.clear();
        }
        cache.insert(key, place);
    }
}

fn geocoding_url(city: &str) -> String {
    let mut url = reqwest::Url::parse(GEOCODING_URL).expect("固定地址合法");
    url.query_pairs_mut()
        .append_pair("name", city)
        .append_pair("count", "1")
        .append_pair("language", "zh")
        .append_pair("format", "json");
    url.to_string()
}

fn forecast_url(latitude: f64, longitude: f64, days: u8) -> String {
    let mut url = reqwest::Url::parse(FORECAST_URL).expect("固定地址合法");
    url.query_pairs_mut()
        .append_pair("latitude", &format!("{latitude}"))
        .append_pair("longitude", &format!("{longitude}"))
        .append_pair(
            "daily",
            "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
        )
        .append_pair("timezone", "auto")
        .append_pair("forecast_days", &days.to_string());
    url.to_string()
}

fn parse_place(body: &Value, city: &str) -> Result<Place, ToolError> {
    let first = body
        .get("results")
        .and_then(Value::as_array)
        .and_then(|results| results.first())
        .ok_or_else(|| ToolError::Failed(format!("找不到城市：{city}")))?;

    let latitude = first
        .get("latitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| ToolError::Failed("地理编码缺少 latitude".to_string()))?;
    let longitude = first
        .get("longitude")
        .and_then(Value::as_f64)
        .ok_or_else(|| ToolError::Failed("地理编码缺少 longitude".to_string()))?;
    let name = first
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or(city)
        .to_string();

    Ok(Place {
        name,
        latitude,
        longitude,
        cached_ms: now_ms(),
    })
}

/// 把 forecast 响应压成几行人类可读文本。
fn summarize(city: &str, body: &Value) -> Result<String, ToolError> {
    let daily = body
        .get("daily")
        .ok_or_else(|| ToolError::Failed("天气响应缺少 daily".to_string()))?;

    let dates = daily
        .get("time")
        .and_then(Value::as_array)
        .ok_or_else(|| ToolError::Failed("天气响应缺少 time".to_string()))?;

    if dates.is_empty() {
        return Err(ToolError::Failed("天气响应没有可用日期".to_string()));
    }

    let mut lines = vec![format!("{city} 天气预报：")];
    for (index, date) in dates.iter().enumerate() {
        let Some(date) = date.as_str() else {
            continue;
        };

        let code = array_i64(daily, "weather_code", index).unwrap_or(-1);
        let high = array_f64(daily, "temperature_2m_max", index);
        let low = array_f64(daily, "temperature_2m_min", index);
        let rain = array_i64(daily, "precipitation_probability_max", index);

        let temperature = match (low, high) {
            (Some(low), Some(high)) => format!("{low:.0}~{high:.0}°C"),
            _ => "温度未获取".to_string(),
        };
        let rain = rain
            .map(|value| format!("降水概率 {value}%"))
            .unwrap_or_else(|| "降水概率未获取".to_string());

        lines.push(format!(
            "{date}：{}，{temperature}，{rain}",
            weather_label(code)
        ));
    }

    Ok(lines.join("\n"))
}

fn array_i64(daily: &Value, key: &str, index: usize) -> Option<i64> {
    daily
        .get(key)
        .and_then(Value::as_array)
        .and_then(|items| items.get(index))
        .and_then(Value::as_i64)
}

fn array_f64(daily: &Value, key: &str, index: usize) -> Option<f64> {
    daily
        .get(key)
        .and_then(Value::as_array)
        .and_then(|items| items.get(index))
        .and_then(Value::as_f64)
}

/// WMO 天气代码 → 中文。未知代码不猜含义，明确写"未识别"。
fn weather_label(code: i64) -> &'static str {
    match code {
        0 => "晴",
        1 => "基本晴",
        2 => "局部多云",
        3 => "阴",
        45 => "雾",
        48 => "雾凇",
        51 => "弱毛毛雨",
        53 => "毛毛雨",
        55 => "强毛毛雨",
        56 | 57 => "冻毛毛雨",
        61 => "小雨",
        63 => "中雨",
        65 => "大雨",
        66 | 67 => "冻雨",
        71 => "小雪",
        73 => "中雪",
        75 => "大雪",
        77 => "雪粒",
        80 => "小阵雨",
        81 => "阵雨",
        82 => "强阵雨",
        85 => "小阵雪",
        86 => "强阵雪",
        95 => "雷雨",
        96 | 99 => "雷雨伴冰雹",
        _ => "天气代码未识别",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        serde_json::json!({
            "daily": {
                "time": ["2026-10-28", "2026-10-29"],
                "weather_code": [2, 61],
                "temperature_2m_max": [24.4, 21.6],
                "temperature_2m_min": [17.5, 15.2],
                "precipitation_probability_max": [10, null]
            }
        })
    }

    #[test]
    fn known_codes_have_labels_and_unknown_is_explicit() {
        assert_eq!(weather_label(0), "晴");
        assert_eq!(weather_label(61), "小雨");
        assert_eq!(weather_label(99), "雷雨伴冰雹");
        assert_eq!(weather_label(1234), "天气代码未识别");
    }

    #[test]
    fn parses_geocoding_result() {
        let body = serde_json::json!({
            "results": [{ "name": "上海", "latitude": 31.22, "longitude": 121.46 }]
        });
        let place = parse_place(&body, "上海").expect("应解析成功");
        assert_eq!(place.name, "上海");
        assert!((place.latitude - 31.22).abs() < 1e-9);
    }

    #[test]
    fn missing_city_is_reported_not_fabricated() {
        let error = parse_place(&serde_json::json!({ "results": [] }), "不存在市")
            .expect_err("空结果应报错");
        assert!(error.to_string().contains("找不到城市"));
    }

    #[test]
    fn summarizes_days_and_marks_missing_values() {
        let summary = summarize("上海", &fixture()).expect("应解析成功");
        assert!(summary.contains("上海 天气预报"));
        assert!(summary.contains("2026-10-28：局部多云，18~24°C，降水概率 10%"));
        // 降水概率为 null 时不能编一个 0%
        assert!(summary.contains("2026-10-29：小雨，15~22°C，降水概率未获取"));
    }

    #[test]
    fn missing_daily_is_an_error() {
        let error = summarize("上海", &serde_json::json!({})).expect_err("缺 daily 应报错");
        assert!(error.to_string().contains("daily"));
    }

    #[test]
    fn forecast_url_carries_coordinates_and_days() {
        let url = forecast_url(31.22, 121.46, 3);
        assert!(url.starts_with("https://api.open-meteo.com/v1/forecast?"));
        assert!(url.contains("forecast_days=3"));
        assert!(url.contains("latitude=31.22"));
    }
}
