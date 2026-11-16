//! 录音端点集成测试。
//!
//! 用 `asr.provider = "mock"`：不访问网络，但仍然走完整的「上传 → 落盘 →
//! 转写 → 聚合状态」链路。真实厂商接口的验证是另一件事（见开发方案 P1）。

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, setup_with, wait_limit_ms, TestContext};
use serde_json::{json, Value};
use std::sync::Arc;
use jarvis_service::config::{AsrConfig, RecordingConfig};
use jarvis_service::model::{Completion, CompletionFuture, CompletionModel};
use jarvis_service::recording::audio_jobs::SummaryAudioJobs;
use jarvis_service::recording::summary::SummaryJobs;
use jarvis_service::recording::tts::MockTts;

#[derive(Debug)]
struct FakeSummaryModel;

impl CompletionModel for FakeSummaryModel {
    fn complete(
        &self,
        _system: &str,
        _prompt: &str,
        _max_tokens: Option<u32>,
    ) -> CompletionFuture<'_> {
        Box::pin(async {
            Ok(Completion {
                text: "## 概要\n测试录音的自动总结。\n## 关键要点\n- 测试要点\n## 待办 / 结论\n未提及明确待办。".to_string(),
                completion_tokens: 24,
                ..Completion::default()
            })
        })
    }
}

fn test_wav(duration_ms: usize) -> Vec<u8> {
    let data_len = duration_ms * 32; // 16kHz * 2 bytes
    let mut bytes = jarvis_service::recording::wav::header(data_len);
    bytes.extend(std::iter::repeat_n(0u8, data_len));
    bytes
}

fn binary_post(uri: &str, token: &str, bytes: Vec<u8>) -> Request<Body> {
    Request::post(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "audio/wav")
        .body(Body::from(bytes))
        .expect("构造请求失败")
}

async fn with_asr() -> TestContext {
    setup_with(|config| {
        config.asr = AsrConfig {
            enabled: true,
            provider: "mock".to_string(),
            model: "mock-asr".to_string(),
            ..AsrConfig::default()
        };
    })
    .await
}

