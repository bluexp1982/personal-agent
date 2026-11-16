//! 录音笔记领域逻辑。
//!
//! 与「会话/任务」的软删不同，录音是**物理删除**：音频很占磁盘，
//! 留一份"看不见但还在"的归档没有意义。删除时元信息、分段记录与文件一起清掉。
//!
//! 状态机（聚合状态永远由分段推导，不靠调用方自觉）：
//! ```text
//! recording ──complete──▶ transcribing ──▶ ready / partial / failed
//!      ▲                        │
//!      └────── 追加分段 ─────────┘（complete 之后再传会重新进入 recording）
//! ```

pub mod asr;
pub mod audio_jobs;
pub mod job;
pub mod store;
pub mod summary;
pub mod tts;
pub mod wav;
pub mod waveform;

use protocol::{
    Cursor, Recording, RecordingCreate, RecordingDetail, RecordingMode, RecordingSegment,
    RecordingStatus, RecordingSummary, RecordingSummaryStyleUpdate, RecordingUpdate, SegmentState,
    SummaryAudioStatus, SummaryStatus, SummaryStyle,
};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use crate::clock::now_ms;
use crate::{ids, state::AppState};

use self::store::{RecordingStore, StoreError};

const MAX_TITLE_CHARS: usize = 200;
const MAX_CLIENT_ID_CHARS: usize = 128;
const PREVIEW_CHARS: usize = 80;
const MAX_SEQ: u32 = 999_999;

#[derive(Debug, thiserror::Error)]
pub enum RecordingError {
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error("录音不存在")]
    NotFound,
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    InvalidAudio(String),
    #[error("{0}")]
    TooLarge(String),
    #[error("{0}")]
    Quota(String),
    #[error("转写服务未就绪")]
    AsrUnavailable,
    #[error("总结服务未就绪")]
    SummaryUnavailable,
    #[error("{0}")]
    SummaryNotReady(String),
    #[error("语音合成服务未就绪")]
    TtsUnavailable,
    #[error("{0}")]
    SummaryAudioNotReady(String),
    #[error("音频存储失败: {0}")]
    Store(String),
}

type RecordingRow = (
    String,
    String,
    String,
    String,
    String,
    i64,
    i64,
    i64,
    i64,
    String,
    i64,
    i64,
);

type SegmentRow = (i64, i64, i64, i64, String, String, Option<String>);

fn recording_from_row(row: RecordingRow) -> Recording {
    let (
        id,
        client_recording_id,
        title,
        mode,
        status,
        duration_ms,
        bytes,
        segment_count,
        ready_count,
        text,
        created_at,
        updated_at,
    ) = row;
    Recording {
        id,
        client_recording_id,
        title,
        mode: RecordingMode::parse(&mode).unwrap_or(RecordingMode::Batch),
        status: RecordingStatus::parse(&status).unwrap_or(RecordingStatus::Recording),
        duration_ms,
        bytes,
        segment_count,
        ready_count,
        preview: preview_of(&text),
        created_at,
        updated_at,
    }
}

fn segment_from_row(row: SegmentRow) -> RecordingSegment {
    let (seq, start_ms, end_ms, bytes, text, state, error) = row;
    RecordingSegment {
        seq: u32::try_from(seq).unwrap_or(0),
        start_ms,
        end_ms,
        bytes,
        text,
        state: SegmentState::parse(&state).unwrap_or(SegmentState::Stored),
        error,
    }
}

/// 列表预览：压成一行并截断。完整文本只在详情里给。
fn preview_of(text: &str) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    one_line.chars().take(PREVIEW_CHARS).collect()
}

fn normalize_title(raw: Option<&str>) -> String {
    let title = raw.unwrap_or("").trim();
    if title.is_empty() {
        return "未命名录音".to_string();
    }
    title.chars().take(MAX_TITLE_CHARS).collect()
}

fn validate_title(raw: &str) -> Result<String, RecordingError> {
    let title: String = raw.trim().chars().take(MAX_TITLE_CHARS).collect();
    if title.is_empty() {
        return Err(RecordingError::Invalid("标题不能为空".to_string()));
    }
    Ok(title)
}

