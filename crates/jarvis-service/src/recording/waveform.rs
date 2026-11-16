//! 总结语音的波形峰值。
//!
//! 客户端解不了 mp3，所以回放总结语音时的波形由服务端按需算：请求进来
//! 才解码，结果不落盘也不落库——重生成语音后自然重算，不存在"旧峰值
//! 残留"这一整类 bug。
//!
//! 这里只做解码与取最大值，不做任何视觉处理（归一化、dB 曲线都在客户端），
//! 两端可以各自单测。

use std::io::Cursor;

use symphonia::core::audio::Signal;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// 峰值桶数：与客户端 `kWaveformBuckets` 一致，改动要两端同步。
pub const PEAK_BUCKETS: usize = 480;

/// 聚合窗口的样本数（16k 下约 8ms）。
///
/// 先按固定窗口累计最大值、解码完再按比例合并到 480 桶：mp3 的
/// `n_frames` 常常是未知的，只有边解边聚合才能在内存有界的前提下
/// 拿到正确的时长比例。窗口取小一点，短语音也能铺满整条波形：
/// 1 秒音频有 125 个窗口，够 480 桶分。
const WINDOW_SAMPLES: usize = 128;

/// 把 [bytes]（按 [format] 给探测提示）解码成 [buckets] 个 `0..255` 峰值。
///
/// 失败时返回可直接展示的原因；调用方（handler）记一条 warn 并让客户端
/// 静默降级为进度条，不影响播放本身。
pub fn peaks(bytes: &[u8], format: &str, buckets: usize) -> Result<Vec<u8>, String> {
    if buckets == 0 {
        return Err("峰值桶数不能为 0".to_string());
    }

    let mut reader = open(bytes, format)?;
    let (track_id, codec_params) = {
        let track = reader
            .tracks()
            .iter()
            .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or_else(|| "音频里没有可解码的音轨".to_string())?;
        (track.id, track.codec_params.clone())
    };
    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &DecoderOptions::default())
        .map_err(|err| format!("初始化解码器失败：{err}"))?;

    let windows = collect_windows(&mut reader, &mut decoder, track_id)?;
    if windows.is_empty() {
        // 解码成功但一个样本都没有（0 长度的假文件）：给全静音，让客户端
        // 画出中线而不是报错。
        return Ok(vec![0; buckets]);
    }
    Ok(merge_windows(&windows, buckets))
}

fn open(bytes: &[u8], format: &str) -> Result<Box<dyn FormatReader>, String> {
    let source = MediaSourceStream::new(Box::new(Cursor::new(bytes.to_vec())), Default::default());
    let mut hint = Hint::new();
    if !format.is_empty() {
        hint.with_extension(format);
    }
    symphonia::default::get_probe()
        .format(
            &hint,
            source,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map(|probed| probed.format)
        .map_err(|err| format!("探测音频格式失败：{err}"))
}

fn collect_windows(
    reader: &mut Box<dyn FormatReader>,
    decoder: &mut Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
) -> Result<Vec<u8>, String> {
    let mut windows: Vec<u8> = Vec::new();
    let mut peak = 0f32;
    let mut count = 0usize;

    loop {
        let packet = match reader.next_packet() {
            Ok(packet) => packet,
            // 读到结尾是正常收尾，不是错误。
            Err(SymphoniaError::IoError(err))
                if err.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            // 流参数变了（多见于某些 mp3 的拼接）：重置后继续解下一包。
            Err(SymphoniaError::ResetRequired) => continue,
            Err(err) => return Err(format!("读取音频包失败：{err}")),
        };
        if packet.track_id() != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            // 单帧损坏不该让整段波形失效：跳过这一包继续。
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(SymphoniaError::IoError(err))
                if err.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            Err(err) => return Err(format!("解码音频失败：{err}")),
        };

        // 统一转成 f32 再遍历：symphonia 的包可能是 i16/u8/f32，
        // 这里只关心幅度，不需要保持原始位深。
        let mut samples = decoded.make_equivalent::<f32>();
        decoded.convert(&mut samples);

        // 平面数据逐声道遍历即可：峰值统计与声道交织顺序无关。
        for channel in 0..samples.spec().channels.count() {
            for &sample in samples.chan(channel) {
                let magnitude = sample.abs();
                if magnitude > peak {
                    peak = magnitude;
                }
                count += 1;
                if count >= WINDOW_SAMPLES {
                    windows.push(amplitude_u8(peak));
                    peak = 0.0;
                    count = 0;
                }
            }
        }
    }

    if count > 0 {
        windows.push(amplitude_u8(peak));
    }
    Ok(windows)
}

