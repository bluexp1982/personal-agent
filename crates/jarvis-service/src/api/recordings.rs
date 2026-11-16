//! 录音笔记端点。
//!
//! 音频以 `application/octet-stream` / `audio/wav` 原样上传，不做 base64：
//! 30 秒 16k 单声道约 1MB，多一层编码只会让请求体大 33%。
//! 分片大小上限由 `recording.max_segment_bytes` 决定，路由层挂 `DefaultBodyLimit`。

use std::io::SeekFrom;

use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Extension, Json, Router};
use futures_util::stream::{self, StreamExt};
use protocol::{
    Recording, RecordingComplete, RecordingCreate, RecordingDetail, RecordingInfo, RecordingPage,
    RecordingSegment, RecordingStatus, RecordingSummaryGenerate, RecordingSummaryStyleUpdate,
    RecordingUpdate,
};
use serde::Deserialize;

use super::error::ApiRejection;
use super::ApiJson;
use crate::auth::AuthDevice;
use crate::recording::{self, wav, RecordingError};
use crate::state::AppState;

/// 录音路由。鉴权与请求体上限由 `api::router` 统一挂：
/// 只有这一簇端点放开到 32MB，其它 JSON 端点仍保持 axum 的默认上限。
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/recordings", get(list).post(create))
        // 静态段写在 `{id}` 前面：`/info` 不能被当成录音 id。
        .route("/api/recordings/info", get(info))
        .route(
            "/api/recordings/{id}",
            get(detail).patch(rename).delete(delete),
        )
        .route("/api/recordings/{id}/segments/{seq}", post(upload_segment))
        .route("/api/recordings/{id}/complete", post(complete))
        .route("/api/recordings/{id}/retry", post(retry))
        .route(
            "/api/recordings/{id}/summary",
            post(regenerate_summary).patch(update_summary_style),
        )
        .route(
            "/api/recordings/{id}/summary/audio",
            get(summary_audio).post(ensure_summary_audio),
        )
        .route(
            "/api/recordings/{id}/summary/audio/peaks",
            get(summary_audio_peaks),
        )
        .route("/api/recordings/{id}/audio", get(audio))
}

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub q: Option<String>,
    pub status: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct SegmentQuery {
    pub start_ms: i64,
    pub end_ms: i64,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<RecordingPage>, ApiRejection> {
    let status = match query.status.as_deref() {
        None | Some("") => None,
        Some(raw) => Some(RecordingStatus::parse(raw).ok_or_else(|| {
            ApiRejection::new(
                protocol::ErrorCode::InvalidRequest,
                "unknown recording status",
                "录音状态过滤值不支持",
            )
        })?),
    };

    let (items, next) = recording::list(
        &state.pool,
        query.q.as_deref(),
        status,
        query.cursor.as_deref(),
        query.limit.unwrap_or(30),
    )
    .await?;
    Ok(Json(RecordingPage::from_items(items, next)))
}

pub async fn create(
    State(state): State<AppState>,
    Extension(device): Extension<AuthDevice>,
    ApiJson(request): ApiJson<RecordingCreate>,
) -> Result<(StatusCode, Json<Recording>), ApiRejection> {
    let (recording, created) = recording::create(
        &state.pool,
        &device.device_id,
        &request,
        state.config.summary.default_style,
    )
    .await?;
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(recording)))
}

pub async fn info(State(state): State<AppState>) -> Result<Json<RecordingInfo>, ApiRejection> {
    Ok(Json(RecordingInfo {
        asr_enabled: state.config.asr.enabled,
        asr_available: state.transcription.available(),
        asr_model: state.transcription.model().map(str::to_string),
        max_segment_bytes: state.config.recording.max_segment_bytes,
        max_duration_ms: state.config.recording.max_duration_ms,
        max_total_bytes: state.config.recording.max_total_bytes,
        summary_available: state.summary.available(),
        summary_model: state.summary.model(),
        summary_default_style: state.config.summary.default_style,
        tts_enabled: state.config.tts.enabled,
        tts_available: state.summary_audio.available(),
        tts_model: state.summary_audio.model().map(str::to_string),
        tts_voice: state.summary_audio.voice().map(str::to_string),
    }))
}

pub async fn detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    let detail = recording::detail(&state.pool, &id)
        .await?
        .ok_or_else(not_found)?;
    Ok(Json(detail))
}

