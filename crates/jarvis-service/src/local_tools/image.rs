//! 图片识别：只认文件头，不解码像素。
//!
//! 为什么自己写而不是引入 `image` crate：我们只需要"这是什么格式、多大尺寸"，
//! 而 `image` 会带进一整套编解码器（编译时间与产物体积都是代价）。四种格式的
//! 头部结构固定，加起来不到一百行。
//!
//! 尺寸解析是**尽力而为**：解不出来只说明"这是张 WebP"，不算失败。模型看不到
//! 画面，尺寸的价值只在提示"这是一张大图，别指望我描述它"。

/// 支持识别的图片格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImageFormat {
    Jpeg,
    Png,
    Gif,
    WebP,
}

impl ImageFormat {
    /// 给模型看的中文名。
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Jpeg => "JPEG",
            Self::Png => "PNG",
            Self::Gif => "GIF",
            Self::WebP => "WebP",
        }
    }
}

/// 按文件头判格式。扩展名可以骗人，文件头不行。
pub(crate) fn sniff(bytes: &[u8]) -> Option<ImageFormat> {
    if bytes.len() >= 8 && bytes[..8] == [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A] {
        return Some(ImageFormat::Png);
    }
    if bytes.len() >= 6 && (&bytes[..6] == b"GIF87a" || &bytes[..6] == b"GIF89a") {
        return Some(ImageFormat::Gif);
    }
    if bytes.len() >= 3 && bytes[..3] == [0xFF, 0xD8, 0xFF] {
        return Some(ImageFormat::Jpeg);
    }
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some(ImageFormat::WebP);
    }
    None
}

/// 从头部字节里取宽高。取不到时返回 `None`。
pub(crate) fn dimensions(bytes: &[u8], format: ImageFormat) -> Option<(u32, u32)> {
    match format {
        ImageFormat::Png => {
            // 8 字节签名 + 4 字节长度 + 4 字节 "IHDR"，宽高各 4 字节大端。
            if bytes.len() < 24 {
                return None;
            }
            let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
            let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
            Some((width, height))
        }
        ImageFormat::Gif => {
            // 逻辑屏幕宽高：小端，各 2 字节。
            if bytes.len() < 10 {
                return None;
            }
            let width = u16::from_le_bytes(bytes[6..8].try_into().ok()?) as u32;
            let height = u16::from_le_bytes(bytes[8..10].try_into().ok()?) as u32;
            Some((width, height))
        }
        ImageFormat::Jpeg => jpeg_dimensions(bytes),
        ImageFormat::WebP => webp_dimensions(bytes),
    }
}

fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut index = 2usize;

    while index + 8 < bytes.len() {
        if bytes[index] != 0xFF {
            index += 1;
            continue;
        }

        let marker = bytes[index + 1];
        // 填充字节、无长度段（SOI/EOI/RSTn）直接跳过。
        if marker == 0xFF {
            index += 1;
            continue;
        }
        if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
            index += 2;
            continue;
        }

        let length = u16::from_be_bytes([bytes[index + 2], bytes[index + 3]]) as usize;
        if length < 2 {
            return None;
        }

        // SOF0..SOF15，去掉 C4(DHT)、C8(JPG)、CC(DAC)。
        if (0xC0..=0xCF).contains(&marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
            let height = u16::from_be_bytes([bytes[index + 5], bytes[index + 6]]) as u32;
            let width = u16::from_be_bytes([bytes[index + 7], bytes[index + 8]]) as u32;
            return Some((width, height));
        }

        index += 2 + length;
    }

    None
}

fn webp_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 30 {
        return None;
    }

    // 只有扩展格式（VP8X）把画布尺寸放在固定位置；VP8/VP8L 的尺寸藏在码流里，
    // 解析收益太低，直接放弃——调用方会退化成"不知道多大"。
    if &bytes[12..16] != b"VP8X" {
        return None;
    }

    let width = le24(&bytes[24..27])? + 1;
    let height = le24(&bytes[27..30])? + 1;
    Some((width, height))
}

/// 24 位小端整数。WebP 的画布尺寸是"实际值 - 1"存在 3 个字节里。
fn le24(bytes: &[u8]) -> Option<u32> {
    if bytes.len() < 3 {
        return None;
    }
    Some(u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_each_format() {
        assert_eq!(
            sniff(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]),
            Some(ImageFormat::Png)
        );
        assert_eq!(sniff(b"GIF89a...."), Some(ImageFormat::Gif));
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(ImageFormat::Jpeg));
        assert_eq!(
            sniff(b"RIFF\x00\x00\x00\x00WEBPVP8X"),
            Some(ImageFormat::WebP)
        );
        assert_eq!(sniff(b"hello"), None);
    }

    #[test]
    fn reads_png_size() {
        let mut bytes = vec![0u8; 24];
        bytes[..8].copy_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        bytes[16..20].copy_from_slice(&1200u32.to_be_bytes());
        bytes[20..24].copy_from_slice(&800u32.to_be_bytes());

        assert_eq!(dimensions(&bytes, ImageFormat::Png), Some((1200, 800)));
    }

    #[test]
    fn reads_gif_size() {
        let mut bytes = b"GIF89a".to_vec();
        bytes.extend_from_slice(&320u16.to_le_bytes());
        bytes.extend_from_slice(&240u16.to_le_bytes());

        assert_eq!(dimensions(&bytes, ImageFormat::Gif), Some((320, 240)));
    }

    #[test]
    fn reads_webp_canvas_size() {
        let mut bytes = vec![0u8; 30];
        bytes[..4].copy_from_slice(b"RIFF");
        bytes[8..12].copy_from_slice(b"WEBP");
        bytes[12..16].copy_from_slice(b"VP8X");
        // 尺寸以"实际值 - 1"存 24 位小端。
        bytes[24..27].copy_from_slice(&[0x2F, 0x02, 0x00]); // 560 - 1 = 559
        bytes[27..30].copy_from_slice(&[0x8F, 0x01, 0x00]); // 400 - 1 = 399

        assert_eq!(dimensions(&bytes, ImageFormat::WebP), Some((560, 400)));
    }

    #[test]
    fn reads_jpeg_size() {
        // SOI + APP0(长度 4) + SOF0
        let mut bytes = vec![0xFF, 0xD8];
        bytes.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]);
        bytes.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
        bytes.extend_from_slice(&640u16.to_be_bytes());
        bytes.extend_from_slice(&480u16.to_be_bytes());
        bytes.extend_from_slice(&[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);

        assert_eq!(dimensions(&bytes, ImageFormat::Jpeg), Some((480, 640)));
    }
}
