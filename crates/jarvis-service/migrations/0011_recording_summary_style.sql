-- 总结形式：当前正文实际使用的样式 + 用户选中的下一版样式。
--
-- 两列必须分开：用户切到「简短摘要」但还没点「重新生成」时，旧正文仍然
-- 是会议纪要，不能把正文标签改成新样式。
ALTER TABLE recordings ADD COLUMN summary_style TEXT;
ALTER TABLE recordings ADD COLUMN summary_style_preference TEXT NOT NULL DEFAULT 'brief';

-- 功能上线前已有的总结都是会议纪要：保留正文，并标记为 minutes，
-- 避免被错误显示成新的默认「简短摘要」。
UPDATE recordings
SET summary_style = 'minutes',
    summary_style_preference = 'minutes'
WHERE summary IS NOT NULL AND trim(summary) <> '';
