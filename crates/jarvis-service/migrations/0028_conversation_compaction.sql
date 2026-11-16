-- 会话上下文压缩记录。
--
-- 每次尝试一行，失败也留痕：
--   * `ready`   一次成功压缩。`upto_seq` 是"折叠到哪"的位置锚点：装配时只送
--               `seq > upto_seq` 的消息，再前置一条摘要。
--   * `failed`  一次失败的尝试。`upto_seq` 与 `summary` 为空，不参与装配，
--               只用于在客户端回答"上次为什么没有摘要"。
--   * `pending` 正在跑。服务重启遗留的会被标成 `failed`，而不是删掉。
--
-- 为什么失败不覆盖旧行：失败的覆盖成功的，会让"摘要为什么消失"无从排查；
-- 成功的覆盖失败的，又会让"上次为什么失败"丢证据。摘要可以重算，
-- 但"当时发生了什么"不能重算。
--
-- 时间戳单位与其它表一致：毫秒。
CREATE TABLE conversation_compactions (
    id                TEXT PRIMARY KEY,
    conversation_id   TEXT NOT NULL,
    -- pending | ready | failed
    status            TEXT NOT NULL,
    -- 仅 ready：折叠到的消息 seq（含）。装配只取 seq > upto_seq 的消息。
    upto_seq          INTEGER,
    -- 仅 ready：摘要正文。不代表原文被删——原文永远留在 messages 里。
    summary           TEXT,
    -- 本次折叠掉多少条消息。
    source_messages   INTEGER NOT NULL DEFAULT 0,
    model             TEXT NOT NULL DEFAULT '',
    -- 压缩调用信封：口径与 messages 表一致，便于把整理成本单独算清。
    max_tokens        INTEGER,
    prompt_tokens     INTEGER,
    completion_tokens INTEGER,
    tokens_estimated  INTEGER NOT NULL DEFAULT 0,
    elapsed_ms        INTEGER,
    -- 仅 failed：一句面向用户的原因。
    error             TEXT,
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
);

-- 同一位置只允许成功一次：重算必须往更后面推，否则"摘要覆盖了谁"说不清。
-- 失败行的 upto_seq 为 NULL，不受约束（SQLite 里并列多个 NULL 不冲突）。
CREATE UNIQUE INDEX idx_conversation_compactions_upto
    ON conversation_compactions (conversation_id, upto_seq)
    WHERE upto_seq IS NOT NULL;

-- 装配取"最新一条 ready"，抽屉取"最近一次失败"，各一个索引。
CREATE INDEX idx_conversation_compactions_ready
    ON conversation_compactions (conversation_id, status, upto_seq DESC);
CREATE INDEX idx_conversation_compactions_recent
    ON conversation_compactions (conversation_id, created_at DESC);

-- 用户关掉压缩是会话级偏好，不是一次压缩事件：存在会话行上。
-- 0 = 跟随服务端配置；1 = 这个会话不压缩（DELETE /compaction 写入，
-- POST /compaction 时清零）。装配与后台触发都要看这一列。
ALTER TABLE conversations ADD COLUMN compaction_disabled INTEGER NOT NULL DEFAULT 0;
