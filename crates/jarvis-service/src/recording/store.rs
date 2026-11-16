//! 录音分段的磁盘落地。
//!
//! 目录布局：
//! ```text
//! {data_dir}/recordings/{recording_id}/seg_00000.wav
//! ```
//! 库里只存相对路径，读写都按「自己拼出来的路径」进行：
//! 客户端永远不能指定路径，也就不存在越界读写的入口。
//!
//! 写入沿用 `artifact_store` 的「临时文件 + rename」：进程在写一半时退出，
//! 磁盘上最多留一个 `.tmp`，不会出现半截 WAV 被当成有效分段。

use std::path::{Path, PathBuf};

use tokio::io::AsyncWriteExt;

const SEGMENT_PREFIX: &str = "seg_";
const SEGMENT_SUFFIX: &str = ".wav";

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("音频文件不存在")]
    Missing,
    #[error("路径非法: {0}")]
    InvalidPath(String),
    #[error("音频读写失败: {0}")]
    Io(String),
}

impl From<std::io::Error> for StoreError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err.to_string())
    }
}

#[derive(Debug, Clone)]
pub struct RecordingStore {
    root: PathBuf,
}

impl RecordingStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn recording_dir(&self, recording_id: &str) -> PathBuf {
        self.root.join(recording_id)
    }

    /// 相对 `{data_dir}/recordings` 的路径，落库用。
    pub fn relative_path(recording_id: &str, seq: u32) -> String {
        format!("{recording_id}/{SEGMENT_PREFIX}{seq:05}{SEGMENT_SUFFIX}")
    }

    /// 总结语音的文件名与相对路径。
    pub fn summary_relative_path(recording_id: &str, format: &str) -> String {
        format!("{recording_id}/summary.{format}")
    }

    /// 原子写入总结语音，返回相对路径。
    pub async fn write_summary_audio(
        &self,
        recording_id: &str,
        format: &str,
        bytes: &[u8],
    ) -> Result<String, StoreError> {
        if !is_safe_id(recording_id) || !is_safe_extension(format) {
            return Err(StoreError::InvalidPath(recording_id.to_string()));
        }
        let relative = Self::summary_relative_path(recording_id, format);
        let target = self.resolve(&relative)?;
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let tmp = target.with_extension(format!("{format}.tmp"));
        {
            let mut file = tokio::fs::File::create(&tmp).await?;
            file.write_all(bytes).await?;
            file.flush().await?;
            file.sync_all().await?;
        }
        tokio::fs::rename(&tmp, &target).await?;
        Ok(relative)
    }

    /// 读取总结语音。
    pub async fn read_summary_audio(&self, relative: &str) -> Result<Vec<u8>, StoreError> {
        let path = self.resolve(relative)?;
        match tokio::fs::read(&path).await {
            Ok(bytes) => Ok(bytes),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Err(StoreError::Missing),
            Err(err) => Err(StoreError::Io(err.to_string())),
        }
    }

    /// 原子写入一个分段，返回相对路径。
    pub async fn write_segment(
        &self,
        recording_id: &str,
        seq: u32,
        bytes: &[u8],
    ) -> Result<String, StoreError> {
        if !is_safe_id(recording_id) {
            return Err(StoreError::InvalidPath(recording_id.to_string()));
        }

        let relative = Self::relative_path(recording_id, seq);
        let target = self.resolve(&relative)?;
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let tmp = target.with_extension("wav.tmp");
        {
            let mut file = tokio::fs::File::create(&tmp).await?;
            file.write_all(bytes).await?;
            file.flush().await?;
            file.sync_all().await?;
        }
        tokio::fs::rename(&tmp, &target).await?;
        Ok(relative)
    }

    /// 读取一个分段。`relative` 来自数据库，仍需校验形状。
    pub async fn read_segment(&self, relative: &str) -> Result<Vec<u8>, StoreError> {
        let path = self.resolve(relative)?;
        match tokio::fs::read(&path).await {
            Ok(bytes) => Ok(bytes),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Err(StoreError::Missing),
            Err(err) => Err(StoreError::Io(err.to_string())),
        }
    }

    /// 按顺序读取整条录音的分段。
    pub async fn read_all(&self, segments: &[(i64, String)]) -> Result<Vec<Vec<u8>>, StoreError> {
        let mut out = Vec::with_capacity(segments.len());
        for (_, relative) in segments {
            out.push(self.read_segment(relative).await?);
        }
        Ok(out)
    }

    /// 删除整条录音的目录。目录本就不存在时视为成功（幂等）。
    pub async fn remove_recording(&self, recording_id: &str) -> Result<(), StoreError> {
        if !is_safe_id(recording_id) {
            return Err(StoreError::InvalidPath(recording_id.to_string()));
        }
        let dir = self.recording_dir(recording_id);
        match tokio::fs::remove_dir_all(&dir).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(StoreError::Io(err.to_string())),
        }
    }

    /// 把数据库里的相对路径还原成磁盘路径，供流式下载逐段打开。
    pub fn path_of(&self, relative: &str) -> Result<PathBuf, StoreError> {
        self.resolve(relative)
    }

    /// 把相对路径收敛到根目录内，并校验它正好是「一个 id / 一个合法分段名」。
    fn resolve(&self, relative: &str) -> Result<PathBuf, StoreError> {
        let parts: Vec<&str> = relative.split('/').collect();
        if parts.len() != 2 || !is_safe_id(parts[0]) {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }
        let file = parts[1];
        if let Some(format) = file.strip_prefix("summary.") {
            if !is_safe_extension(format) {
                return Err(StoreError::InvalidPath(relative.to_string()));
            }
            return Ok(self.root.join(parts[0]).join(file));
        }
        if !file.starts_with(SEGMENT_PREFIX) || !file.ends_with(SEGMENT_SUFFIX) {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }
        let seq = &file[SEGMENT_PREFIX.len()..file.len() - SEGMENT_SUFFIX.len()];
        if seq.len() != 5 || !seq.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }
        Ok(self.root.join(parts[0]).join(file))
    }
}

