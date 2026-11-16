//! 产物文件落盘与读取。
//!
//! 文件系统是产物的**唯一副本**：数据库只记相对路径与元信息，正文不重复入库。
//! service 是唯一写盘方（worker 经 IPC 把正文送上来），因此不存在两个进程
//! 同时写同一个文件的可能。
//!
//! 写盘用"临时文件 + rename"：rename 在同一文件系统内是原子的，读者永远看不到
//! 半截文件；写入失败时临时文件不会顶替正式文件，记录也就不会指向一个残缺产物。

use std::path::{Path, PathBuf};

/// 产物目录名（相对数据目录）。
pub const ARTIFACTS_DIR: &str = "artifacts";

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("产物路径非法: {0}")]
    InvalidPath(String),
    #[error("产物文件不存在")]
    Missing,
    #[error("产物读写失败: {0}")]
    Io(#[from] std::io::Error),
}

/// 产物仓库。根目录固定为 `<data_dir>/artifacts`。
#[derive(Debug, Clone)]
pub struct ArtifactStore {
    root: PathBuf,
}

impl ArtifactStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 写入产物正文，返回相对路径与字节数。
    ///
    /// 相对路径形如 `{task_id}/{artifact_id}.txt`，由读取方拼回数据目录——
    /// 数据目录整体搬迁后历史记录仍然有效。
    pub async fn save(
        &self,
        task_id: &str,
        artifact_id: &str,
        mime: Option<&str>,
        content: &str,
    ) -> Result<(String, i64), StoreError> {
        self.save_bytes(task_id, artifact_id, mime, content.as_bytes())
            .await
    }

    /// 写入产物正文（二进制）。
    ///
    /// 图片、视频与音频走这条：它们不能先当 `&str`，那样要么编译不过，
    /// 要么被有损转码成乱码。语义与 [`Self::save`] 完全一致（单个实现）。
    pub async fn save_bytes(
        &self,
        task_id: &str,
        artifact_id: &str,
        mime: Option<&str>,
        content: &[u8],
    ) -> Result<(String, i64), StoreError> {
        check_segment(task_id)?;
        check_segment(artifact_id)?;

        let file_name = format!("{artifact_id}{}", extension_for(mime));
        let relative = format!("{task_id}/{file_name}");
        let dir = self.root.join(task_id);
        tokio::fs::create_dir_all(&dir).await?;

        // 临时文件名带 `.part` 后缀并加前导点：即便写入中途崩溃，也不会被
        // 目录列举或下载端点当成正式产物。
        let target = dir.join(&file_name);
        let temporary = dir.join(format!(".{artifact_id}.part"));
        tokio::fs::write(&temporary, content).await?;
        if let Err(err) = tokio::fs::rename(&temporary, &target).await {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(StoreError::Io(err));
        }

        Ok((relative, content.len() as i64))
    }

    /// 按相对路径读取正文。
    ///
    /// 路径可能来自数据库，所以做两道校验：拒绝绝对路径与 `..`，
    /// 再确认 `canonicalize` 之后仍在产物根目录内。
    pub async fn read(&self, relative: &str) -> Result<Vec<u8>, StoreError> {
        let candidate = self.resolve(relative)?;
        match tokio::fs::read(&candidate).await {
            Ok(bytes) => Ok(bytes),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Err(StoreError::Missing),
            Err(err) => Err(StoreError::Io(err)),
        }
    }

    /// 删除产物文件。文件本就不在时视为成功——删除的语义是"结果不存在"。
    pub async fn remove(&self, relative: &str) -> Result<(), StoreError> {
        let path = self.resolve(relative)?;
        match tokio::fs::remove_file(&path).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(StoreError::Io(err)),
        }
    }

    /// 解析相对路径到产物根内的真实路径。
    ///
    /// 给「另存为到项目」这类**只读源文件**的端点用：那边要流式复制，
    /// 不经过 [`Self::read`] 整片进内存。准入规则与读取完全一致（同一份实现）。
    pub(crate) fn resolve(&self, relative: &str) -> Result<PathBuf, StoreError> {
        let path = Path::new(relative);
        if relative.trim().is_empty() || path.is_absolute() {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }
        if path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }

        let root = match self.root.canonicalize() {
            Ok(root) => root,
            // 目录还没建（从来没有产物）等于"文件不存在"，不该报成路径非法。
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Err(StoreError::Missing);
            }
            Err(err) => return Err(StoreError::Io(err)),
        };
        let candidate = self.root.join(path);
        let resolved = candidate.canonicalize().map_err(|err| match err.kind() {
            std::io::ErrorKind::NotFound => StoreError::Missing,
            _ => StoreError::Io(err),
        })?;
        if !resolved.starts_with(&root) {
            return Err(StoreError::InvalidPath(relative.to_string()));
        }
        Ok(resolved)
    }
}

