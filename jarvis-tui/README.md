# jarvis-tui（占位）

终端运维面板：纯 Rust + `ratatui` + `crossterm`，面向无桌面环境的 Linux
（服务器、容器、SSH 会话），与 `jarvis-gui` 共用 `/admin/*` 契约和 `protocol` crate。

**状态**：v1.2 才实现，且分发形态（独立二进制还是 `jarvis-service tui` 子命令）尚未拍板。

边界摘要：与 `jarvis-gui` 共用 `/admin/*` 契约，只读、自身无状态。
