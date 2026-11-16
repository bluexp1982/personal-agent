-- 逻辑删除：`deleted_at` 非空即视为已删除，行本身保留在库里。
--
-- 只给"删除主体"加标记：会话与任务。消息、步骤、审批、产物元信息属于父级的
-- 从属数据，随父级一起从接口视图里消失；将来若恢复父级，不需要再补数据。
--
-- 不设自动清理：软删数据永久保留，需要时再单独加清理任务或手工处理。

ALTER TABLE conversations ADD COLUMN deleted_at INTEGER;
ALTER TABLE tasks ADD COLUMN deleted_at INTEGER;

-- 列表与清理都按"未删除"过滤，单列索引足够。
CREATE INDEX idx_conversations_deleted ON conversations (deleted_at);
CREATE INDEX idx_tasks_deleted ON tasks (deleted_at);