fn escape_like(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '\\' | '%' | '_' => {
                out.push('\\');
                out.push(ch);
            }
            _ => out.push(ch),
        }
    }
    out
}

const RECORDING_COLUMNS: &str = "id, client_recording_id, title, mode, status, duration_ms, \
                                 bytes, segment_count, ready_count, text, created_at, updated_at";

// sqlx 0.9 只接受 `&'static str`（动态拼接需要用 QueryBuilder 或显式审计），
// 所以两条按主键/客户端 id 查询单独写成常量，而不是 format! 拼列名。
const SELECT_BY_ID: &str = "SELECT id, client_recording_id, title, mode, status, duration_ms, \
     bytes, segment_count, ready_count, text, created_at, updated_at \
     FROM recordings WHERE id = ?";

const SELECT_BY_CLIENT_ID: &str = "SELECT id, client_recording_id, title, mode, status, \
     duration_ms, bytes, segment_count, ready_count, text, created_at, updated_at \
     FROM recordings WHERE client_recording_id = ?";

/// 新建录音（幂等）。返回 `(录音, 是否新建)`。
pub async fn create(
    pool: &SqlitePool,
    device_id: &str,
    request: &RecordingCreate,
    default_summary_style: SummaryStyle,
) -> Result<(Recording, bool), RecordingError> {
    let client_id = request.client_recording_id.trim();
    if client_id.is_empty() || client_id.chars().count() > MAX_CLIENT_ID_CHARS {
        return Err(RecordingError::Invalid(
            "client_recording_id 不能为空且不超过 128 字".to_string(),
        ));
    }

    let now = now_ms();
    let title = normalize_title(request.title.as_deref());
    let result = sqlx::query(
        "INSERT INTO recordings (id, client_recording_id, title, mode, status, duration_ms, \
         bytes, segment_count, ready_count, text, device_id, completed_at, \
         summary_style_preference, created_at, updated_at) \
         VALUES (?, ?, ?, ?, 'recording', 0, 0, 0, 0, '', ?, NULL, ?, ?, ?) \
         ON CONFLICT (client_recording_id) DO NOTHING",
    )
    .bind(ids::new_id("rec"))
    .bind(client_id)
    .bind(&title)
    .bind(request.mode.as_str())
    .bind(device_id)
    .bind(default_summary_style.as_str())
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    let recording = find_by_client_id(pool, client_id)
        .await?
        .ok_or_else(|| RecordingError::Store("幂等创建后仍读不到记录".to_string()))?;
    Ok((recording, result.rows_affected() > 0))
}

async fn find_by_client_id(
    pool: &SqlitePool,
    client_id: &str,
) -> Result<Option<Recording>, RecordingError> {
    let row = sqlx::query_as::<_, RecordingRow>(SELECT_BY_CLIENT_ID)
        .bind(client_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(recording_from_row))
}

