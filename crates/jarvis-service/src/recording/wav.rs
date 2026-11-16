//! WAV 头解析、格式校验与分段拼接。
//!
//! 全链路只接受一种格式：**16kHz / 单声道 / PCM16**。客户端按同一参数采集，
//! 服务端也按同一参数转写与归档，两边都不需要为"兼容各种音频"写分支。
//! 代价是导入其它格式的录音需要先转码——这属于后续版本，不在本期。

/// 解析出的 WAV 结构信息。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WavInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    /// `data` 块在文件里的起始偏移。
    pub data_offset: usize,
    /// `data` 块实际可读长度（已按文件真实长度收敛）。
    pub data_len: usize,
}

impl WavInfo {
    /// 音频时长（毫秒）。按 `data` 字节数换算，不信任头部声明。
    pub fn duration_ms(self) -> i64 {
        let bytes_per_ms = (self.sample_rate as u64)
            .saturating_mul(self.channels as u64)
            .saturating_mul(self.bits_per_sample as u64 / 8)
            / 1000;
        if bytes_per_ms == 0 {
            return 0;
        }
        (self.data_len as u64 / bytes_per_ms) as i64
    }
}

/// 解析 WAV 头。只做必要的边界检查，不认识的块跳过。
pub fn parse(bytes: &[u8]) -> Result<WavInfo, String> {
    if bytes.len() < 44 {
        return Err("文件太短，不是一个完整的 WAV".to_string());
    }
    if &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("不是 RIFF/WAVE 文件".to_string());
    }

    let mut fmt: Option<(u16, u16, u32, u16)> = None;
    let mut data: Option<(usize, usize)> = None;
    let mut offset = 12usize;

    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(
            bytes[offset + 4..offset + 8]
                .try_into()
                .map_err(|_| "块长度字段损坏".to_string())?,
        ) as usize;
        let body = offset + 8;
        let end = body.checked_add(size).ok_or("块长度溢出")?;

        match id {
            b"fmt " => {
                if size < 16 || body + 16 > bytes.len() {
                    return Err("fmt 块不完整".to_string());
                }
                let audio_format = u16::from_le_bytes(
                    bytes[body..body + 2]
                        .try_into()
                        .map_err(|_| "fmt 损坏".to_string())?,
                );
                let channels = u16::from_le_bytes(
                    bytes[body + 2..body + 4]
                        .try_into()
                        .map_err(|_| "fmt 损坏".to_string())?,
                );
                let sample_rate = u32::from_le_bytes(
                    bytes[body + 4..body + 8]
                        .try_into()
                        .map_err(|_| "fmt 损坏".to_string())?,
                );
                let bits = u16::from_le_bytes(
                    bytes[body + 14..body + 16]
                        .try_into()
                        .map_err(|_| "fmt 损坏".to_string())?,
                );
                fmt = Some((audio_format, channels, sample_rate, bits));
            }
            b"data" => {
                // 流式写出的 WAV 可能把 data 长度留成 0 或 0xFFFFFFFF：
                // 按文件真实结尾收敛，不因为头部偷懒就判整段无效。
                let available = bytes.len().saturating_sub(body);
                let len = if size == 0 || size > available {
                    available
                } else {
                    size
                };
                data = Some((body, len));
            }
            _ => {}
        }

        // 块按偶数字节对齐；`end` 已含 size，补一个填充字节。
        offset = end + (size & 1);
    }

    let (audio_format, channels, sample_rate, bits_per_sample) =
        fmt.ok_or_else(|| "缺少 fmt 块".to_string())?;
    if audio_format != 1 {
        return Err(format!(
            "只支持 PCM（audio_format=1），实际是 {audio_format}；请上传未压缩的 WAV"
        ));
    }
    let (data_offset, data_len) = data.ok_or_else(|| "缺少 data 块".to_string())?;

    Ok(WavInfo {
        sample_rate,
        channels,
        bits_per_sample,
        data_offset,
        data_len,
    })
}

/// 解析并校验为「16kHz / 单声道 / PCM16」。
pub fn parse_16k_mono(bytes: &[u8]) -> Result<WavInfo, String> {
    let info = parse(bytes)?;
    if info.sample_rate != 16_000 {
        return Err(format!(
            "采样率必须是 16000，实际是 {}；客户端请按 16k 采集",
            info.sample_rate
        ));
    }
    if info.channels != 1 {
        return Err(format!("必须是单声道，实际是 {} 声道", info.channels));
    }
    if info.bits_per_sample != 16 {
        return Err(format!(
            "必须是 16 bit PCM，实际是 {} bit",
            info.bits_per_sample
        ));
    }
    Ok(info)
}