pub async fn rename(
    State(state): State<AppState>,
    Path(id): Path<String>,
    ApiJson(update): ApiJson<RecordingUpdate>,
) -> Result<Json<Recording>, ApiRejection> {
    Ok(Json(recording::rename(&state.pool, &id, &update).await?))
}

pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiRejection> {
    recording::delete(&state, &id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn upload_segment(
    State(state): State<AppState>,
    Path((id, seq)): Path<(String, u32)>,
    Query(query): Query<SegmentQuery>,
    body: Bytes,
) -> Result<(StatusCode, Json<RecordingSegment>), ApiRejection> {
    if body.is_empty() {
        return Err(ApiRejection::new(
            protocol::ErrorCode::InvalidAudio,
            "empty segment body",
            "音频内容为空",
        ));
    }

    let (segment, created) =
        recording::add_segment(&state, &id, seq, query.start_ms, query.end_ms, &body).await?;
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(segment)))
}

pub async fn complete(
    State(state): State<AppState>,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    let request = if body.is_empty() {
        RecordingComplete::default()
    } else {
        serde_json::from_slice::<RecordingComplete>(&body).map_err(|err| {
            ApiRejection::new(
                protocol::ErrorCode::InvalidRequest,
                format!("invalid complete body: {err}"),
                "结束录音的参数格式不正确",
            )
        })?
    };

    Ok(Json(
        recording::complete(&state, &id, request.duration_ms).await?,
    ))
}

pub async fn retry(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    Ok(Json(recording::retry(&state, &id).await?))
}

pub async fn regenerate_summary(
    State(state): State<AppState>,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<RecordingSummaryGenerate>,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    Ok(Json(
        recording::regenerate_summary(&state, &id, body.style).await?,
    ))
}

pub async fn update_summary_style(
    State(state): State<AppState>,
    Path(id): Path<String>,
    ApiJson(update): ApiJson<RecordingSummaryStyleUpdate>,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    Ok(Json(
        recording::update_summary_style(&state, &id, &update).await?,
    ))
}