/// 列表。`q` 同时匹配标题与转写稿，`status` 过滤聚合状态。
pub async fn list(
    pool: &SqlitePool,
    q: Option<&str>,
    status: Option<RecordingStatus>,
    cursor: Option<&str>,
    limit: u32,
) -> Result<(Vec<Recording>, Option<Cursor>), RecordingError> {
    let limit = limit.clamp(1, 100);
    let cursor = match cursor {
        Some(raw) => Some(
            Cursor::decode(raw)
                .ok_or_else(|| RecordingError::Invalid("cursor 无法解析".to_string()))?,
        ),
        None => None,
    };

    let mut builder = QueryBuilder::<Sqlite>::new(format!(
        "SELECT {RECORDING_COLUMNS} FROM recordings WHERE 1 = 1"
    ));
    if let Some(status) = status {
        builder.push(" AND status = ").push_bind(status.as_str());
    }
    if let Some(q) = q.map(str::trim).filter(|q| !q.is_empty()) {
        let like = format!(
            "%{}%",
            escape_like(&q.chars().take(100).collect::<String>())
        );
        builder
            .push(" AND (title LIKE ")
            .push_bind(like.clone())
            .push(" ESCAPE '\\' OR text LIKE ")
            .push_bind(like)
            .push(" ESCAPE '\\')");
    }
    if let Some(cursor) = &cursor {
        builder
            .push(" AND (updated_at < ")
            .push_bind(cursor.updated_at)
            .push(" OR (updated_at = ")
            .push_bind(cursor.updated_at)
            .push(" AND id < ")
            .push_bind(cursor.id.clone())
            .push("))");
    }
    builder
        .push(" ORDER BY updated_at DESC, id DESC LIMIT ")
        .push_bind(i64::from(limit) + 1);

    let rows = builder
        .build_query_as::<RecordingRow>()
        .fetch_all(pool)
        .await?;

    let mut items: Vec<Recording> = rows.into_iter().map(recording_from_row).collect();
    let has_more = items.len() > limit as usize;
    if has_more {
        items.truncate(limit as usize);
    }
    let next = if has_more {
        items
            .last()
            .map(|item| Cursor::new(item.updated_at, item.id.clone()))
    } else {
        None
    };
    Ok((items, next))
}