/// 由 mime 推导扩展名。只覆盖当前会产出的类型，其余一律 `.bin`。
///
/// 媒体产物必须在这里登记：扩展名不对，客户端的预览器就认不出文件类型。
pub(crate) fn extension_for(mime: Option<&str>) -> &'static str {
    match mime
        .unwrap_or_default()
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
    {
        "text/plain" => ".txt",
        "text/markdown" => ".md",
        "application/json" => ".json",
        "image/png" => ".png",
        "image/jpeg" => ".jpg",
        "video/mp4" => ".mp4",
        _ => ".bin",
    }
}

/// 目录/文件名的片段校验：不允许分隔符与 `..`，避免拼出根目录之外的路径。
fn check_segment(segment: &str) -> Result<(), StoreError> {
    let bad = segment.is_empty()
        || segment.contains('/')
        || segment.contains('\\')
        || segment.contains("..")
        || segment.starts_with('.');
    if bad {
        return Err(StoreError::InvalidPath(segment.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, ArtifactStore) {
        let dir = tempfile::tempdir().expect("创建临时目录失败");
        let store = ArtifactStore::new(dir.path().join(ARTIFACTS_DIR));
        (dir, store)
    }

    #[tokio::test]
    async fn saves_and_reads_back() {
        let (_dir, store) = store();
        let (relative, size) = store
            .save("task_1", "art_1", Some("text/plain"), "行程草案")
            .await
            .expect("写入失败");

        assert_eq!(relative, "task_1/art_1.txt");
        assert_eq!(size as usize, "行程草案".len());

        let bytes = store.read(&relative).await.expect("读取失败");
        assert_eq!(String::from_utf8(bytes).expect("非 UTF-8"), "行程草案");
    }

    #[tokio::test]
    async fn missing_file_is_reported() {
        let (_dir, store) = store();
        tokio::fs::create_dir_all(store.root())
            .await
            .expect("建目录失败");
        assert!(matches!(
            store.read("task_1/none.txt").await,
            Err(StoreError::Missing)
        ));
    }

    #[tokio::test]
    async fn rejects_path_traversal() {
        let (_dir, store) = store();
        tokio::fs::create_dir_all(store.root())
            .await
            .expect("建目录失败");

        for bad in ["../agent.db", "/etc/passwd", "", "task/../../x"] {
            let result = store.read(bad).await;
            assert!(
                matches!(result, Err(StoreError::InvalidPath(_))),
                "{bad} 应被拒绝，实际 {result:?}"
            );
        }
    }

    #[test]
    fn extension_follows_mime() {
        assert_eq!(extension_for(Some("text/plain")), ".txt");
        assert_eq!(extension_for(Some("text/plain; charset=utf-8")), ".txt");
        assert_eq!(extension_for(Some("application/json")), ".json");
        assert_eq!(extension_for(Some("image/png")), ".png");
        assert_eq!(extension_for(Some("image/jpeg")), ".jpg");
        assert_eq!(extension_for(Some("video/mp4")), ".mp4");
        assert_eq!(extension_for(None), ".bin");
    }

    #[tokio::test]
    async fn saves_binary_bytes_untouched() {
        let (_dir, store) = store();
        let png = [0x89u8, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF];

        let (relative, size) = store
            .save_bytes("task_1", "art_1", Some("image/png"), &png)
            .await
            .expect("写入失败");

        assert_eq!(relative, "task_1/art_1.png");
        assert_eq!(size as usize, png.len());
        assert_eq!(store.read(&relative).await.expect("读取失败"), png);
    }
}
