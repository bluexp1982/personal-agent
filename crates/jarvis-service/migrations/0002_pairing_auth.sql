-- M2：配对票据与会话令牌。
--
-- 约定：
-- - 配对码与令牌都只存哈希（sha256 十六进制），数据库泄露不等于可直接使用；
-- - 「同一时刻只允许一个有效票据」由生成列 + 部分唯一索引在数据库层保证，
--   不依赖应用层先查后写（并发下会漏）；
-- - 时间统一 Unix 毫秒。

CREATE TABLE pairing_requests (
    id            TEXT PRIMARY KEY,
    code_hash     TEXT NOT NULL,
    device_name   TEXT,
    platform      TEXT,
    client_pubkey TEXT,
    status        TEXT NOT NULL,
    attempts      INTEGER NOT NULL DEFAULT 0,
    approved_by   TEXT,
    created_at    INTEGER NOT NULL,
    expires_at    INTEGER NOT NULL,
    -- 活跃票据为 1，其余为 NULL；唯一索引对 NULL 不去重，因此最多一条活跃记录。
    active        INTEGER GENERATED ALWAYS AS (
        CASE WHEN status IN ('pending', 'awaiting_confirmation') THEN 1 ELSE NULL END
    ) VIRTUAL
);

CREATE UNIQUE INDEX idx_pairing_active ON pairing_requests (active);
CREATE INDEX idx_pairing_expires ON pairing_requests (status, expires_at);

CREATE TABLE sessions (
    token_hash  TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    revoked_at  INTEGER,
    FOREIGN KEY (device_id) REFERENCES devices (id) ON DELETE CASCADE
);

CREATE INDEX idx_sessions_device ON sessions (device_id);
CREATE INDEX idx_sessions_expires ON sessions (expires_at);
