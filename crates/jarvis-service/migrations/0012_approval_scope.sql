-- 工具级审批（多 CLI 编码执行层，V1.12）。
--
-- `scope` 区分"任务级（合并确认）"与"工具级（某一次工具调用）"；
-- `tool_json` 只在 scope='tool' 时存在：{ name, risk, digest }。
-- 老数据全部落回 task，读写都不受影响。
ALTER TABLE approvals ADD COLUMN scope TEXT NOT NULL DEFAULT 'task';
ALTER TABLE approvals ADD COLUMN tool_json TEXT;

CREATE INDEX IF NOT EXISTS idx_approvals_task_pending
    ON approvals (task_id, decision, created_at);
