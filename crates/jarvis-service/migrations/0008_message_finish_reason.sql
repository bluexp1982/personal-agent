-- 回答的终态：stop（写完）/ error（出错）/ stopped（用户点了停止）。
--
-- 落成列而不是塞进 content_json：后者是"正文 + 来源 + 建议"的载体，
-- 而终态与 elapsed_ms、token 用量同属统计口径，落列之后按会话统计
-- "被停止率"可以直接 SQL 分组，也避免同一份数据出现两条读取路径。
--
-- 历史行为 NULL：客户端一律按"已完成"处理，界面不退化成"未知状态"。
-- 用户消息没有终态，恒为 NULL。

ALTER TABLE messages ADD COLUMN finish_reason TEXT;