/// 详情。不存在返回 `None`。
pub async fn detail(
    pool: &SqlitePool,
    recording_id: &str,
) -> Result<Option<RecordingDetail>, RecordingError> {
    let Some(row) = sqlx::query_as::<_, RecordingRow>(SELECT_BY_ID)
        .bind(recording_id)
        .fetch_optional(pool)
        .await?
    else {
        return Ok(None);
    };

    let segments = sqlx::query_as::<_, SegmentRow>(
        "SELECT seq, start_ms, end_ms, bytes, text, state, error \
         FROM recording_segments WHERE recording_id = ? ORDER BY seq ASC",
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(segment_from_row)
    .collect();

    Ok(Some(RecordingDetail {
        recording: recording_from_row(row),
        segments,
        summary: load_summary(pool, recording_id).await?,
    }))
}

/// 读取总结与 TTS 状态。历史数据没有这些列值时按 none 处理。
async fn load_summary(
    pool: &SqlitePool,
    recording_id: &str,
) -> Result<RecordingSummary, RecordingError> {
    type SummaryRow = (
        String,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<String>,
        Option<i64>,
        String,
        Option<String>,
        i64,
        Option<String>,
        Option<i64>,
        i64,
    );
    let row = sqlx::query_as::<_, SummaryRow>(
        "SELECT summary, summary_style, summary_style_preference, summary_status, \
                summary_error, summary_model, summary_updated_at, \
                summary_audio_status, summary_audio_error, summary_audio_bytes, \
                summary_audio_format, summary_audio_updated_at, summary_audio_truncated \
         FROM recordings WHERE id = ?",
    )
    .bind(recording_id)
    .fetch_optional(pool)
    .await?;

    let Some((
        text,
        style,
        style_preference,
        status,
        error,
        model,
        updated_at,
        audio_status,
        audio_error,
        audio_bytes,
        audio_format,
        audio_updated_at,
        audio_truncated,
    )) = row
    else {
        return Ok(RecordingSummary::default());
    };

    let mut style = style.as_deref().and_then(SummaryStyle::parse);
    if style.is_none() && !text.trim().is_empty() {
        // 迁移前的历史总结都是会议纪要。
        style = Some(SummaryStyle::Minutes);
    }
    let style_preference = style_preference
        .as_deref()
        .and_then(SummaryStyle::parse)
        .unwrap_or(style.unwrap_or(SummaryStyle::Brief));

    Ok(RecordingSummary {
        status: SummaryStatus::parse(&status).unwrap_or(SummaryStatus::None),
        text,
        style,
        style_preference,
        error,
        model,
        updated_at,
        audio_status: SummaryAudioStatus::parse(&audio_status).unwrap_or(SummaryAudioStatus::None),
        audio_error,
        audio_bytes,
        audio_format,
        audio_updated_at,
        audio_truncated: audio_truncated != 0,
    })
}

/// 重命名。
pub async fn rename(
    pool: &SqlitePool,
    recording_id: &str,
    update: &RecordingUpdate,
) -> Result<Recording, RecordingError> {
    let title = validate_title(&update.title)?;
    let affected = sqlx::query("UPDATE recordings SET title = ?, updated_at = ? WHERE id = ?")
        .bind(&title)
        .bind(now_ms())
        .bind(recording_id)
        .execute(pool)
        .await?
        .rows_affected();
    if affected == 0 {
        return Err(RecordingError::NotFound);
    }
    detail(pool, recording_id)
        .await?
        .map(|detail| detail.recording)
        .ok_or(RecordingError::NotFound)
}

/// 删除录音：先删记录（级联分段），再尽力删目录。
///
/// 文件删除失败只告警不失败：记录已经没了，再让请求 500 只会让客户端反复重试，
/// 而这堆文件也只能靠人工清理。
pub async fn delete(state: &AppState, recording_id: &str) -> Result<(), RecordingError> {
    let affected = sqlx::query("DELETE FROM recordings WHERE id = ?")
        .bind(recording_id)
        .execute(&state.pool)
        .await?
        .rows_affected();
    if affected == 0 {
        return Err(RecordingError::NotFound);
    }

    let store = RecordingStore::new(state.config.recordings_dir());
    if let Err(err) = store.remove_recording(recording_id).await {
        tracing::warn!(%err, recording_id, "录音记录已删除，但清理音频目录失败");
    }
    Ok(())
}

/// 上传一个分段。
///
/// `created=false` 表示幂等命中：音频与转写都不重做，直接返回已有分段。
pub async fn add_segment(
    state: &AppState,
    recording_id: &str,
    seq: u32,
    start_ms: i64,
    end_ms: i64,
    bytes: &[u8],
) -> Result<(RecordingSegment, bool), RecordingError> {
    if seq > MAX_SEQ {
        return Err(RecordingError::Invalid(format!(
            "seq 超出范围（最大 {MAX_SEQ}）"
        )));
    }
    if start_ms < 0 || end_ms <= start_ms {
        return Err(RecordingError::Invalid(
            "需要 0 <= start_ms < end_ms".to_string(),
        ));
    }

    let info = wav::parse_16k_mono(bytes).map_err(RecordingError::InvalidAudio)?;
    let duration = info.duration_ms();
    // 客户端给的是录音内偏移；与音频实际时长差太多，说明参数或分段错位。
    if (duration - (end_ms - start_ms)).abs() > 1_500 {
        return Err(RecordingError::InvalidAudio(format!(
            "声明时长 {}ms 与音频实际 {}ms 相差过大",
            end_ms - start_ms,
            duration
        )));
    }

    let quota = &state.config.recording;
    if bytes.len() as i64 > quota.max_segment_bytes {
        return Err(RecordingError::TooLarge(format!(
            "分段 {} 字节超过上限 {}",
            bytes.len(),
            quota.max_segment_bytes
        )));
    }
    if end_ms > quota.max_duration_ms {
        return Err(RecordingError::Quota(format!(
            "录音时长超过上限 {} 分钟",
            quota.max_duration_ms / 60_000
        )));
    }

    let existing = load_segment(&state.pool, recording_id, seq).await?;
    if let Some(segment) = existing {
        return Ok((segment, false));
    }

    // 先确认录音存在，避免为一个不存在的 id 写文件。
    let Some(recording) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };
    if recording.recording.bytes + bytes.len() as i64 > quota.max_total_bytes {
        return Err(RecordingError::Quota(format!(
            "录音音频总量超过上限 {} MB",
            quota.max_total_bytes / (1024 * 1024)
        )));
    }

    let store = RecordingStore::new(state.config.recordings_dir());
    let relative = store
        .write_segment(recording_id, seq, bytes)
        .await
        .map_err(|err| map_store_error(err, recording_id))?;

    let now = now_ms();
    let inserted = sqlx::query(
        "INSERT INTO recording_segments \
         (recording_id, seq, start_ms, end_ms, bytes, path, text, state, error, created_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?, '', 'stored', NULL, ?, ?) \
         ON CONFLICT (recording_id, seq) DO NOTHING",
    )
    .bind(recording_id)
    .bind(i64::from(seq))
    .bind(start_ms)
    .bind(end_ms)
    .bind(bytes.len() as i64)
    .bind(&relative)
    .bind(now)
    .bind(now)
    .execute(&state.pool)
    .await?
    .rows_affected();

    if inserted == 0 {
        // 并发重复上传：以先写入的为准。
        if let Some(segment) = load_segment(&state.pool, recording_id, seq).await? {
            return Ok((segment, false));
        }
    }

    sqlx::query(
        "UPDATE recordings SET \
           duration_ms = MAX(duration_ms, ?), \
           bytes = bytes + ?, \
           segment_count = segment_count + 1, \
           status = 'recording', \
           completed_at = NULL, \
           updated_at = ? \
         WHERE id = ?",
    )
    .bind(end_ms)
    .bind(bytes.len() as i64)
    .bind(now)
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    // 新分段意味着转写稿会变：旧总结与旧语音立即失效。
    if inserted > 0 {
        invalidate_summary(state, recording_id).await?;
    }

    // 实时模式：在这一请求内转写；失败只落分段状态，音频已经安全落盘。
    if recording.recording.mode == RecordingMode::Realtime && state.transcription.available() {
        if let Err(err) = state.transcription.transcribe_now(recording_id, seq).await {
            tracing::warn!(%err, recording_id, seq, "实时分段转写失败");
        }
    }

    refresh(&state.pool, recording_id).await?;
    let segment = load_segment(&state.pool, recording_id, seq)
        .await?
        .ok_or_else(|| RecordingError::Store("分段写入后读不到".to_string()))?;
    Ok((segment, true))
}