async fn create_recording(ctx: &TestContext, token: &str, mode: &str, client_id: &str) -> Value {
    let response = ctx
        .post_json(
            "/api/recordings",
            token,
            &json!({ "client_recording_id": client_id, "mode": mode, "title": "测试录音" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::CREATED, "创建录音失败");
    body_json(response).await
}

async fn wait_status(ctx: &TestContext, token: &str, id: &str, expected: &str) -> Value {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(wait_limit_ms());
    let mut last = Value::Null;
    while std::time::Instant::now() < deadline {
        let response = ctx.get_json(&format!("/api/recordings/{id}"), token).await;
        if response.status() == StatusCode::OK {
            last = body_json(response).await;
            if last["recording"]["status"] == expected {
                return last;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!(
        "录音未在 {}ms 内进入 {expected}，最后一次：{last}",
        wait_limit_ms()
    );
}

#[tokio::test]
async fn batch_upload_then_complete_transcribes() {
    let ctx = with_asr().await;
    let (_, token) = ctx.pair_and_login("rec-batch").await;

    let created = create_recording(&ctx, &token, "batch", "local-batch-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();
    assert_eq!(created["status"], "recording");

    // 幂等：同一 client_recording_id 再提交返回同一个 id，且是 200。
    let again = ctx
        .post_json(
            "/api/recordings",
            &token,
            &json!({ "client_recording_id": "local-batch-1", "mode": "batch" }),
        )
        .await;
    assert_eq!(again.status(), StatusCode::OK);
    assert_eq!(body_json(again).await["id"], id);

    for seq in 0..2 {
        let start = seq * 1000;
        let response = ctx
            .call(binary_post(
                &format!(
                    "/api/recordings/{id}/segments/{seq}?start_ms={start}&end_ms={}",
                    start + 1000
                ),
                &token,
                test_wav(1000),
            ))
            .await;
        assert_eq!(response.status(), StatusCode::CREATED, "上传分段失败");
        let segment = body_json(response).await;
        assert_eq!(segment["state"], "stored", "批量模式上传时不该转写");
    }

    // 重复上传同一段是幂等命中：返回已有分段，不重复计数。
    let duplicate = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=1000"),
            &token,
            test_wav(1000),
        ))
        .await;
    assert_eq!(duplicate.status(), StatusCode::OK);

    let detail = ctx.get_json(&format!("/api/recordings/{id}"), &token).await;
    let detail = body_json(detail).await;
    assert_eq!(detail["recording"]["segment_count"], 2);
    assert_eq!(detail["segments"].as_array().expect("segments").len(), 2);

    let complete = ctx
        .post_json(
            &format!("/api/recordings/{id}/complete"),
            &token,
            &json!({ "duration_ms": 2000 }),
        )
        .await;
    assert_eq!(complete.status(), StatusCode::OK, "complete 失败");

    let ready = wait_status(&ctx, &token, &id, "ready").await;
    assert_eq!(ready["recording"]["ready_count"], 2);
    assert!(
        ready["recording"]["preview"]
            .as_str()
            .unwrap_or("")
            .contains("语音片段"),
        "预览应包含转写文本：{ready}"
    );

    let list = ctx.get_json("/api/recordings?q=语音片段", &token).await;
    let list = body_json(list).await;
    assert_eq!(list["items"].as_array().expect("items").len(), 1);
}

#[tokio::test]
async fn realtime_upload_transcribes_inline() {
    let ctx = with_asr().await;
    let (_, token) = ctx.pair_and_login("rec-realtime").await;
    let created = create_recording(&ctx, &token, "realtime", "local-rt-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let response = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=1000"),
            &token,
            test_wav(1000),
        ))
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let segment = body_json(response).await;
    assert_eq!(segment["state"], "ready", "实时模式应立即出稿");
    assert!(segment["text"].as_str().unwrap_or("").contains("语音片段"));

    // 录音还没结束：聚合状态保持 recording，但文本已经可读。
    let detail = body_json(ctx.get_json(&format!("/api/recordings/{id}"), &token).await).await;
    assert_eq!(detail["recording"]["status"], "recording");
    assert!(!detail["recording"]["preview"]
        .as_str()
        .unwrap_or("")
        .is_empty());
}

#[tokio::test]
async fn invalid_audio_and_quota_are_explained() {
    let ctx = setup_with(|config| {
        config.asr = AsrConfig {
            enabled: false,
            ..AsrConfig::default()
        };
        config.recording = RecordingConfig {
            max_duration_ms: 1_500,
            ..RecordingConfig::default()
        };
    })
    .await;
    let (_, token) = ctx.pair_and_login("rec-invalid").await;
    let created = create_recording(&ctx, &token, "batch", "local-invalid-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let bad = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=1000"),
            &token,
            b"not a wav file".to_vec(),
        ))
        .await;
    assert_eq!(bad.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(bad).await["code"], "invalid_audio");

    let over_quota = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/1?start_ms=1000&end_ms=2000"),
            &token,
            test_wav(1000),
        ))
        .await;
    assert_eq!(over_quota.status(), StatusCode::CONFLICT);
    assert_eq!(
        body_json(over_quota).await["code"],
        "recording_quota_exceeded"
    );
}

