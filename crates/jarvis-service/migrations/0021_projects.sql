-- 工作区 → 项目：表、列、索引与记忆作用域值一起改名，数据原样保留。
--
-- 0006 已经在老库上执行过，改它的内容不会重跑；因此这里用 ALTER TABLE 前滚。
-- SQLite 在 foreign_keys=ON 下会自动把其它表里指向 workspaces 的 REFERENCES
-- 一起改成 projects，所以这里只改列名与索引，不动 FK 定义。

-- 1. 先改列名：会话归属、记忆归属、实体变量。
ALTER TABLE conversations RENAME COLUMN workspace_id TO project_id;
ALTER TABLE memories RENAME COLUMN workspace_id TO project_id;
ALTER TABLE memory_digest_snapshots RENAME COLUMN workspace_id TO project_id;
ALTER TABLE memory_entities RENAME COLUMN workspace_id TO project_id;
ALTER TABLE memory_entities RENAME COLUMN workspace_path TO project_path;

-- 2. 记忆作用域取值：workspace → project（只改值，不改语义）。
UPDATE memories SET scope = 'project' WHERE scope = 'workspace';

-- 3. 索引：旧名字带 workspace 的一律重建，名字与新列对齐。
DROP INDEX IF EXISTS idx_conversations_workspace;
CREATE INDEX IF NOT EXISTS idx_conversations_project
    ON conversations (project_id, archived, updated_at DESC, id DESC);

DROP INDEX IF EXISTS idx_entities_workspace;
CREATE INDEX IF NOT EXISTS idx_entities_project ON memory_entities (project_id, status);

-- idx_memories_scope 的名字不含 workspace，但列已改名；重建一次让 SQL 可读。
DROP INDEX IF EXISTS idx_memories_scope;
CREATE INDEX IF NOT EXISTS idx_memories_scope ON memories (scope, project_id, status);

-- 4. 表改名：外键引用由 SQLite 同步更新。
ALTER TABLE workspaces RENAME TO projects;

DROP INDEX IF EXISTS idx_workspaces_mode;
DROP INDEX IF EXISTS idx_workspaces_path;
CREATE INDEX IF NOT EXISTS idx_projects_mode
    ON projects (mode, deleted_at, updated_at DESC, id DESC);
-- 界面已不再按模式过滤：这份索引服务"全部项目按更新时间倒序"。
CREATE INDEX IF NOT EXISTS idx_projects_updated
    ON projects (deleted_at, updated_at DESC, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_path
    ON projects (path) WHERE deleted_at IS NULL;