fn map_store_error(err: StoreError, recording_id: &str) -> RecordingError {
    match err {
        StoreError::Missing => RecordingError::Store(format!("{recording_id} 的音频文件缺失")),
        StoreError::InvalidPath(reason) => RecordingError::Store(format!("音频路径非法：{reason}")),
        StoreError::Io(reason) => RecordingError::Store(reason),
    }
}

async fn load_segment(
    pool: &SqlitePool,
    recording_id: &str,
    seq: u32,
) -> Result<Option<RecordingSegment>, RecordingError> {
    let row = sqlx::query_as::<_, SegmentRow>(
        "SELECT seq, start_ms, end_ms, bytes, text, state, error \
         FROM recording_segments WHERE recording_id = ? AND seq = ?",
    )
    .bind(recording_id)
    .bind(i64::from(seq))
    .fetch_optional(pool)
    .await?;
    Ok(row.map(segment_from_row))
}

/// 结束录音并触发转写。
pub async fn complete(
    state: &AppState,
    recording_id: &str,
    duration_ms: Option<i64>,
) -> Result<RecordingDetail, RecordingError> {
    let Some(existing) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };

    if existing.recording.duration_ms > state.config.recording.max_duration_ms {
        return Err(RecordingError::Quota("录音时长超过服务端上限".to_string()));
    }

    let duration = duration_ms
        .filter(|value| *value > 0)
        .map(|value| value.min(state.config.recording.max_duration_ms))
        .unwrap_or(existing.recording.duration_ms);

    sqlx::query(
        "UPDATE recordings SET completed_at = ?, duration_ms = MAX(duration_ms, ?), \
         status = 'transcribing', updated_at = ? WHERE id = ?",
    )
    .bind(now_ms())
    .bind(duration)
    .bind(now_ms())
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    refresh(&state.pool, recording_id).await?;
    state.transcription.enqueue(recording_id.to_string());

    detail(&state.pool, recording_id)
        .await?
        .ok_or(RecordingError::NotFound)
}