#[tokio::test]
async fn retry_without_asr_reports_unavailable() {
    let ctx = setup_with(|config| {
        config.asr = AsrConfig {
            enabled: false,
            ..AsrConfig::default()
        };
    })
    .await;
    let (_, token) = ctx.pair_and_login("rec-noasr").await;

    let info = body_json(ctx.get_json("/api/recordings/info", &token).await).await;
    assert_eq!(info["asr_enabled"], false);
    assert_eq!(info["asr_available"], false);

    let created = create_recording(&ctx, &token, "batch", "local-noasr-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let retry = ctx
        .post_json(&format!("/api/recordings/{id}/retry"), &token, &json!({}))
        .await;
    assert_eq!(retry.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(retry).await["code"], "asr_unavailable");
}

#[tokio::test]
async fn delete_removes_record_and_audio_files() {
    let ctx = with_asr().await;
    let (_, token) = ctx.pair_and_login("rec-delete").await;
    let created = create_recording(&ctx, &token, "batch", "local-del-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let response = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=1000"),
            &token,
            test_wav(1000),
        ))
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);

    let dir = ctx.state.config.recordings_dir().join(&id);
    assert!(dir.exists(), "分段应已落盘");

    let deleted = ctx.delete(&format!("/api/recordings/{id}"), &token).await;
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    assert!(!dir.exists(), "删除录音后音频目录应被清理");

    let missing = ctx.get_json(&format!("/api/recordings/{id}"), &token).await;
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    assert_eq!(body_json(missing).await["code"], "recording_not_found");
}

