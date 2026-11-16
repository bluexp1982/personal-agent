-- 会话侧文件生成：覆盖已有文件前要用户确认，待写内容先落这张表。
--
-- 为什么不用内存：服务重启或客户端断线后，用户点"覆盖"必须还能写；
-- 为什么正文要在这里存一份：确认动作是确定性的，不需要模型重新生成一遍。
-- 决策完成后立刻清空 content，库里不留两份正文。

CREATE TABLE file_write_requests (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    -- 触发这次写入的 assistant 消息。为空表示消息还没落库（正常流程里不会）。
    message_id      TEXT,
    -- project | draft
    scope           TEXT NOT NULL,
    -- 根内相对路径，绝对路径一律不接受。
    path            TEXT NOT NULL,
    content         TEXT NOT NULL,
    -- 新内容字节数。
    bytes           INTEGER NOT NULL,
    -- 待覆盖文件的字节数；新建时为 0。
    existing_bytes  INTEGER NOT NULL DEFAULT 0,
    -- pending | written | rejected | expired | failed | superseded
    status          TEXT NOT NULL,
    backup_path     TEXT,
    error           TEXT,
    created_at      INTEGER NOT NULL,
    decided_at      INTEGER,
    expires_at      INTEGER NOT NULL
);

CREATE INDEX idx_file_writes_conversation
    ON file_write_requests (conversation_id, created_at DESC);

-- 过期清理靠这条：按状态与到期时间扫，不给后台任务开口子。
CREATE INDEX idx_file_writes_pending
    ON file_write_requests (status, expires_at);