/// 录音 id 只允许小写字母、数字、下划线与短横线。
///
/// 服务端自己生成的 id 天然满足；这里主要挡住"手工构造了个带 `..` 的路径"
/// 这类输入——即使它们只来自已配对设备。
pub fn is_safe_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// 总结语音扩展名：只允许 mp3 / wav 这类短 ASCII 标识，挡住路径穿越。
pub fn is_safe_extension(value: &str) -> bool {
    !value.is_empty() && value.len() <= 8 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_ids_reject_traversal() {
        assert!(is_safe_id("rec_abc123"));
        assert!(is_safe_id("rec-1"));
        assert!(!is_safe_id(""));
        assert!(!is_safe_id("../etc"));
        assert!(!is_safe_id("a/b"));
        assert!(!is_safe_id(&"x".repeat(65)));
    }

    #[test]
    fn relative_path_is_padded_and_stable() {
        assert_eq!(
            RecordingStore::relative_path("rec_1", 7),
            "rec_1/seg_00007.wav"
        );
    }

    #[tokio::test]
    async fn write_read_and_remove_roundtrip() {
        let dir = tempfile::tempdir().expect("临时目录");
        let store = RecordingStore::new(dir.path().to_path_buf());

        let relative = store
            .write_segment("rec_1", 0, b"hello")
            .await
            .expect("写入失败");
        assert_eq!(relative, "rec_1/seg_00000.wav");
        assert_eq!(
            store.read_segment(&relative).await.expect("读取失败"),
            b"hello"
        );

        store.remove_recording("rec_1").await.expect("删除失败");
        assert!(matches!(
            store.read_segment(&relative).await,
            Err(StoreError::Missing)
        ));
        // 重复删除是幂等的。
        store
            .remove_recording("rec_1")
            .await
            .expect("重复删除应成功");
    }

    #[tokio::test]
    async fn rejects_unsafe_relative_paths() {
        let dir = tempfile::tempdir().expect("临时目录");
        let store = RecordingStore::new(dir.path().to_path_buf());
        for bad in [
            "../seg_00000.wav",
            "rec_1/../../x.wav",
            "rec_1/other.wav",
            "rec_1/seg_abc.wav",
            "rec_1/seg_00000.wav/extra",
        ] {
            assert!(
                matches!(
                    store.read_segment(bad).await,
                    Err(StoreError::InvalidPath(_))
                ),
                "{bad} 应被拒绝"
            );
        }
    }
}
