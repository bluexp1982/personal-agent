-- 记忆核心：正文、证据、召回日志、digest 快照、抽取预算、FTS5 索引。
--
-- 约定沿用 0001：时间用 Unix 毫秒 INTEGER；枚举用 TEXT 由 Rust 校验（不写 CHECK，
-- 新增取值不需要迁移）；复合索引列顺序与过滤条件、cursor 排序键一致。
--
-- 迁移只前滚，不写 down：SQLite 删表会丢数据，出问题用新的迁移修正。

CREATE TABLE memories (
    id              TEXT PRIMARY KEY,
    -- profile / preference / event / project
    kind            TEXT NOT NULL,
    -- subjective / objective
    pipeline        TEXT NOT NULL,
    -- candidate / active / stale / archived / deleted
    status          TEXT NOT NULL,
    -- global / workspace
    scope           TEXT NOT NULL,
    workspace_id    TEXT,
    -- normal / private（secret 在写入阶段就被拒绝，不入库）
    sensitivity     TEXT NOT NULL DEFAULT 'normal',
    content         TEXT NOT NULL,
    -- 检索用分词串：content + subject + predicate 的 bigram 拼接，写入时算好
    content_tokens  TEXT NOT NULL DEFAULT '',
    subject         TEXT,
    subject_norm    TEXT,
    predicate       TEXT,
    entity_id       TEXT,
    -- 时间范围描述（JSON：{from,to,label}）；time_scope 给人看，due_at 给心跳扫描用
    time_scope_json TEXT,
    due_at          INTEGER,
    confidence      REAL NOT NULL DEFAULT 0.6,
    importance      REAL NOT NULL DEFAULT 0.5,
    pinned          INTEGER NOT NULL DEFAULT 0,
    -- 一次抽取 = 一个批次；显式写入也带 batch_id（单条批次），
    -- 这样"撤销这批"对所有来源都成立
    batch_id        TEXT,
    -- explicit / session / task / recording / code_task / heartbeat / user_corrected
    source          TEXT NOT NULL,
    valid_from      INTEGER NOT NULL,
    valid_to        INTEGER,
    superseded_by   TEXT,
    use_count       INTEGER NOT NULL DEFAULT 0,
    useful_count    INTEGER NOT NULL DEFAULT 0,
    useless_count   INTEGER NOT NULL DEFAULT 0,
    last_used_at    INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    deleted_at      INTEGER,
    FOREIGN KEY (workspace_id) REFERENCES workspaces (id) ON DELETE SET NULL
);

-- 列表翻页：(status 过滤, updated_at DESC, id DESC)
CREATE INDEX idx_memories_cursor ON memories (status, updated_at DESC, id DESC);
-- 消息式过滤（kind / scope / 项目层）
CREATE INDEX idx_memories_kind ON memories (kind, status, updated_at DESC, id DESC);
CREATE INDEX idx_memories_scope ON memories (scope, workspace_id, status);
-- 实体时间线与"这个人的全部记忆"
CREATE INDEX idx_memories_entity ON memories (entity_id, created_at DESC);
-- 撤销一批
CREATE INDEX idx_memories_batch ON memories (batch_id);
-- 去重：同 subject + 内容归一化
CREATE INDEX idx_memories_dedupe ON memories (subject_norm, content_tokens);
-- digest 取数：置顶优先、重要度次之
CREATE INDEX idx_memories_digest ON memories (status, pinned DESC, importance DESC, updated_at DESC);
-- 心跳临近项扫描
CREATE INDEX idx_memories_due ON memories (status, due_at) WHERE due_at IS NOT NULL;

CREATE TABLE memory_evidence (
    id           TEXT PRIMARY KEY,
    memory_id    TEXT NOT NULL,
    -- message / task / step / recording / code_task / explicit
    source_kind  TEXT NOT NULL,
    source_id    TEXT NOT NULL,
    -- 源文本的连续子串（归一化前）
    quote        TEXT NOT NULL,
    -- 断言依赖 quote 中的哪一段，必须也是 quote 的子串
    support_span TEXT,
    created_at   INTEGER NOT NULL,
    FOREIGN KEY (memory_id) REFERENCES memories (id) ON DELETE CASCADE
);

CREATE INDEX idx_memory_evidence_memory ON memory_evidence (memory_id);
-- 源被删除时按 (kind,id) 找到要转 stale 的记忆
CREATE INDEX idx_memory_evidence_source ON memory_evidence (source_kind, source_id);

CREATE TABLE memory_recall_log (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT,
    message_id      TEXT,
    query           TEXT NOT NULL,
    memory_id       TEXT NOT NULL,
    rank            INTEGER NOT NULL,
    score           REAL NOT NULL,
    -- 自动代理指标：回答正文里出现了记忆正文的 >=8 字连续子串
    used            INTEGER NOT NULL DEFAULT 0,
    feedback        TEXT,
    created_at      INTEGER NOT NULL
);

CREATE INDEX idx_recall_log_conversation ON memory_recall_log (conversation_id, created_at DESC);
CREATE INDEX idx_recall_log_memory ON memory_recall_log (memory_id, created_at DESC);

CREATE TABLE memory_digest_snapshots (
    id              TEXT PRIMARY KEY,
    mode            TEXT,
    workspace_id    TEXT,
    content         TEXT NOT NULL,
    chars           INTEGER NOT NULL,
    memory_ids_json TEXT NOT NULL DEFAULT '[]',
    created_at      INTEGER NOT NULL
);

CREATE INDEX idx_digest_snapshots_created ON memory_digest_snapshots (created_at DESC);

CREATE TABLE memory_extract_daily (
    -- 'YYYY-MM-DD'（服务端本地时区）
    day        TEXT PRIMARY KEY,
    calls      INTEGER NOT NULL DEFAULT 0,
    candidates INTEGER NOT NULL DEFAULT 0,
    rejected   INTEGER NOT NULL DEFAULT 0,
    chars      INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

-- FTS5：外部内容表，索引列是写入时算好的 content_tokens。
-- 不直接索引 content，是因为中文需要用 bigram 预分词（见开发方案 4.3）。
CREATE VIRTUAL TABLE memories_fts USING fts5(
    content_tokens,
    content='memories',
    content_rowid='rowid',
    tokenize='unicode61'
);

CREATE TRIGGER memories_fts_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, content_tokens) VALUES (new.rowid, new.content_tokens);
END;

CREATE TRIGGER memories_fts_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, content_tokens)
        VALUES ('delete', old.rowid, old.content_tokens);
END;

CREATE TRIGGER memories_fts_au AFTER UPDATE OF content_tokens ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, content_tokens)
        VALUES ('delete', old.rowid, old.content_tokens);
    INSERT INTO memories_fts(rowid, content_tokens) VALUES (new.rowid, new.content_tokens);
END;
