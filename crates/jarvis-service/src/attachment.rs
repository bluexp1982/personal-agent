//! 输入框附件：上传登记、绑定消息、正文读取与上下文注入。
//!
//! 职责边界：
//! - 本模块管"附件"这件事的全部真理：行怎么写、文件怎么落、什么时候算孤儿；
//! - 不碰 HTTP：路由、请求体上限、错误体映射在 `api/attachments.rs`；
//! - 不碰消息结构：绑定只写 `message_id` / `conversation_id` 两列，
//!   消息行里的 `content_json.attachments` 由 `conversation` 组装。
//!
//! 一生分两段：上传时落一行（`message_id` 为空），发送时才绑定。这样空态页
//! 不必"先建会话再上传"——上传与会话完全解耦。
//!
//! 文件与库分工与产物一致：库只记相对路径与元信息，正文永不进库。

use base64::Engine;
use protocol::Attachment;
use sqlx::SqlitePool;

use crate::artifact_store::{extension_for, ArtifactStore, StoreError};
use crate::chat::{ChatMessage, ChatRole};
use crate::clock::now_ms;
use crate::ids::new_id;
use crate::state::AppState;

/// 附件目录名（相对数据目录）。
pub const ATTACHMENTS_DIR: &str = "attachments";

/// 附件文件在 attachments 根下的子目录。
///
/// 只为了复用 [`ArtifactStore`] 的"相对路径带一段目录"写法（它据此做越界校验）；
/// 附件本身是扁平集合，没有再分层的必要。
const UPLOAD_DIR: &str = "upload";

/// 文件名展示上限。再长在 chip 上也是一串省略号。
const MAX_NAME_CHARS: usize = 120;

/// 判定"这是文本文件"的 mime。
const TEXT_MIMES: &[&str] = &[
    "application/json",
    "application/xml",
    "application/yaml",
    "application/x-yaml",
    "application/toml",
    "application/javascript",
    "application/typescript",
    "application/x-sh",
];

/// 判定"这是文本文件"的扩展名。
///
/// 只看 mime 不够：`file_selector` 与系统拖拽常给出 `application/octet-stream`，
/// 而一份 `.md` 的正文恰恰是最该给模型看的东西。
const TEXT_EXTENSIONS: &[&str] = &[
    "md", "markdown", "txt", "json", "yaml", "yml", "toml", "ini", "csv", "log", "xml", "html",
    "htm", "css", "js", "jsx", "ts", "tsx", "dart", "rs", "go", "py", "rb", "java", "kt", "swift",
    "c", "h", "cc", "hpp", "cpp", "m", "mm", "sh", "zsh", "bash", "ps1", "sql", "gradle", "conf",
];