/// 清空总结与总结语音。转写内容变化、手动重生成前都要调用。
///
/// 这里先删音频文件再改数据库：文件删失败最多留下孤儿文件，
/// 反过来会出现"数据库说没有、磁盘上还能被下载"的窗口。
pub async fn invalidate_summary(
    state: &AppState,
    recording_id: &str,
) -> Result<(), RecordingError> {
    let old_path = sqlx::query_scalar::<_, Option<String>>(
        "SELECT summary_audio_path FROM recordings WHERE id = ?",
    )
    .bind(recording_id)
    .fetch_optional(&state.pool)
    .await?
    .flatten();

    if let Some(relative) = old_path {
        let store = RecordingStore::new(state.config.recordings_dir());
        if let Ok(path) = store.path_of(&relative) {
            let _ = tokio::fs::remove_file(path).await;
        }
    }

    sqlx::query(
        "UPDATE recordings SET summary = '', summary_style = NULL, summary_status = 'none', \
         summary_error = NULL, summary_model = NULL, summary_updated_at = NULL, \
         summary_audio_path = NULL, summary_audio_status = 'none', summary_audio_error = NULL, \
         summary_audio_bytes = 0, summary_audio_format = NULL, summary_audio_updated_at = NULL, \
         summary_audio_truncated = 0, updated_at = ? WHERE id = ?",
    )
    .bind(now_ms())
    .bind(recording_id)
    .execute(&state.pool)
    .await?;
    Ok(())
}

/// 只保存用户选中的总结形式，不触发模型调用。
pub async fn update_summary_style(
    state: &AppState,
    recording_id: &str,
    update: &RecordingSummaryStyleUpdate,
) -> Result<RecordingDetail, RecordingError> {
    if !state.summary.available() {
        return Err(RecordingError::SummaryUnavailable);
    }
    let Some(_) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };
    sqlx::query("UPDATE recordings SET summary_style_preference = ?, updated_at = ? WHERE id = ?")
        .bind(update.style.as_str())
        .bind(now_ms())
        .bind(recording_id)
        .execute(&state.pool)
        .await?;

    detail(&state.pool, recording_id)
        .await?
        .ok_or(RecordingError::NotFound)
}

/// 手动重新生成总结：清空旧总结与旧语音，置 pending 等后台任务。
pub async fn regenerate_summary(
    state: &AppState,
    recording_id: &str,
    style: Option<SummaryStyle>,
) -> Result<RecordingDetail, RecordingError> {
    if !state.summary.available() {
        return Err(RecordingError::SummaryUnavailable);
    }
    let Some(current) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };
    if current.recording.status != RecordingStatus::Ready
        || !current
            .segments
            .iter()
            .any(|segment| segment.state == SegmentState::Ready && !segment.text.trim().is_empty())
    {
        return Err(RecordingError::SummaryNotReady(
            "需要所有分段转写完成，且至少有一段文字".to_string(),
        ));
    }

    let style = style.unwrap_or(current.summary.style_preference);
    invalidate_summary(state, recording_id).await?;
    sqlx::query(
        "UPDATE recordings SET summary_status = 'pending', summary_style_preference = ?, \
         updated_at = ? WHERE id = ?",
    )
    .bind(style.as_str())
    .bind(now_ms())
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    detail(&state.pool, recording_id)
        .await?
        .ok_or(RecordingError::NotFound)
}

