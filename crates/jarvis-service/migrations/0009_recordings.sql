-- 录音笔记：转写稿为主数据，音频为归档。
--
-- 录音文件本体落在 `{data_dir}/recordings/{id}/seg_XXXXX.wav`，库里只存
-- 分段元信息与相对路径。删除录音是物理删除（连同文件），不做软删：
-- 音频占磁盘，留一份"看不见但还在"的归档没有意义。

CREATE TABLE recordings (
    id                  TEXT PRIMARY KEY,
    -- 客户端生成的稳定标识：断点续传、崩溃恢复后重建同一个服务端记录。
    client_recording_id TEXT NOT NULL,
    title               TEXT NOT NULL,
    mode                TEXT NOT NULL,
    status              TEXT NOT NULL,
    duration_ms         INTEGER NOT NULL DEFAULT 0,
    bytes               INTEGER NOT NULL DEFAULT 0,
    segment_count       INTEGER NOT NULL DEFAULT 0,
    ready_count         INTEGER NOT NULL DEFAULT 0,
    -- 所有 ready 分段按 seq 拼起来的文本；列表预览与搜索都用它。
    text                TEXT NOT NULL DEFAULT '',
    device_id           TEXT,
    -- 客户端调用 complete 的时刻。为空表示"还在录"，用于状态机判断。
    completed_at        INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

-- 幂等创建：同一台客户端重复提交同一个 local id 时返回已有记录。
CREATE UNIQUE INDEX idx_recordings_client ON recordings (client_recording_id);

-- 列表按 (updated_at DESC, id DESC) 翻页；status 过滤走前缀列。
CREATE INDEX idx_recordings_cursor ON recordings (updated_at DESC, id DESC);
CREATE INDEX idx_recordings_status ON recordings (status, updated_at DESC, id DESC);

CREATE TABLE recording_segments (
    recording_id TEXT NOT NULL REFERENCES recordings (id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    start_ms     INTEGER NOT NULL,
    end_ms       INTEGER NOT NULL,
    bytes        INTEGER NOT NULL,
    -- 相对 `{data_dir}/recordings` 的路径；服务端只按自己拼出的路径读写。
    path         TEXT NOT NULL,
    text         TEXT NOT NULL DEFAULT '',
    state        TEXT NOT NULL,
    error        TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    PRIMARY KEY (recording_id, seq)
);

-- 后台转写按 "还没成功的段" 取活；已成功的不再重转。
CREATE INDEX idx_recording_segments_state ON recording_segments (recording_id, state);