#[derive(Debug, thiserror::Error)]
pub enum AttachmentError {
    #[error("数据库错误: {0}")]
    Db(#[from] sqlx::Error),
    #[error("附件不存在")]
    NotFound,
    #[error("附件内容为空")]
    Empty,
    #[error("附件超过上限: {bytes} > {max} 字节")]
    TooLarge { bytes: i64, max: i64 },
    #[error("附件数量超过上限: {count} > {max}")]
    TooMany { count: usize, max: usize },
    #[error("附件已经被另一条消息使用")]
    AlreadyBound,
    #[error("附件不属于本设备")]
    NotOwned,
    #[error("附件参数非法: {0}")]
    Invalid(&'static str),
    #[error("附件存取失败: {0}")]
    Store(String),
}

impl From<StoreError> for AttachmentError {
    fn from(err: StoreError) -> Self {
        AttachmentError::Store(err.to_string())
    }
}

/// 一行附件记录。
#[derive(Debug, sqlx::FromRow)]
struct AttachmentRow {
    id: String,
    device_id: String,
    message_id: Option<String>,
    name: String,
    kind: String,
    mime: String,
    bytes: i64,
    path: String,
    width: Option<i64>,
    height: Option<i64>,
}

impl AttachmentRow {
    fn to_attachment(&self) -> Attachment {
        Attachment {
            id: self.id.clone(),
            name: self.name.clone(),
            kind: self.kind.clone(),
            mime: self.mime.clone(),
            bytes: self.bytes,
            width: self.width.and_then(|value| u32::try_from(value).ok()),
            height: self.height.and_then(|value| u32::try_from(value).ok()),
        }
    }
}

/// 查询用的列清单。写成字面量而不是 `format!` 拼出来：sqlx 只接受静态 SQL，
/// 动态字符串在编译期就被拒（见 `SqlSafeStr`）。
const SELECT_ONE: &str =
    "SELECT id, device_id, message_id, name, kind, mime, bytes, path, width, height \
     FROM attachments WHERE id = ?";

/// 由 mime 判定附件种类。客户端只认 `kind`，两端口径必须一致。
pub fn kind_of(mime: &str) -> &'static str {
    if mime.trim().to_ascii_lowercase().starts_with("image/") {
        "image"
    } else {
        "file"
    }
}

/// 归一化展示用的文件名。
///
/// 只留最后一段：客户端在别的平台可能把整个路径当名字传上来，
/// 而名字会进 `content_json` 与提示词，不能让它带上目录结构。
pub fn sanitize_name(raw: Option<&str>) -> String {
    let raw = raw.unwrap_or_default().trim();
    let base = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(raw)
        .trim()
        .trim_start_matches('.');
    if base.is_empty() {
        return "附件".to_string();
    }
    base.chars().take(MAX_NAME_CHARS).collect()
}

/// 登记一次上传：落文件 + 写一行，返回给客户端的元信息。
///
/// 顺序是"先写文件再写库"：反过来会出现"库里有一行、文件还没落"的窗口，
/// 那个窗口里的下载就是 500。
pub async fn record_upload(
    state: &AppState,
    device_id: &str,
    name: &str,
    mime: &str,
    width: Option<u32>,
    height: Option<u32>,
    bytes: &[u8],
) -> Result<Attachment, AttachmentError> {
    if bytes.is_empty() {
        return Err(AttachmentError::Empty);
    }
    let bytes_len = i64::try_from(bytes.len()).unwrap_or(i64::MAX);
    let max = state.config.attachment.max_bytes;
    if bytes_len > max {
        return Err(AttachmentError::TooLarge {
            bytes: bytes_len,
            max,
        });
    }

    let id = new_id("att");
    let kind = kind_of(mime);
    let store = ArtifactStore::new(state.config.attachments_dir());
    let (path, _) = store.save_bytes(UPLOAD_DIR, &id, Some(mime), bytes).await?;

    let created_at = now_ms();
    sqlx::query(
        "INSERT INTO attachments (id, device_id, conversation_id, message_id, name, kind, mime, \
                bytes, path, width, height, created_at) \
         VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&id)
    .bind(device_id)
    .bind(name)
    .bind(kind)
    .bind(mime)
    .bind(bytes_len)
    .bind(&path)
    .bind(width.map(i64::from))
    .bind(height.map(i64::from))
    .bind(created_at)
    .execute(&state.pool)
    .await?;

    tracing::debug!(
        attachment_id = %id,
        mime = %mime,
        bytes = bytes_len,
        "附件已登记"
    );

    Ok(Attachment {
        id,
        name: name.to_string(),
        kind: kind.to_string(),
        mime: mime.to_string(),
        bytes: bytes_len,
        width,
        height,
    })
}

/// 读取一个附件的元信息与正文。
pub async fn body_of(state: &AppState, id: &str) -> Result<(Attachment, Vec<u8>), AttachmentError> {
    let row = lookup(&state.pool, id)
        .await?
        .ok_or(AttachmentError::NotFound)?;

    let store = ArtifactStore::new(state.config.attachments_dir());
    let bytes = match store.read(&row.path).await {
        Ok(bytes) => bytes,
        Err(StoreError::Missing) => {
            tracing::warn!(attachment_id = %id, "附件记录存在但文件缺失");
            return Err(AttachmentError::NotFound);
        }
        Err(err) => return Err(err.into()),
    };

    Ok((row.to_attachment(), bytes))
}

async fn lookup(pool: &SqlitePool, id: &str) -> Result<Option<AttachmentRow>, AttachmentError> {
    let row = sqlx::query_as::<_, AttachmentRow>(SELECT_ONE)
        .bind(id)
        .fetch_optional(pool)
        .await?;
    Ok(row)
}

/// 校验并取出这一轮要发送的附件。
///
/// 三个约束一起判：数量、存在、属于本设备且还没被别的消息用过。
/// 判完才允许落消息——消息一旦写进去，客户端就已经看到"发出去了"。
pub async fn claim(
    state: &AppState,
    device_id: &str,
    ids: &[String],
) -> Result<Vec<Attachment>, AttachmentError> {
    let max = state.config.attachment.max_count;
    if ids.len() > max {
        return Err(AttachmentError::TooMany {
            count: ids.len(),
            max,
        });
    }

    let mut claimed = Vec::with_capacity(ids.len());
    let mut seen = std::collections::BTreeSet::new();
    for id in ids {
        // 同一个 id 传两次只算一枚：客户端重排 chip 时可能带出重复项。
        if !seen.insert(id.as_str()) {
            continue;
        }
        let row = lookup(&state.pool, id)
            .await?
            .ok_or(AttachmentError::NotFound)?;
        if row.device_id != device_id {
            return Err(AttachmentError::NotOwned);
        }
        if row.message_id.is_some() {
            return Err(AttachmentError::AlreadyBound);
        }
        claimed.push(row.to_attachment());
    }

    Ok(claimed)
}

/// 把已登记的附件绑到一条消息上。
///
/// `WHERE message_id IS NULL` 让"两个请求同时用同一枚附件"只成功一个，
/// 不需要额外的读-判断-写窗口。
pub async fn bind(
    pool: &SqlitePool,
    ids: &[String],
    conversation_id: &str,
    message_id: &str,
) -> Result<(), AttachmentError> {
    for id in ids {
        let affected = sqlx::query(
            "UPDATE attachments SET conversation_id = ?, message_id = ? \
             WHERE id = ? AND message_id IS NULL",
        )
        .bind(conversation_id)
        .bind(message_id)
        .bind(id)
        .execute(pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Err(AttachmentError::AlreadyBound);
        }
    }
    Ok(())
}

/// 删除一枚**还没发送**的附件（用户把 chip 删掉时清文件）。
///
/// 已绑到消息上的拒绝：那条历史消息里的 chip 还要能点开。
pub async fn delete(state: &AppState, device_id: &str, id: &str) -> Result<(), AttachmentError> {
    let row = lookup(&state.pool, id)
        .await?
        .ok_or(AttachmentError::NotFound)?;
    if row.device_id != device_id {
        return Err(AttachmentError::NotOwned);
    }
    if row.message_id.is_some() {
        return Err(AttachmentError::AlreadyBound);
    }

    let store = ArtifactStore::new(state.config.attachments_dir());
    // 文件先删：库行没了而文件还在，是最难发现的一种泄漏。
    store.remove(&row.path).await?;
    sqlx::query("DELETE FROM attachments WHERE id = ? AND message_id IS NULL")
        .bind(id)
        .execute(&state.pool)
        .await?;
    Ok(())
}

/// 清掉超过 TTL 还没被发送的附件，返回清理条数。
///
/// 只在启动时跑一次：这是一件"迟早要做、但不急"的事，
/// 放进 ticker 每 5 秒扫一遍库不值当。
pub async fn purge_orphans(state: &AppState) -> Result<usize, AttachmentError> {
    let ttl_ms = i64::from(state.config.attachment.orphan_ttl_hours) * 60 * 60 * 1000;
    let cutoff = now_ms() - ttl_ms;

    let rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT id, path FROM attachments WHERE message_id IS NULL AND created_at < ?",
    )
    .bind(cutoff)
    .fetch_all(&state.pool)
    .await?;

    let store = ArtifactStore::new(state.config.attachments_dir());
    let mut removed = 0usize;
    for (id, path) in rows {
        // 文件删不掉也照样删行：行留着只会让下一次启动再试一遍，而用户看不到它。
        if let Err(err) = store.remove(&path).await {
            tracing::warn!(attachment_id = %id, %err, "清理孤儿附件文件失败");
        }
        sqlx::query("DELETE FROM attachments WHERE id = ? AND message_id IS NULL")
            .bind(&id)
            .execute(&state.pool)
            .await?;
        removed += 1;
    }

    Ok(removed)
}

/// 从消息的 `content_json` 里取出附件元信息。
///
/// 解析失败一律当"没有附件"：老数据没有这个键，形状不对也只该少显示几枚 chip，
/// 不该让整条历史查询失败。
pub fn from_content_json(content_json: &str) -> Vec<Attachment> {
    serde_json::from_str::<serde_json::Value>(content_json)
        .ok()
        .and_then(|value| value.get("attachments").cloned())
        .and_then(|items| serde_json::from_value::<Vec<Attachment>>(items).ok())
        .unwrap_or_default()
}

/// 历史消息里那行附件注记。没有附件时返回 `None`。
///
/// 历史里的附件正文不重发（一张图 base64 后几 MB），只留一份名字清单，
/// 让模型知道"那轮用户其实给了文件"，而不是把这一轮当成凭空提问。
pub fn history_note(attachments: &[Attachment]) -> Option<String> {
    if attachments.is_empty() {
        return None;
    }
    let names = attachments
        .iter()
        .map(|attachment| attachment.name.as_str())
        .collect::<Vec<_>>()
        .join("、");
    Some(format!("[附件：{names}]"))
}

/// 把本轮附件写进上下文：图片走多模态、文本类内联摘录、其余只给说明。
///
/// 只处理**最后一条用户消息**——那是刚刚落库的这一轮。历史消息不重复注入正文，
/// 否则第三轮对话起，每轮都在重发第一轮的整份文件。
pub async fn decorate_turn(
    state: &AppState,
    messages: &mut [ChatMessage],
    attachments: &[Attachment],
) {
    if attachments.is_empty() {
        return;
    }
    let Some(index) = messages.iter().rposition(|m| m.role == ChatRole::User) else {
        return;
    };

    let config = &state.config.attachment;
    let vision = state.active_model().vision;
    let store = ArtifactStore::new(state.config.attachments_dir());
    let mut lines: Vec<String> = Vec::new();
    let mut images: Vec<String> = Vec::new();
    let mut budget = config.prompt_budget_chars;

    for attachment in attachments {
        let path = relative_path(attachment);

        if attachment.is_image() {
            if !vision {
                lines.push(format!(
                    "（附件 {}：图片，当前模型未开启读图，只能看到文件名；\
                     需要看图请在客户端设置 › 能力 › 模型里给当前配置打开「支持读图」，\
                     并确认该模型支持 image_url）",
                    attachment.name
                ));
                continue;
            }
            if attachment.bytes > config.inline_image_max_bytes {
                lines.push(format!(
                    "（附件 {}：图片 {}，超过单张内联上限 {}，未送进模型）",
                    attachment.name,
                    human_size(attachment.bytes),
                    human_size(config.inline_image_max_bytes),
                ));
                continue;
            }
            match store.read(&path).await {
                Ok(bytes) => {
                    let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                    images.push(format!("data:{};base64,{encoded}", attachment.mime));
                }
                Err(err) => {
                    tracing::warn!(
                        attachment_id = %attachment.id,
                        %err,
                        "读取图片附件失败，本轮跳过该图"
                    );
                    lines.push(format!(
                        "（附件 {}：图片读取失败，未送进模型）",
                        attachment.name
                    ));
                }
            }
            continue;
        }

        if !is_textual(attachment) {
            lines.push(format!(
                "（附件 {}：{}，{}，未内联正文）",
                attachment.name,
                attachment.mime,
                human_size(attachment.bytes),
            ));
            continue;
        }

        match store.read(&path).await {
            Ok(bytes) => match decode_excerpt(&bytes, config.text_excerpt_bytes) {
                Some(excerpt) => {
                    let chars = excerpt.chars().count();
                    if chars > budget {
                        // 预算用尽：给出名字但不再贴正文，用户能从 chip 上看出是哪一份。
                        lines.push(format!(
                            "（附件 {}：正文过长，本轮上下文字数预算已用尽）",
                            attachment.name
                        ));
                        continue;
                    }
                    budget -= chars;
                    lines.push(format!("### {}\n```\n{}\n```", attachment.name, excerpt));
                }
                None => lines.push(format!(
                    "（附件 {}：二进制内容，未内联正文）",
                    attachment.name
                )),
            },
            Err(err) => {
                tracing::warn!(
                    attachment_id = %attachment.id,
                    %err,
                    "读取文本附件失败，本轮跳过正文"
                );
                lines.push(format!(
                    "（附件 {}：读取失败，未内联正文）",
                    attachment.name
                ));
            }
        }
    }

    if lines.is_empty() && images.is_empty() {
        return;
    }

    let message = &mut messages[index];
    if !lines.is_empty() {
        message.content.push_str("\n\n");
        message.content.push_str(&lines.join("\n\n"));
    }
    message.images = images;
}

/// 附件文件在 attachments 根下的相对路径。
///
/// 与 [`record_upload`] 的落盘规则必须是同一份：库里那一列只用于清理与排障，
/// 注入路径靠 id + mime 推回来，避免为了拼路径多一次查询。
fn relative_path(attachment: &Attachment) -> String {
    format!(
        "{UPLOAD_DIR}/{}{}",
        attachment.id,
        extension_for(Some(&attachment.mime))
    )
}

fn is_textual(attachment: &Attachment) -> bool {
    let mime = attachment.mime.trim().to_ascii_lowercase();
    if mime.starts_with("text/") || TEXT_MIMES.contains(&mime.as_str()) {
        return true;
    }
    let extension = attachment
        .name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default();
    TEXT_EXTENSIONS.contains(&extension.as_str())
}

/// 把字节解成"能读的一段文本"；不像文本就返回 `None`。
///
/// 判据是"开头没有 NUL 字节"：真正的二进制（图片、压缩包、PDF）几乎必然有，
/// 而 UTF-8 文本里不该出现。宁可漏判一个怪文件，也不要往提示词里塞乱码。
fn decode_excerpt(bytes: &[u8], limit: usize) -> Option<String> {
    let probe = &bytes[..bytes.len().min(4096)];
    if probe.contains(&0) {
        return None;
    }

    let slice = &bytes[..bytes.len().min(limit.saturating_mul(4).max(limit))];
    let text = String::from_utf8_lossy(slice);
    let mut taken: String = text.chars().take(limit).collect();
    if taken.trim().is_empty() {
        return None;
    }
    if text.chars().count() > limit {
        taken.push_str("\n…（其余内容已截断）");
    }
    Some(taken)
}

/// 人类可读的大小。提示词与错误文案共用一份口径。
pub fn human_size(bytes: i64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    let value = bytes as f64;
    if value >= MB {
        format!("{:.1} MB", value / MB)
    } else if value >= KB {
        format!("{:.0} KB", value / KB)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_follows_mime() {
        assert_eq!(kind_of("image/png"), "image");
        assert_eq!(kind_of("IMAGE/JPEG"), "image");
        assert_eq!(kind_of("application/pdf"), "file");
        assert_eq!(kind_of(""), "file");
    }

    #[test]
    fn name_is_reduced_to_a_basename() {
        assert_eq!(sanitize_name(Some("api.md")), "api.md");
        assert_eq!(sanitize_name(Some("/tmp/a/b/api.md")), "api.md");
        assert_eq!(sanitize_name(Some(r"C:\x\y.png")), "y.png");
        assert_eq!(sanitize_name(Some("   ")), "附件");
        assert_eq!(sanitize_name(None), "附件");
        // 前导点会被去掉：`.` 开头的名字在部分平台上是隐藏文件，不适合当展示名。
        assert_eq!(sanitize_name(Some(".gitignore")), "gitignore");
    }

    #[test]
    fn old_messages_parse_as_no_attachments() {
        assert!(from_content_json(r#"{"text":"旧消息"}"#).is_empty());
        assert!(from_content_json("not-json").is_empty());
        assert!(from_content_json(r#"{"attachments":"oops"}"#).is_empty());
    }

    #[test]
    fn attachments_parse_from_content_json() {
        let parsed = from_content_json(
            r#"{"text":"看看这个","attachments":[{"id":"att_1","name":"api.md","kind":"file",
                "mime":"text/markdown","bytes":12}]}"#,
        );
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].name, "api.md");
        assert!(!parsed[0].is_image());
        assert!(parsed[0].width.is_none());
    }

    #[test]
    fn history_note_lists_names() {
        let attachments = vec![
            Attachment {
                id: "att_1".into(),
                name: "api.md".into(),
                kind: "file".into(),
                mime: "text/markdown".into(),
                bytes: 1,
                width: None,
                height: None,
            },
            Attachment {
                id: "att_2".into(),
                name: "shot.png".into(),
                kind: "image".into(),
                mime: "image/png".into(),
                bytes: 2,
                width: Some(10),
                height: Some(20),
            },
        ];
        assert_eq!(
            history_note(&attachments).as_deref(),
            Some("[附件：api.md、shot.png]")
        );
        assert!(history_note(&[]).is_none());
    }

    #[test]
    fn binary_content_is_not_decoded() {
        let png = [0x89u8, b'P', b'N', b'G', 0x0D, 0x00, 0x1A];
        assert!(decode_excerpt(&png, 1024).is_none());
    }

    #[test]
    fn text_is_truncated_with_a_marker() {
        let excerpt = decode_excerpt("一二三四五".as_bytes(), 3).expect("应识别为文本");
        assert!(excerpt.starts_with("一二三"));
        assert!(excerpt.ends_with("（其余内容已截断）"));
    }

    #[test]
    fn text_detection_covers_code_extensions() {
        let attachment = Attachment {
            id: "att_1".into(),
            name: "ARCHITECTURE.MD".into(),
            kind: "file".into(),
            mime: "application/octet-stream".into(),
            bytes: 1,
            width: None,
            height: None,
        };
        assert!(is_textual(&attachment));
    }

    #[test]
    fn human_size_reads_naturally() {
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(2048), "2 KB");
        assert_eq!(human_size(3 * 1024 * 1024), "3.0 MB");
    }
}
