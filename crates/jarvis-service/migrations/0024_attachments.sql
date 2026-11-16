-- 用户在输入框里附上的文件 / 图片。
--
-- 一生分两段：上传时就落一行（`message_id` 为空），发送时才绑到消息上。
-- 这样空态页不必"先建会话再上传"——上传与会话解耦，发送时按 id 绑定。
--
-- 正文不进库：文件落在 {data_dir}/attachments 下，与媒体产物共用同一套
-- "库里只记相对路径"的做法。客户端永远拿不到也传不进路径。
--
-- 为什么不复用 media_assets：那张表的方向是反的（模型生成给用户看），
-- 而且它的 conversation_id 非空——上传时还没有会话。

CREATE TABLE attachments (
    id              TEXT PRIMARY KEY,
    -- 上传它的设备。只有同一台设备能把 id 绑到消息上。
    device_id       TEXT NOT NULL,
    -- 发送后才有值；为空表示"还没被任何消息引用"。
    conversation_id TEXT,
    message_id      TEXT,
    -- 原始文件名，仅用于展示。
    name            TEXT NOT NULL,
    -- image | file
    kind            TEXT NOT NULL,
    mime            TEXT NOT NULL,
    bytes           INTEGER NOT NULL,
    -- 相对 attachments 目录根的路径，绝对路径一律不接受。
    path            TEXT NOT NULL,
    width           INTEGER,
    height          INTEGER,
    created_at      INTEGER NOT NULL
);

CREATE INDEX idx_attachments_message ON attachments (message_id);

-- 孤儿清理按上传时间扫：`message_id IS NULL` 的那批是"用户删了 chip 却没发"。
CREATE INDEX idx_attachments_orphan ON attachments (created_at);
