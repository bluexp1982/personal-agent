-- 回答的统计元信息：耗时与 token 用量。
--
-- 独立成列而不是塞进 content_json：后者是"正文 + 来源 + 建议"的载体，
-- 而耗时/用量是统计口径的数据，落成列之后按会话聚合（平均耗时、总 token）
-- 可以直接 SQL 求和，也避免同一份数据出现两条读取路径。
--
-- 历史行新列为 NULL：客户端按"未知"处理，只省略用时与用量，不影响布局。
-- 用户消息没有这两项，恒为 NULL。

ALTER TABLE messages ADD COLUMN elapsed_ms INTEGER;
ALTER TABLE messages ADD COLUMN prompt_tokens INTEGER;
ALTER TABLE messages ADD COLUMN completion_tokens INTEGER;
ALTER TABLE messages ADD COLUMN tokens_estimated INTEGER NOT NULL DEFAULT 0;
