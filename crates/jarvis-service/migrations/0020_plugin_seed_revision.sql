-- 种子技能的修订号。
--
-- `version` 只回答"技能包是哪个版本"，回答不了"这次装进去的结论对不对"。
-- 例子：兼容层修好了一个把包误判成 `unsupported` 的判据，包版本不必变，
-- 但已经落盘的 sidecar 仍然是错的。只比版本就会永远跳过，用户看到的是
-- 「包在那儿，但用不了」。
--
-- `revision` 在素材或判定逻辑变化时 +1，播种据此重装一次；用户主动卸载
-- 过的（`dismissed = 1`）仍然不会回来。旧记录默认空串，正好触发一次重装，
-- 把历史上误判的种子纠正过来。
--
-- 迁移只前滚，不写 down。

ALTER TABLE plugin_seeds ADD COLUMN revision TEXT NOT NULL DEFAULT '';
