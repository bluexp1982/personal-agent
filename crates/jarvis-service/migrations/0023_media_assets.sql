-- 会话内生成的图片 / 视频。
--
-- 只存元信息与产物相对路径：正文在 {data_dir}/artifacts 下，消息 content_json
-- 里也只有这份元信息。图片 2–3MB、视频 5–10MB，谁都不该被塞进消息行。
--
-- 为什么单独一张表而不是复用 artifacts：那张表属于任务（JOIN tasks 才能下载），
-- 会话里的媒体没有 task，也不该为了下载去伪造一个任务。

CREATE TABLE media_assets (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    -- image | video
    kind            TEXT NOT NULL,
    -- 相对 artifacts 根的路径，绝对路径一律不接受。
    path            TEXT NOT NULL,
    mime            TEXT NOT NULL,
    bytes           INTEGER NOT NULL,
    model           TEXT NOT NULL,
    prompt          TEXT NOT NULL DEFAULT '',
    width           INTEGER,
    height          INTEGER,
    duration_ms     INTEGER,
    -- 视频分辨率档位（480P / 720P / 1080P）；图片为空。
    resolution      TEXT,
    created_at      INTEGER NOT NULL
);

CREATE INDEX idx_media_assets_conversation
    ON media_assets (conversation_id, created_at DESC);
