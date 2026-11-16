-- M3：业务主干的增量。
--
-- 0001 已建好 conversations / messages / tasks / task_steps / approvals /
-- artifacts / audit_log 七张表，这里只补三处缺口，不动既有列。

-- 与 updated_at 区分：updated_at 是"最后一次变更"，finished_at 是"执行结束"。
-- 任务终态后仍可能因审批记录或产物追加而更新 updated_at，两者语义不同。
ALTER TABLE tasks ADD COLUMN finished_at INTEGER;

-- 客户端重发去重：同一条用户消息重复提交不应产生两条记录。
ALTER TABLE messages ADD COLUMN client_msg_id TEXT;

CREATE UNIQUE INDEX idx_messages_client ON messages (conversation_id, client_msg_id)
    WHERE client_msg_id IS NOT NULL;

-- 会话内单调序号。
-- 只靠 (created_at, id) 排序时，同一毫秒内写入的两条消息（用户的提问与助理的回答）
-- 顺序由随机 id 决定，历史会随机颠倒。seq 提供确定的先后关系，也让 cursor 稳定。
ALTER TABLE messages ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
UPDATE messages SET seq = rowid;
CREATE INDEX idx_messages_seq ON messages (conversation_id, seq DESC);

-- 全量任务列表按 cursor 翻页。0001 的两个索引分别以 state 与 conversation_id
-- 打头，无法服务"不带过滤条件"的列表查询。
CREATE INDEX idx_tasks_cursor ON tasks (updated_at DESC, id DESC);
