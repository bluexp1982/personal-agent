-- 随应用分发的示例技能（种子）的播种记录。
--
-- 为什么不能靠"安装目录是否存在"判断要不要播种：卸载会删掉目录与
-- `plugins` 记录，凭目录判断的话，用户卸载后下次启动又会被装回来——
-- 那等于"可卸载"是假的。
--
-- `dismissed` 记的是"用户主动卸载过"：升级带来的新版本也不再装回，
-- 否则应用一升级，用户删掉的示例技能会自己长出来。
--
-- 迁移只前滚，不写 down。

CREATE TABLE plugin_seeds (
    -- 插件 id（`plugins.id`），不是单条技能名：一个种子就是一个包。
    name       TEXT PRIMARY KEY,
    -- 最近一次处理过的种子版本；应用内置版本更高时补装。
    version    TEXT NOT NULL,
    -- 1 表示用户在插件页卸掉过，之后一律不再播种。
    dismissed  INTEGER NOT NULL DEFAULT 0,
    applied_at INTEGER NOT NULL
);
