//! 与 `jarvis-service` 的连接。
//!
//! worker 主动连接服务端的本地套接字：服务端掌握生命周期，worker 只管重连。
//! 单连接串行读写，避免多任务同时写导致帧交错。

use std::path::Path;

use protocol::{Envelope, IpcMessage};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

/// 发送端句柄，可克隆给多个任务共享。
#[derive(Clone, Debug)]
pub(crate) struct Client {
    tx: mpsc::Sender<IpcMessage>,
}

impl Client {
    /// 发送一条消息。连接已断开时返回 false。
    pub(crate) async fn send(&self, message: IpcMessage) -> bool {
        self.tx.send(message).await.is_ok()
    }

    /// 只给测试用：不建连接，直接拿一个发送端当客户端。
    #[cfg(test)]
    pub(crate) fn for_test(tx: mpsc::Sender<IpcMessage>) -> Self {
        Self { tx }
    }
}

/// 一条已建立的连接：客户端句柄 + 读端。
#[derive(Debug)]
pub(crate) struct Connection {
    pub(crate) client: Client,
    reader: BufReader<OwnedReadHalf>,
    writer: tokio::task::JoinHandle<()>,
}

impl Connection {
    pub(crate) async fn connect(socket: &Path) -> std::io::Result<Self> {
        let stream = UnixStream::connect(socket).await?;
        let (read_half, write_half) = stream.into_split();

        let (tx, rx) = mpsc::channel::<IpcMessage>(64);
        let writer = tokio::spawn(write_loop(write_half, rx));

        Ok(Self {
            client: Client { tx },
            reader: BufReader::new(read_half),
            writer,
        })
    }

    /// 读取下一条消息。返回 `None` 表示连接关闭。
    ///
    /// 无法解析的行只记 warn 并跳过：单条坏消息不应让整个进程退出。
    pub(crate) async fn next(&mut self) -> Option<IpcMessage> {
        loop {
            let mut line = String::new();
            match self.reader.read_line(&mut line).await {
                Ok(0) => return None,
                Ok(_) => {}
                Err(err) => {
                    tracing::warn!(%err, "读取 IPC 失败");
                    return None;
                }
            }

            if line.trim().is_empty() {
                continue;
            }

            match Envelope::from_line(&line) {
                Ok(envelope) => return Some(envelope.message),
                Err(err) => {
                    tracing::warn!(%err, "丢弃无法解析的 IPC 消息");
                    continue;
                }
            }
        }
    }

    /// 主动断开写端（进程退出前调用，避免残留任务）。
    pub(crate) fn close(&self) {
        self.writer.abort();
    }
}

async fn write_loop(mut write_half: OwnedWriteHalf, mut rx: mpsc::Receiver<IpcMessage>) {
    while let Some(message) = rx.recv().await {
        let envelope = Envelope::new(message);
        let line = match envelope.to_line() {
            Ok(line) => line,
            Err(err) => {
                tracing::error!(%err, "IPC 序列化失败");
                continue;
            }
        };

        if write_half.write_all(line.as_bytes()).await.is_err()
            || write_half.write_all(b"\n").await.is_err()
            || write_half.flush().await.is_err()
        {
            tracing::warn!("与服务端的连接已断开");
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use protocol::{IpcMessage, IPC_VERSION};
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn socket_roundtrip_over_unix() {
        let dir = std::env::temp_dir().join(format!(
            "pa-ipc-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        let socket = dir.join("test.sock");

        let listener = tokio::net::UnixListener::bind(&socket).expect("绑定失败");
        let socket_for_client = socket.clone();

        let client_task = tokio::spawn(async move {
            let connection = super::Connection::connect(&socket_for_client)
                .await
                .expect("连接失败");
            assert!(
                connection
                    .client
                    .send(IpcMessage::Heartbeat {
                        active_tasks: Vec::new()
                    })
                    .await
            );
            // 等对端回一条，确认读路径可用
            let mut connection = connection;
            let message = connection.next().await.expect("应收到回复");
            assert!(matches!(message, IpcMessage::Shutdown));
            connection.close();
        });

        let (stream, _) = listener.accept().await.expect("接受失败");
        let (read_half, mut write_half) = stream.into_split();
        let mut reader = tokio::io::BufReader::new(read_half);
        let mut line = String::new();
        tokio::io::AsyncBufReadExt::read_line(&mut reader, &mut line)
            .await
            .expect("读取失败");

        let envelope = protocol::Envelope::from_line(line.trim()).expect("解析失败");
        assert_eq!(envelope.v, IPC_VERSION);
        assert!(matches!(envelope.message, IpcMessage::Heartbeat { .. }));

        let reply = protocol::Envelope::new(IpcMessage::Shutdown)
            .to_line()
            .expect("序列化失败");
        write_half
            .write_all(format!("{reply}\n").as_bytes())
            .await
            .expect("写失败");
        write_half.flush().await.expect("flush 失败");

        client_task.await.expect("客户端任务失败");
        let _ = std::fs::remove_file(&socket);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
