-- 执行授权：审批的缓存层。只跳过"询问"，不改变"判定"。
--
-- 编号是 0017 而不是设计文档里留的 0015：0016 已经发布，迁移只前滚，
-- 回头补一个更低的版本号会让已升级的库处于"缺一个已越过的迁移"的状态。

CREATE TABLE memory_grants (
    id          TEXT PRIMARY KEY,
    -- 工具名（与 worker 侧同名，如 code.write / code.delete）
    tool        TEXT NOT NULL,
    -- read / reversible_write / irreversible_write
    risk        TEXT NOT NULL,
    -- task / session / project
    scope       TEXT NOT NULL,
    -- task_id / conversation_id / workspace_id
    scope_id    TEXT NOT NULL,
    -- 批准它的那条审批记录：所有 grant 都要能追到"当初是哪张卡批准的"
    approved_by TEXT NOT NULL,
    device_id   TEXT,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    revoked_at  INTEGER,
    last_hit_at INTEGER,
    hit_count   INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (approved_by) REFERENCES approvals (id) ON DELETE CASCADE
);

-- 同一作用域内同一工具同一风险档只能有一条活着的 grant
CREATE UNIQUE INDEX idx_grants_unique ON memory_grants (tool, risk, scope, scope_id)
    WHERE revoked_at IS NULL;
CREATE INDEX idx_grants_lookup ON memory_grants (scope, scope_id, tool, revoked_at);
CREATE INDEX idx_grants_expiry ON memory_grants (expires_at, revoked_at);