#[tokio::test]
async fn archives_audio_as_one_wav() {
    let ctx = with_asr().await;
    let (_, token) = ctx.pair_and_login("rec-audio").await;
    let created = create_recording(&ctx, &token, "batch", "local-audio-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    for seq in 0..2 {
        let start = seq * 500;
        let response = ctx
            .call(binary_post(
                &format!(
                    "/api/recordings/{id}/segments/{seq}?start_ms={start}&end_ms={}",
                    start + 500
                ),
                &token,
                test_wav(500),
            ))
            .await;
        assert_eq!(response.status(), StatusCode::CREATED);
    }

    let response = ctx
        .get_json(&format!("/api/recordings/{id}/audio"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("读取音频失败");
    assert_eq!(&bytes[0..4], b"RIFF");
    let info =
        jarvis_service::recording::wav::parse_16k_mono(&bytes).expect("归档音频应是合法 WAV");
    assert_eq!(info.duration_ms(), 1000);
}

#[tokio::test]
async fn accepts_segments_larger_than_default_body_limit() {
    let ctx = with_asr().await;
    let (_, token) = ctx.pair_and_login("rec-large").await;
    let created = create_recording(&ctx, &token, "batch", "local-large-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    // 100 秒 ≈ 3.2MB：超过 axum 默认的 2MB，验证录音路由确实放宽了上限。
    let response = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=100000"),
            &token,
            test_wav(100_000),
        ))
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
}

/// 真实厂商链路的回归：默认不跑，避免 CI 依赖网络与密钥。
///
/// ```bash
/// ASR_PROBE_WAV=/path/to/speech.wav \
///   cargo test -p jarvis-service --test recordings real_asr -- --ignored --nocapture
/// ```
#[tokio::test]
#[ignore = "需要真实 ASR 凭据与 ASR_PROBE_WAV"]
#[allow(clippy::print_stdout)] // 手动跑探针时要看到真实转写结果
async fn real_asr_transcribes_uploaded_wav() {
    let path = std::env::var("ASR_PROBE_WAV").expect("需要设置 ASR_PROBE_WAV");
    let bytes = tokio::fs::read(&path).await.expect("读取探针音频失败");

    let ctx = setup_with(|config| {
        config.asr = AsrConfig {
            enabled: true,
            ..AsrConfig::default()
        };
    })
    .await;
    let (_, token) = ctx.pair_and_login("rec-real-asr").await;
    let created = create_recording(&ctx, &token, "realtime", "local-real-asr-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();

    let response = ctx
        .call(binary_post(
            &format!("/api/recordings/{id}/segments/0?start_ms=0&end_ms=5000"),
            &token,
            bytes,
        ))
        .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let segment = body_json(response).await;
    let text = segment["text"].as_str().unwrap_or_default();
    println!("真实转写结果：{text}");
    assert_eq!(segment["state"], "ready");
    assert!(!text.trim().is_empty(), "上游返回了空转写：{segment}");
}

#[tokio::test]
async fn summary_and_tts_pipeline_with_mocks() {
    let mut ctx = with_asr().await;
    ctx.state.summary = SummaryJobs::with_model(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Arc::new(FakeSummaryModel),
    );
    ctx.state.summary_audio = SummaryAudioJobs::with_synthesizer(
        ctx.state.pool.clone(),
        &ctx.state.config,
        Arc::new(MockTts::new()),
    );

    let (_, token) = ctx.pair_and_login("rec-summary").await;
    let created = create_recording(&ctx, &token, "batch", "local-summary-1").await;
    let id = created["id"].as_str().expect("缺少 id").to_string();
    for seq in 0..2 {
        let start = seq * 1000;
        let response = ctx
            .call(binary_post(
                &format!(
                    "/api/recordings/{id}/segments/{seq}?start_ms={start}&end_ms={}",
                    start + 1000
                ),
                &token,
                test_wav(1000),
            ))
            .await;
        assert_eq!(response.status(), StatusCode::CREATED);
    }
    let response = ctx
        .post_json(
            &format!("/api/recordings/{id}/complete"),
            &token,
            &json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);

    let detail = wait_status(&ctx, &token, &id, "ready").await;
    assert_eq!(detail["summary"]["status"], "pending");

    ctx.state.summary.process_pending().await;
    let detail = ctx.get_json(&format!("/api/recordings/{id}"), &token).await;
    let detail = body_json(detail).await;
    assert_eq!(detail["summary"]["status"], "ready");
    assert_eq!(detail["summary"]["style"], "brief");
    assert_eq!(detail["summary"]["style_preference"], "brief");
    assert!(detail["summary"]["text"]
        .as_str()
        .unwrap_or_default()
        .contains("概要"));

    let response = ctx
        .post_json(
            &format!("/api/recordings/{id}/summary/audio"),
            &token,
            &json!({}),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let detail = body_json(response).await;
    assert_eq!(detail["summary"]["audio_status"], "pending");

    ctx.state.summary_audio.process_pending().await;
    let response = ctx
        .get_json(&format!("/api/recordings/{id}/summary/audio"), &token)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();
    assert_eq!(content_type, "audio/mpeg");
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("读取语音失败");
    assert!(!bytes.is_empty());

    let before = ctx.get_json(&format!("/api/recordings/{id}"), &token).await;
    let before = body_json(before).await;
    let before_text = before["summary"]["text"].as_str().unwrap_or_default();

    // 只保存形式：不改正文、状态与语音。
    let response = ctx
        .patch_json(
            &format!("/api/recordings/{id}/summary"),
            &token,
            &json!({ "style": "detailed" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let detail = body_json(response).await;
    assert_eq!(detail["summary"]["style_preference"], "detailed");
    assert_eq!(detail["summary"]["style"], "brief");
    assert_eq!(detail["summary"]["text"], before_text);
    assert_eq!(detail["summary"]["audio_status"], "ready");

    // 手动重新生成：按偏好样式生成，旧语音必须失效。
    let response = ctx
        .post_json(
            &format!("/api/recordings/{id}/summary"),
            &token,
            &json!({ "style": "minutes" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let detail = body_json(response).await;
    assert_eq!(detail["summary"]["status"], "pending");
    assert_eq!(detail["summary"]["style_preference"], "minutes");
    assert_eq!(detail["summary"]["audio_status"], "none");

    ctx.state.summary.process_pending().await;
    let detail = ctx.get_json(&format!("/api/recordings/{id}"), &token).await;
    let detail = body_json(detail).await;
    assert_eq!(detail["summary"]["status"], "ready");
    assert_eq!(detail["summary"]["style"], "minutes");
    assert_eq!(detail["summary"]["style_preference"], "minutes");
}

#[tokio::test]
async fn recording_endpoints_require_auth() {
    let ctx = with_asr().await;
    let response = ctx.call(common::get("/api/recordings")).await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(body_json(response).await["code"], "unauthenticated");
}