/// 只凭文件头取 `data` 块声明长度。
///
/// 流式下载时只读前 44 字节算总长度，不能把整段音频读进内存；
/// 因此这里不能用 [`parse`] 的"按真实文件长度收敛"结果。
pub fn declared_data_len(bytes: &[u8]) -> Result<usize, String> {
    let info = parse_16k_mono(bytes)?;
    if bytes.len() >= 44 {
        let declared = u32::from_le_bytes(
            bytes[40..44]
                .try_into()
                .map_err(|_| "data 长度字段损坏".to_string())?,
        ) as usize;
        if declared > 0 {
            return Ok(declared);
        }
    }
    Ok(info.data_len)
}

/// 构造 16kHz / 单声道 / PCM16 的 44 字节 WAV 头。
pub fn header(data_len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(44);
    let riff_len = (36 + data_len) as u32;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&riff_len.to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&16_000u32.to_le_bytes());
    out.extend_from_slice(&32_000u32.to_le_bytes()); // byte rate = 16000 * 2
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    out
}

/// 把多段 WAV 的 PCM 数据按顺序拼成一个 WAV。
///
/// 每个分段都必须是 16k 单声道 PCM16；任何一段不合格就整体失败，
/// 不悄悄跳过——少一段音频比报错更难被发现。
pub fn concat(parts: &[Vec<u8>]) -> Result<Vec<u8>, String> {
    let mut total = 0usize;
    let mut payloads = Vec::with_capacity(parts.len());
    for (index, part) in parts.iter().enumerate() {
        let info = parse_16k_mono(part).map_err(|err| format!("第 {index} 段无效：{err}"))?;
        total = total
            .checked_add(info.data_len)
            .ok_or_else(|| "拼接后长度溢出".to_string())?;
        payloads.push(&part[info.data_offset..info.data_offset + info.data_len]);
    }
    if total > u32::MAX as usize - 36 {
        return Err("拼接后超出 WAV 可表示的长度".to_string());
    }

    let mut out = header(total);
    out.reserve(total);
    for payload in payloads {
        out.extend_from_slice(payload);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wav(sample_rate: u32, channels: u16, bits: u16, samples: usize) -> Vec<u8> {
        let bytes_per_sample = (bits / 8) as usize;
        let data_len = samples * channels as usize * bytes_per_sample;
        let mut out = header(data_len);
        // 把头部里的采样率/声道/位深改成测试值，验证解析而不是验证构造函数。
        out[22..24].copy_from_slice(&channels.to_le_bytes());
        out[24..28].copy_from_slice(&sample_rate.to_le_bytes());
        out[34..36].copy_from_slice(&bits.to_le_bytes());
        out.extend(std::iter::repeat_n(0u8, data_len));
        out
    }

    #[test]
    fn parses_16k_mono_pcm16() {
        let bytes = wav(16_000, 1, 16, 16_000);
        let info = parse_16k_mono(&bytes).expect("应能解析");
        assert_eq!(info.sample_rate, 16_000);
        assert_eq!(info.channels, 1);
        assert_eq!(info.data_len, 32_000);
        assert_eq!(info.duration_ms(), 1000);
    }

    #[test]
    fn rejects_non_pcm_or_wrong_shape() {
        let stereo = wav(16_000, 2, 16, 1_000);
        assert!(parse_16k_mono(&stereo).is_err(), "立体声应被拒绝");

        let low_rate = wav(8_000, 1, 16, 1_000);
        assert!(parse_16k_mono(&low_rate).is_err(), "8k 应被拒绝");

        let eight_bit = wav(16_000, 1, 8, 1_000);
        assert!(parse_16k_mono(&eight_bit).is_err(), "8bit 应被拒绝");

        let mut not_wav = wav(16_000, 1, 16, 10);
        not_wav[0..4].copy_from_slice(b"XXXX");
        assert!(parse_16k_mono(&not_wav).is_err(), "非 RIFF 应被拒绝");
    }

    #[test]
    fn accepts_streaming_header_with_unknown_data_size() {
        let mut bytes = wav(16_000, 1, 16, 1_000);
        // 模拟"边写边传"：data 长度留 0xFFFFFFFF。
        let len = bytes.len();
        bytes[40..44].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        let info = parse_16k_mono(&bytes).expect("应按真实长度收敛");
        assert_eq!(info.data_len, len - 44);
    }

    #[test]
    fn concat_builds_one_valid_wav() {
        let first = wav(16_000, 1, 16, 8_000);
        let second = wav(16_000, 1, 16, 4_000);
        let joined = concat(&[first, second]).expect("拼接应成功");

        let info = parse_16k_mono(&joined).expect("拼接结果应可解析");
        assert_eq!(info.duration_ms(), 750);
        assert_eq!(info.data_len, 24_000);
    }

    #[test]
    fn concat_rejects_bad_segment() {
        let good = wav(16_000, 1, 16, 100);
        let bad = wav(44_100, 1, 16, 100);
        let err = concat(&[good, bad]).expect_err("含坏分段应失败");
        assert!(err.contains("第 1 段"), "错误要指出是哪一段：{err}");
    }
}