pub async fn ensure_summary_audio(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<RecordingDetail>, ApiRejection> {
    Ok(Json(
        crate::recording::audio_jobs::ensure_audio(&state, &id).await?,
    ))
}

/// 下载总结语音。未合成好时返回统一错误体，客户端据此继续轮询。
pub async fn summary_audio(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiRejection> {
    let audio = crate::recording::audio_jobs::load_audio(&state, &id).await?;
    let bytes = audio.bytes;
    let format = audio.format;
    let content_type = match format.as_str() {
        "wav" => "audio/wav",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    };
    let file_name = format!("recording-summary-{}.{}", sanitize(&id), format);
    let disposition = HeaderValue::from_str(&format!("inline; filename=\"{file_name}\""))
        .unwrap_or_else(|_| HeaderValue::from_static("inline"));

    let length = bytes.len();
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_DISPOSITION, disposition)
        .header(header::CONTENT_LENGTH, length)
        .header("x-content-type-options", "nosniff")
        .body(Body::from(bytes))
        .map_err(|err| {
            tracing::error!(%err, recording_id = %id, "构造总结语音响应失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "summary audio response failed",
                "下载语音失败，请重试",
            )
        })
}

/// 总结语音的波形峰值。
///
/// 只在客户端真正要显示波形时调用一次：解码放在 `spawn_blocking` 里，
/// 不占 async 线程；结果不落盘也不落库，重生成语音后版本号变化，
/// 客户端自然重新拉取。
pub async fn summary_audio_peaks(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<protocol::SummaryAudioPeaks>, ApiRejection> {
    let audio = crate::recording::audio_jobs::load_audio(&state, &id).await?;
    let version = audio.updated_at;
    let format = audio.format;
    let bytes = audio.bytes;
    let byte_count = bytes.len();
    let hint = format.clone();
    let started = std::time::Instant::now();

    let decoded = tokio::task::spawn_blocking(move || {
        crate::recording::waveform::peaks(&bytes, &hint, crate::recording::waveform::PEAK_BUCKETS)
    })
    .await
    .map_err(|err| {
        tracing::warn!(recording_id = %id, %err, "总结语音峰值任务异常结束");
        ApiRejection::new(
            protocol::ErrorCode::InternalError,
            "summary audio peaks task failed",
            "语音波形暂时不可用，播放不受影响",
        )
    })?;

    let peaks = match decoded {
        Ok(peaks) => peaks,
        Err(reason) => {
            // 解码失败（例如 MockTts 写下的假字节）只降级：播放照旧，
            // 客户端退回进度条。
            tracing::warn!(
                recording_id = %id,
                format = %format,
                bytes = byte_count,
                %reason,
                "总结语音峰值解码失败"
            );
            return Err(ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "summary audio peaks unavailable",
                "语音波形暂时不可用，播放不受影响",
            ));
        }
    };

    tracing::debug!(
        recording_id = %id,
        format = %format,
        bytes = byte_count,
        elapsed_ms = started.elapsed().as_millis() as u64,
        buckets = peaks.len(),
        "总结语音峰值生成完成"
    );

    Ok(Json(protocol::SummaryAudioPeaks {
        version,
        buckets: peaks.len() as u32,
        peaks,
    }))
}

/// 下载整段归档音频：把分段 PCM 流式拼成一个标准 WAV。
///
/// 不把全部音频读进内存：先读每段 44 字节头算总长度，再逐个文件
/// 跳过头部、按 64KB 分块推进响应。1 小时的录音也不会撑爆服务端。
pub async fn audio(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiRejection> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    use tokio_util::io::ReaderStream;

    let (data_len, paths) = recording::audio_files(&state, &id).await?;
    let data_len = usize::try_from(data_len).map_err(|_| {
        ApiRejection::new(
            protocol::ErrorCode::PayloadTooLarge,
            "recording audio too large",
            "归档音频超过可下载上限",
        )
    })?;

    type ChunkStream =
        std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<Bytes, std::io::Error>> + Send>>;
    let header = wav::header(data_len);
    let mut streams: Vec<ChunkStream> = Vec::with_capacity(paths.len() + 1);
    streams.push(stream::once(async move { Ok::<_, std::io::Error>(Bytes::from(header)) }).boxed());

    for path in paths {
        let mut file = tokio::fs::File::open(&path).await.map_err(|err| {
            tracing::error!(%err, path = %path.display(), "打开录音分段失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "recording segment missing",
                "归档音频不完整，请查看服务日志",
            )
        })?;
        let mut segment_header = [0u8; 44];
        file.read_exact(&mut segment_header).await.map_err(|err| {
            tracing::error!(%err, path = %path.display(), "读取录音分段头失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "recording segment invalid",
                "归档音频不完整，请查看服务日志",
            )
        })?;
        let info = wav::parse_16k_mono(&segment_header).map_err(|reason| {
            ApiRejection::new(
                protocol::ErrorCode::InvalidAudio,
                format!("segment header invalid: {reason}"),
                "归档音频格式异常，请查看服务日志",
            )
        })?;
        file.seek(SeekFrom::Start(info.data_offset as u64))
            .await
            .map_err(|err| {
                tracing::error!(%err, path = %path.display(), "定位录音分段数据失败");
                ApiRejection::new(
                    protocol::ErrorCode::InternalError,
                    "recording segment seek failed",
                    "归档音频读取失败，请重试",
                )
            })?;
        streams.push(ReaderStream::new(file).boxed());
    }

    let file_name = format!("recording-{}{}", sanitize(&id), ".wav");
    let disposition = HeaderValue::from_str(&format!("attachment; filename=\"{file_name}\""))
        .unwrap_or_else(|_| HeaderValue::from_static("attachment"));

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "audio/wav")
        .header(header::CONTENT_DISPOSITION, disposition)
        .header(header::CONTENT_LENGTH, data_len + 44)
        .header("x-content-type-options", "nosniff")
        .body(Body::from_stream(stream::iter(streams).flatten()))
        .map_err(|err| {
            tracing::error!(%err, recording_id = %id, "构造录音下载响应失败");
            ApiRejection::new(
                protocol::ErrorCode::InternalError,
                "recording response failed",
                "下载失败，请重试",
            )
        })?;
    Ok(response)
}

fn not_found() -> ApiRejection {
    ApiRejection::from(RecordingError::NotFound)
}

fn sanitize(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "recording".to_string()
    } else {
        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize;

    #[test]
    fn sanitize_keeps_expected_ids() {
        assert_eq!(sanitize("rec_abc123"), "rec_abc123");
        assert_eq!(sanitize("a\"/../"), "a_____");
        assert_eq!(sanitize(""), "recording");
    }
}
