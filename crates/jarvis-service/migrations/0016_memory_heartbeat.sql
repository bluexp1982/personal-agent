-- 心跳状态与提醒队列。
--
-- 状态用 key/value 而不是加列：心跳的"记住上次跑到哪"只有几种，
-- 加列会逼着每次改调度逻辑都动迁移。

CREATE TABLE memory_heartbeat_state (
    -- last_scan_at / last_nightly_at / settings
    key        TEXT PRIMARY KEY,
    value_json TEXT NOT NULL DEFAULT '{}',
    updated_at INTEGER NOT NULL
);

CREATE TABLE memory_notifications (
    id           TEXT PRIMARY KEY,
    -- due / todo / digest_report
    category     TEXT NOT NULL,
    -- 去重键：category + 主体 + 时间窗（同一事项 24 小时内只提醒一次）
    dedupe_key   TEXT NOT NULL,
    memory_id    TEXT,
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    score        REAL NOT NULL,
    -- 四因子打分明细，用于事后解释"为什么先推这条"
    factors_json TEXT NOT NULL,
    -- queued / delivered / muted / expired
    status       TEXT NOT NULL,
    deliver_at   INTEGER,
    message_id   TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

CREATE UNIQUE INDEX idx_notifications_dedupe ON memory_notifications (dedupe_key);
CREATE INDEX idx_notifications_status ON memory_notifications (status, score DESC, deliver_at);
