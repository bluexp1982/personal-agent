-- 实体页：把"关于同一个人的记忆"聚合成一条可读的状态。
--
-- 实体不存正文：正文在 memories，这里只放"当前状态快照"（一段合成文本）。
-- 快照由夜间批处理重算，重算前 `snapshot_json` 是空对象——界面显示"还没有快照"。

CREATE TABLE memory_entities (
    id               TEXT PRIMARY KEY,
    -- person / org / project / device / recurring
    entity_type      TEXT NOT NULL,
    name             TEXT NOT NULL,
    -- 归一化名称：匹配与唯一约束都基于它
    name_norm        TEXT NOT NULL,
    -- JSON 数组：别名（归一化后的去重列表）
    aliases_json     TEXT NOT NULL DEFAULT '[]',
    workspace_id     TEXT,
    -- project 实体绑定仓库根；其它类型为空
    workspace_path   TEXT,
    -- pending / active / archived / merged
    status           TEXT NOT NULL,
    merged_into      TEXT,
    -- 当前状态快照（合成文本，不是正文）
    snapshot_json    TEXT NOT NULL DEFAULT '{}',
    snapshot_at      INTEGER,
    -- 1 = 需要夜间重算
    dirty            INTEGER NOT NULL DEFAULT 0,
    confidence       REAL NOT NULL DEFAULT 0,
    evidence_count   INTEGER NOT NULL DEFAULT 0,
    last_evidence_at INTEGER,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    FOREIGN KEY (workspace_id) REFERENCES workspaces (id) ON DELETE SET NULL
);

-- 强匹配：同类型 + 归一化名称唯一。被合并的旧实体把 name_norm 置空，避免撞唯一索引。
CREATE UNIQUE INDEX idx_entities_name ON memory_entities (entity_type, name_norm)
    WHERE status != 'merged';
CREATE INDEX idx_entities_workspace ON memory_entities (workspace_id, status);
-- 夜间批处理取脏实体
CREATE INDEX idx_entities_dirty ON memory_entities (dirty, updated_at) WHERE dirty = 1;
CREATE INDEX idx_entities_path ON memory_entities (workspace_path) WHERE workspace_path IS NOT NULL;

CREATE TABLE memory_entity_links (
    entity_id  TEXT NOT NULL,
    memory_id  TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (entity_id, memory_id),
    FOREIGN KEY (entity_id) REFERENCES memory_entities (id) ON DELETE CASCADE,
    FOREIGN KEY (memory_id) REFERENCES memories (id) ON DELETE CASCADE
);

CREATE INDEX idx_entity_links_memory ON memory_entity_links (memory_id);

-- 旧快照留档：每个实体保留最近 10 份，由夜间整理裁剪。
CREATE TABLE memory_entity_snapshots (
    id             TEXT PRIMARY KEY,
    entity_id      TEXT NOT NULL,
    snapshot_json  TEXT NOT NULL,
    evidence_count INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL,
    FOREIGN KEY (entity_id) REFERENCES memory_entities (id) ON DELETE CASCADE
);

CREATE INDEX idx_entity_snapshots_entity ON memory_entity_snapshots (entity_id, created_at DESC);