/// 重试失败/未转写的分段。已成功的不重转。
pub async fn retry(
    state: &AppState,
    recording_id: &str,
) -> Result<RecordingDetail, RecordingError> {
    if !state.transcription.available() {
        return Err(RecordingError::AsrUnavailable);
    }
    let Some(_) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };

    // 转写会变化：旧总结和旧语音都不能再展示。
    invalidate_summary(state, recording_id).await?;

    let now = now_ms();
    // `ready` 但文本为空是历史缺陷留下的"假成功"：重试时必须把它也拉回
    // 待转写，否则用户点一次重试仍然什么都看不到。
    sqlx::query(
        "UPDATE recording_segments SET state = 'stored', error = NULL, updated_at = ? \
         WHERE recording_id = ? \
           AND (state IN ('failed', 'stored') OR (state = 'ready' AND trim(text) = ''))",
    )
    .bind(now)
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    sqlx::query(
        "UPDATE recordings SET completed_at = COALESCE(completed_at, ?), \
         status = 'transcribing', updated_at = ? WHERE id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(recording_id)
    .execute(&state.pool)
    .await?;

    refresh(&state.pool, recording_id).await?;
    state.transcription.enqueue(recording_id.to_string());

    detail(&state.pool, recording_id)
        .await?
        .ok_or(RecordingError::NotFound)
}

