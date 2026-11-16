-- 录音总结与总结语音。
--
-- 总结是录音的派生数据：转写完成后自动生成，重生成时清空旧的总结与语音。
-- 音频不进数据库，只存相对 `{data_dir}/recordings` 的路径。
ALTER TABLE recordings ADD COLUMN summary TEXT NOT NULL DEFAULT '';
ALTER TABLE recordings ADD COLUMN summary_status TEXT NOT NULL DEFAULT 'none';
ALTER TABLE recordings ADD COLUMN summary_error TEXT;
ALTER TABLE recordings ADD COLUMN summary_model TEXT;
ALTER TABLE recordings ADD COLUMN summary_updated_at INTEGER;
ALTER TABLE recordings ADD COLUMN summary_audio_path TEXT;
ALTER TABLE recordings ADD COLUMN summary_audio_status TEXT NOT NULL DEFAULT 'none';
ALTER TABLE recordings ADD COLUMN summary_audio_error TEXT;
ALTER TABLE recordings ADD COLUMN summary_audio_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE recordings ADD COLUMN summary_audio_format TEXT;
ALTER TABLE recordings ADD COLUMN summary_audio_updated_at INTEGER;
ALTER TABLE recordings ADD COLUMN summary_audio_truncated INTEGER NOT NULL DEFAULT 0;
