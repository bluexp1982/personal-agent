-- 工作区：会话与任务的归属，绑定服务端这台电脑上的一个真实目录。
--
-- 模式（code / work）决定能力边界：只有 CODE 工作区允许编码任务（Git 相关操作）。
-- 删除一律软删（deleted_at），与 conversations / tasks 的既有约定保持一致。

CREATE TABLE workspaces (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    mode        TEXT NOT NULL,
    path        TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER
);

-- 列表按模式过滤：先过滤列，再 (updated_at DESC, id DESC)。
CREATE INDEX idx_workspaces_mode ON workspaces (mode, deleted_at, updated_at DESC, id DESC);

-- 同一目录不能同时是两个活动工作区，否则「任务该落到哪棵树」没有唯一答案。
-- 软删的行不参与唯一性判断，否则删掉工作区后就再也不能把这个目录要回来。
CREATE UNIQUE INDEX idx_workspaces_path ON workspaces (path) WHERE deleted_at IS NULL;

-- 会话归属工作区。
--
-- SQLite 不能给已有表加 NOT NULL 列，因此这一列可空、**由写路径保证必填**；
-- 升级前的历史会话在启动时由 `workspace::ensure_default` 回填到「默认工作区」。
ALTER TABLE conversations ADD COLUMN workspace_id TEXT;

CREATE INDEX idx_conversations_workspace
    ON conversations (workspace_id, archived, updated_at DESC, id DESC);
