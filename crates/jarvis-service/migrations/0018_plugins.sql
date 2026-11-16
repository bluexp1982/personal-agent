-- 技能包（外部技能）：安装记录与技能清单快照。
--
-- 为什么技能清单要落库而不是每次扫盘：`/api/skills` 与插件管理页在 worker
-- 未连接时也要能给出插件技能（带状态与原因），而 service 不该为此再实现一套
-- 磁盘扫描与 frontmatter 解析。扫描与归一化只发生在安装时，结果写进这里和
-- 目录里的 sidecar；worker 重载时读 sidecar，不读这张表。
--
-- 迁移只前滚，不写 down。

CREATE TABLE plugins (
    id           TEXT PRIMARY KEY,
    -- 展示名；无清单形态与 id 相同。
    name         TEXT NOT NULL,
    version      TEXT NOT NULL,
    author       TEXT,
    description  TEXT,
    -- 安装目录的绝对路径（`{data_dir}/plugins/<id>/<version>/`），卸载要用。
    dir          TEXT NOT NULL,
    -- 安装包 sha256，进审计与排查；老数据可能为空。
    checksum     TEXT NOT NULL DEFAULT '',
    -- 0 表示停用：其技能立即从候选里消失。
    enabled      INTEGER NOT NULL DEFAULT 1,
    installed_at INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

CREATE TABLE plugin_skills (
    plugin_id     TEXT NOT NULL REFERENCES plugins (id) ON DELETE CASCADE,
    -- 技能名（frontmatter `name`）。全局唯一由 service 在安装时保证。
    name          TEXT NOT NULL,
    -- supported / degraded / unsupported
    status        TEXT NOT NULL,
    -- 降级或不支持的可读原因（JSON 数组），管理页直接展示。
    reasons_json  TEXT NOT NULL DEFAULT '[]',
    -- 归一化后的清单（SkillManifest 的 JSON）。列表直接反序列化，
    -- 不用为展示再去读一遍 sidecar。
    manifest_json TEXT NOT NULL,
    -- 规范里的 description：做什么、何时用。
    description   TEXT,
    PRIMARY KEY (plugin_id, name)
);

-- 按技能名查所属插件（冲突检测与删除后清理都要用）。
CREATE INDEX idx_plugin_skills_name ON plugin_skills (name);
