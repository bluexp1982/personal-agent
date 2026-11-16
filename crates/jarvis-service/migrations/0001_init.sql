-- v1 初始表结构。
--
-- 约定：
-- - 时间统一用 Unix 毫秒时间戳（INTEGER），避免 SQLite 的日期字符串解析差异；
-- - 枚举值用 TEXT 存，服务端以 Rust 枚举校验，不用 CHECK 约束锁死（新增枚举值不需要迁移）；
-- - 外键默认开启（连接时设置 PRAGMA foreign_keys = ON）；
-- - 复合索引的列顺序与 cursor 分页的排序键一致：先过滤列，再 (时间 DESC, id DESC)。

CREATE TABLE devices (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    platform      TEXT NOT NULL,
    pubkey        TEXT NOT NULL UNIQUE,
    approved_by   TEXT,
    paired_at     INTEGER NOT NULL,
    last_seen_at  INTEGER,
    revoked_at    INTEGER
);

CREATE INDEX idx_devices_revoked ON devices (revoked_at);

CREATE TABLE credentials (
    id            TEXT PRIMARY KEY,
    platform      TEXT NOT NULL UNIQUE,
    status        TEXT NOT NULL,
    secret_ref    TEXT NOT NULL,
    last_used_at  INTEGER,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

CREATE TABLE conversations (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    mode        TEXT NOT NULL DEFAULT 'text',
    device_id   TEXT,
    archived    INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    FOREIGN KEY (device_id) REFERENCES devices (id) ON DELETE SET NULL
);

CREATE INDEX idx_conversations_cursor ON conversations (archived, updated_at DESC, id DESC);

CREATE TABLE messages (
    id               TEXT PRIMARY KEY,
    conversation_id  TEXT NOT NULL,
    role             TEXT NOT NULL,
    content_json     TEXT NOT NULL,
    task_id          TEXT,
    created_at       INTEGER NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
);

CREATE INDEX idx_messages_cursor ON messages (conversation_id, created_at DESC, id DESC);
CREATE INDEX idx_messages_task ON messages (task_id);

CREATE TABLE tasks (
    id               TEXT PRIMARY KEY,
    conversation_id  TEXT NOT NULL,
    type             TEXT NOT NULL,
    skill            TEXT,
    skill_version    TEXT,
    state            TEXT NOT NULL,
    plan_json        TEXT,
    idempotency_key  TEXT UNIQUE,
    retry_count      INTEGER NOT NULL DEFAULT 0,
    error_code       TEXT,
    error_hint       TEXT,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
);

CREATE INDEX idx_tasks_state ON tasks (state, updated_at DESC, id DESC);
CREATE INDEX idx_tasks_conversation ON tasks (conversation_id, updated_at DESC);

CREATE TABLE task_steps (
    id           TEXT PRIMARY KEY,
    task_id      TEXT NOT NULL,
    seq          INTEGER NOT NULL,
    name         TEXT NOT NULL,
    state        TEXT NOT NULL,
    output_json  TEXT,
    started_at   INTEGER,
    ended_at     INTEGER,
    UNIQUE (task_id, seq),
    FOREIGN KEY (task_id) REFERENCES tasks (id) ON DELETE CASCADE
);

CREATE TABLE approvals (
    id                TEXT PRIMARY KEY,
    task_id           TEXT NOT NULL,
    action            TEXT NOT NULL,
    target            TEXT,
    impact_json       TEXT,
    previews_json     TEXT,
    expires_at        INTEGER NOT NULL,
    decision          TEXT NOT NULL DEFAULT 'pending',
    decided_at        INTEGER,
    decided_by_device TEXT,
    created_at        INTEGER NOT NULL,
    FOREIGN KEY (task_id) REFERENCES tasks (id) ON DELETE CASCADE
);

CREATE INDEX idx_approvals_pending ON approvals (decision, expires_at);
CREATE INDEX idx_approvals_task ON approvals (task_id);

CREATE TABLE artifacts (
    id          TEXT PRIMARY KEY,
    task_id     TEXT NOT NULL,
    kind        TEXT NOT NULL,
    path        TEXT NOT NULL,
    size        INTEGER NOT NULL,
    mime        TEXT,
    created_at  INTEGER NOT NULL,
    FOREIGN KEY (task_id) REFERENCES tasks (id) ON DELETE CASCADE
);

CREATE INDEX idx_artifacts_task ON artifacts (task_id);

CREATE TABLE audit_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,
    trace_id     TEXT NOT NULL,
    actor        TEXT NOT NULL,
    action       TEXT NOT NULL,
    target       TEXT,
    result       TEXT NOT NULL,
    detail_json  TEXT
);

CREATE INDEX idx_audit_ts ON audit_log (ts DESC);
CREATE INDEX idx_audit_trace ON audit_log (trace_id);