/// 窗口序列按比例铺到 [buckets] 个桶，每桶取覆盖窗口的最大值。
///
/// 一个窗口覆盖多个桶（窗口数少于桶数）时整段填满，避免短语音的波形
/// 出现一条条空档；桶数少于窗口数时自然退化成"每桶取最大值"。
fn merge_windows(windows: &[u8], buckets: usize) -> Vec<u8> {
    let mut out = vec![0u8; buckets];
    let total = windows.len();
    for (index, &value) in windows.iter().enumerate() {
        let start = index * buckets / total;
        let end = (((index + 1) * buckets / total).max(start + 1)).min(buckets);
        for bucket in &mut out[start..end] {
            if value > *bucket {
                *bucket = value;
            }
        }
    }
    out
}

/// `f32` 幅度（0..1）→ `0..255`。超出 ±1 的削波样本夹住即可。
fn amplitude_u8(peak: f32) -> u8 {
    (peak.clamp(0.0, 1.0) * 255.0).round() as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 生成 16k/单声道/PCM16 的正弦 WAV。
    fn sine_wav(seconds: f32, amplitude: f32) -> Vec<u8> {
        let sample_rate = 16_000u32;
        let samples = (sample_rate as f32 * seconds) as usize;
        let mut pcm = Vec::with_capacity(samples * 2);
        for index in 0..samples {
            let phase = index as f32 / sample_rate as f32 * 440.0 * std::f32::consts::TAU;
            let value = (phase.sin() * amplitude * 32767.0) as i16;
            pcm.extend_from_slice(&value.to_le_bytes());
        }

        let mut out = Vec::with_capacity(44 + pcm.len());
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(&pcm);
        out
    }

    #[test]
    fn wav_sine_produces_buckets() {
        let wav = sine_wav(1.0, 0.8);
        let peaks = peaks(&wav, "wav", PEAK_BUCKETS).expect("解码应成功");
        assert_eq!(peaks.len(), PEAK_BUCKETS);
        // 440Hz 正弦在 1 秒里有 440 个周期，每个桶都覆盖到波峰附近。
        assert!(peaks.iter().all(|&value| value > 150), "{peaks:?}");
        assert!(peaks.iter().all(|&value| value < 255), "正弦不该满幅削波");
    }

    #[test]
    fn silence_is_all_zero() {
        let wav = sine_wav(0.5, 0.0);
        let peaks = peaks(&wav, "wav", PEAK_BUCKETS).expect("解码应成功");
        assert!(peaks.iter().all(|&value| value == 0));
    }

    #[test]
    fn truncated_wav_still_returns_peaks() {
        let wav = sine_wav(1.0, 0.5);
        let truncated = &wav[..wav.len() - 200];
        // 头里声明的 data 长度比真实字节多：symphonia 读到 EOF 就收尾，
        // 已解出的部分仍然可用。
        let peaks = peaks(truncated, "wav", PEAK_BUCKETS).expect("截断的文件也应给出峰值");
        assert_eq!(peaks.len(), PEAK_BUCKETS);
    }

    #[test]
    fn garbage_bytes_report_error() {
        let bytes = vec![0u8; 64];
        assert!(peaks(&bytes, "mp3", PEAK_BUCKETS).is_err());
    }

    #[test]
    fn merge_windows_keeps_max_in_bucket() {
        let windows = vec![10u8, 200, 20, 30];
        assert_eq!(merge_windows(&windows, 2), vec![200, 30]);
    }

    #[test]
    fn zero_buckets_is_rejected() {
        assert!(peaks(&sine_wav(0.1, 0.5), "wav", 0).is_err());
    }
}
