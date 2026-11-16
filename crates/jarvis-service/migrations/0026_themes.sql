-- 主题包（个性化主题）：安装记录与稀疏色表。
--
-- 为什么颜色存"稀疏覆盖"而不是展开后的完整色表：展开值只是"内置派生 + 覆盖"
-- 的中间产物，存下来等于在服务端复制了一份 Flutter 的色表。客户端一加 token，
-- 两边就会漂；而 `AppPalette` 才是色表的唯一真源。
--
-- 与 plugins 的差异：
--   * 没有 enabled：主题是"选中即用"的二选一，启停没有语义；
--   * 没有版本目录：同 id 重装即覆盖，故主键只有 id。
--
-- 迁移只前滚，不写 down。

CREATE TABLE themes (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    version      TEXT NOT NULL,
    author       TEXT,
    description  TEXT,
    -- light / dark。包只声明一种，客户端选中后不再跟随系统。
    brightness   TEXT NOT NULL,
    -- ThemeColors 的 JSON：只含包声明覆盖的格子，缺省即"沿用内置派生值"。
    colors_json  TEXT NOT NULL DEFAULT '{}',
    -- 安装目录的绝对路径（`{data_dir}/themes/<id>/`），删除要用。
    dir          TEXT NOT NULL,
    -- 安装包 sha256，进审计与排查；老数据可能为空。
    checksum     TEXT NOT NULL DEFAULT '',
    installed_at INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

-- 列表按"最近更新在前"排：覆盖安装会把主题顶到最前面，用户刚装的包一眼可见。
CREATE INDEX idx_themes_updated_at ON themes (updated_at DESC);