/// 由分段推导聚合状态并刷新计数与整段文本。
pub async fn refresh(pool: &SqlitePool, recording_id: &str) -> Result<(), RecordingError> {
    // 两层 Option：外层表示记录是否存在，内层表示是否已经 complete。
    let Some(completed_at) =
        sqlx::query_scalar::<_, Option<i64>>("SELECT completed_at FROM recordings WHERE id = ?")
            .bind(recording_id)
            .fetch_optional(pool)
            .await?
    else {
        return Ok(());
    };

    let counts = sqlx::query_as::<_, (i64, i64, i64, i64)>(
        "SELECT \
           COALESCE(SUM(CASE WHEN state = 'ready' THEN 1 ELSE 0 END), 0), \
           COALESCE(SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END), 0), \
           COALESCE(SUM(CASE WHEN state = 'transcribing' THEN 1 ELSE 0 END), 0), \
           COUNT(*) \
         FROM recording_segments WHERE recording_id = ?",
    )
    .bind(recording_id)
    .fetch_one(pool)
    .await?;
    let (ready, failed, transcribing, total) = counts;

    let status = if completed_at.is_none() {
        // 还在录：即使实时分段已经有文本，聚合状态也保持 recording，
        // 客户端据此显示"录音中"而不是"已完成"。
        RecordingStatus::Recording
    } else if transcribing > 0 {
        RecordingStatus::Transcribing
    } else if failed > 0 && ready > 0 {
        RecordingStatus::Partial
    } else if failed > 0 {
        RecordingStatus::Failed
    } else if total == 0 || ready == total {
        RecordingStatus::Ready
    } else {
        RecordingStatus::Recorded
    };

    let text = sqlx::query_scalar::<_, String>(
        "SELECT text FROM recording_segments \
         WHERE recording_id = ? AND state = 'ready' AND text <> '' ORDER BY seq ASC",
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?
    .join("\n");

    sqlx::query(
        "UPDATE recordings SET status = ?, ready_count = ?, text = ?, updated_at = ? WHERE id = ?",
    )
    .bind(status.as_str())
    .bind(ready)
    .bind(&text)
    .bind(now_ms())
    .bind(recording_id)
    .execute(pool)
    .await?;

    // 全部转写完成且录音已结束：自动排队生成总结。
    // 只认 none：failed 等用户手动重试，避免反复烧模型额度。
    if status == RecordingStatus::Ready && total > 0 {
        sqlx::query(
            "UPDATE recordings SET summary_status = 'pending', updated_at = ? \
             WHERE id = ? AND summary_status = 'none'",
        )
        .bind(now_ms())
        .bind(recording_id)
        .execute(pool)
        .await?;
    }
    Ok(())
}

/// 取一个待转写的分段序号，并把它标记为 `transcribing`。
///
/// 条件更新保证同一段不会被两条路径同时领走（实时上传与后台任务可能并发）。
pub async fn claim_next(
    pool: &SqlitePool,
    recording_id: &str,
) -> Result<Option<(u32, String)>, RecordingError> {
    let candidates = sqlx::query_as::<_, (i64, String)>(
        "SELECT seq, path FROM recording_segments \
         WHERE recording_id = ? AND state = 'stored' ORDER BY seq ASC LIMIT 4",
    )
    .bind(recording_id)
    .fetch_all(pool)
    .await?;

    for (seq, path) in candidates {
        let affected = sqlx::query(
            "UPDATE recording_segments SET state = 'transcribing', updated_at = ? \
             WHERE recording_id = ? AND seq = ? AND state = 'stored'",
        )
        .bind(now_ms())
        .bind(recording_id)
        .bind(seq)
        .execute(pool)
        .await?
        .rows_affected();
        if affected > 0 {
            return Ok(Some((u32::try_from(seq).unwrap_or(0), path)));
        }
    }
    Ok(None)
}

pub async fn set_segment_text(
    pool: &SqlitePool,
    recording_id: &str,
    seq: u32,
    text: &str,
) -> Result<(), RecordingError> {
    sqlx::query(
        "UPDATE recording_segments SET state = 'ready', text = ?, error = NULL, \
         updated_at = ? WHERE recording_id = ? AND seq = ?",
    )
    .bind(text)
    .bind(now_ms())
    .bind(recording_id)
    .bind(i64::from(seq))
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn set_segment_failed(
    pool: &SqlitePool,
    recording_id: &str,
    seq: u32,
    error: &str,
) -> Result<(), RecordingError> {
    sqlx::query(
        "UPDATE recording_segments SET state = 'failed', error = ?, updated_at = ? \
         WHERE recording_id = ? AND seq = ?",
    )
    .bind(error)
    .bind(now_ms())
    .bind(recording_id)
    .bind(i64::from(seq))
    .execute(pool)
    .await?;
    Ok(())
}

/// 转写服务整体不可用时，把还没转的段一起标记为失败，避免详情里永远显示"转写中"。
pub async fn fail_pending(
    pool: &SqlitePool,
    recording_id: &str,
    error: &str,
) -> Result<(), RecordingError> {
    sqlx::query(
        "UPDATE recording_segments SET state = 'failed', error = ?, updated_at = ? \
         WHERE recording_id = ? AND state = 'stored'",
    )
    .bind(error)
    .bind(now_ms())
    .bind(recording_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// 归档下载前的校验：返回「PCM 总字节数 + 按 seq 排好的文件路径」。
///
/// 只读每个文件的前 44 字节算总长度，调用方据此流式拼响应；
/// 若一次性读全部音频，1 小时的 460MB 会直接进内存。
pub async fn audio_files(
    state: &AppState,
    recording_id: &str,
) -> Result<(u64, Vec<std::path::PathBuf>), RecordingError> {
    use tokio::io::AsyncReadExt;

    let Some(meta) = detail(&state.pool, recording_id).await? else {
        return Err(RecordingError::NotFound);
    };
    let rows = sqlx::query_as::<_, (i64, String)>(
        "SELECT seq, path FROM recording_segments WHERE recording_id = ? ORDER BY seq ASC",
    )
    .bind(recording_id)
    .fetch_all(&state.pool)
    .await?;
    if rows.is_empty() {
        return Err(RecordingError::Invalid("这条录音还没有音频".to_string()));
    }

    if meta.recording.bytes > state.config.recording.max_total_bytes {
        return Err(RecordingError::TooLarge(
            "归档音频超过服务端允许的单次下载大小".to_string(),
        ));
    }

    let store = RecordingStore::new(state.config.recordings_dir());
    let mut total = 0u64;
    let mut paths = Vec::with_capacity(rows.len());
    for (_, relative) in rows {
        let path = store
            .path_of(&relative)
            .map_err(|err| map_store_error(err, recording_id))?;
        let mut file = tokio::fs::File::open(&path)
            .await
            .map_err(|err| RecordingError::Store(format!("打开分段失败：{err}")))?;
        let mut header = vec![0u8; 44];
        file.read_exact(&mut header)
            .await
            .map_err(|err| RecordingError::Store(format!("读取分段头失败：{err}")))?;
        let data_len = wav::declared_data_len(&header).map_err(RecordingError::InvalidAudio)?;
        total = total.saturating_add(data_len as u64);
        paths.push(path);
    }
    Ok((total, paths))
}
