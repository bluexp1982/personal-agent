//! 服务装配：数据库与身份就绪后，同时启动管理面与对外 API。
//!
//! 两个监听共用一个 `AppState`（同一连接池、同一身份、同一限流器），
//! 任意一个退出即视为整体应当停止——`select!` 之后统一清理 socket 与端口文件。

use crate::admin;
use crate::api;
use crate::clock::now_ms;
use crate::config::Config;
use crate::db::{self, DbError};
use crate::identity::{Identity, IdentityError};
use crate::state::AppState;
use crate::tool_gateway::WorkerToolGateway;
use crate::worker::{self, WorkerExecutor};
use crate::{task, ticker};

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error(transparent)]
    Db(#[from] DbError),
    #[error(transparent)]
    Identity(#[from] IdentityError),
    #[error(transparent)]
    Tls(#[from] crate::tls::TlsError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub async fn run(config: Config) -> Result<(), AppError> {
    let pool = db::connect(&config.db_path()).await?;
    db::migrate(&pool).await?;

    let identity = Identity::load_or_create(&config.identity_path())?;
    tracing::info!(
        db = %config.db_path().display(),
        fingerprint = %identity.fingerprint(),
        "数据库与身份就绪"
    );

    // 升级兜底：历史会话还没有项目归属时，建一个「默认项目」把它们归进去。
    // 放在这里而不是 SQL 迁移里：默认目录由配置决定，迁移脚本拿不到绝对路径。
    match crate::project::ensure_default(&pool, &config).await {
        Ok(Some(project)) => tracing::info!(
            project_id = %project.id,
            path = %project.path,
            conversations = project.conversation_count,
            "已创建默认项目并归入历史会话"
        ),
        Ok(None) => {}
        Err(err) => {
            // 不阻断启动：项目只是组织方式，回填失败不该让既有会话也打不开。
            tracing::error!(%err, "默认项目回填失败，历史会话暂不出现在项目视图里");
        }
    }

    // 示例技能（trip-plan / bill-explain）以外部插件形态随应用分发：首次启动
    // 装好，之后归用户管——可停用、可卸载，卸载过的不会被装回来。
    //
    // 必须早于 `worker::spawn`：worker 只认 `plugin_dir`，装晚了还得额外触发
    // 一次重载，而重载期间已经发出的派单会找不到技能。
    match crate::plugin::seed::ensure(&pool, &config.plugins_dir()).await {
        Ok(0) => {}
        Ok(count) => tracing::info!(count, "示例技能已就绪"),
        Err(err) => {
            // 与默认项目回填同样的口径：示例能力装不上不该让服务起不来。
            tracing::error!(%err, "示例技能安装失败，本次跳过");
        }
    }

    // 证书先于状态装配：它决定客户端能不能信任这台机器，日志必须在监听之前说清楚。
    let tls = if config.tls_required() {
        let tls = crate::tls::TlsIdentity::load_or_create(&config)?;
        tracing::info!(
            bind = %config.api_bind,
            fingerprint = %tls.fingerprint(),
            pem = %config.tls_cert_pem_path().display(),
            "对外 API 使用自签 TLS（客户端凭证书指纹识别本机）"
        );
        Some(std::sync::Arc::new(tls))
    } else {
        tracing::info!(
            bind = %config.api_bind,
            "对外 API 使用明文 HTTP（仅限本机访问）"
        );
        None
    };

    let mut state = AppState::new(pool.clone(), identity, config.clone());
    state.tls = tls;

    // 会话预览站：项目文件在服务端，客户端唯一到服务的通道是浏览器隧道，
    // 所以内容必须由服务端托管成一个回环 http 地址。
    //
    // 起不来只降级"会话里预览文件"这一项，不阻断整个服务：预览是锦上添花，
    // 服务起不来则是所有功能全没了。
    match crate::web_preview::WebPreview::start(pool.clone(), state.config.clone()).await {
        Ok(preview) => state.web_preview = Some(preview),
        Err(err) => {
            tracing::warn!(%err, "预览站启动失败：会话里的文件预览与运行代理不可用")
        }
    }

    // 编码代理必须先于 worker 就绪：worker 的启动环境里要带上代理地址。
    if config.code.enabled {
        std::fs::create_dir_all(config.code_worktree_dir())?;
        let proxy = crate::code_proxy::CodeProxy::start(&config, pool.clone()).await?;
        tracing::info!(
            addr = %proxy.base_url(),
            provider = %config.code.provider,
            model = %config.code_upstream_model(),
            upstream = proxy.has_upstream(),
            worktrees = %config.code_worktree_dir().display(),
            "编码代理已启动（仅回环；模型密钥不出本进程）"
        );
        state.code_proxy = Some(proxy);
    }

    // 联网工具代理同样必须先于 worker：worker 的启动环境要带上代理地址与令牌。
    // 不需要付费上游时不起监听，也不占端口。
    match crate::tool_proxy::ToolProxy::start(&config).await {
        Ok(Some(proxy)) => {
            tracing::info!(
                addr = %proxy.base_url(),
                search = config.web_search_provider(),
                fetch_fallback = config.web_fetch_fallback(),
                "联网工具代理已启动（仅回环；密钥不出本进程）"
            );
            state.tool_proxy = Some(proxy);
        }
        Ok(None) => {}
        Err(err) => {
            tracing::warn!(%err, "联网工具代理启动失败：本次仍走 Bing + 本机抓取")
        }
    }

    // M4：生产路径使用独立的 jarvis-worker；未启用时继续用进程内模拟执行器。
    let worker_handle = worker::spawn(state.clone());
    if config.worker_enabled {
        state.executor = std::sync::Arc::new(WorkerExecutor::new(
            worker_handle.clone(),
            state.code_proxy.clone(),
            state.skills.clone(),
            state.config.clone(),
        ));
        // 对话工具同样走 worker：白名单、超时、体积上限只有一套实现。
        state.tool_gateway = std::sync::Arc::new(WorkerToolGateway::new(
            worker_handle.clone(),
            std::time::Duration::from_millis(config.tool.call_timeout_ms.max(1_000)),
        ));
    }
    state.worker = worker_handle.clone();

    // 预算命中时让 CLI 立刻停手。代理自己判失败时拿不到执行器，回调在这里注入；
    // 用弱引用：执行器持有代理句柄，强引用会成环。
    if let Some(proxy) = state.code_proxy.clone() {
        let executor = std::sync::Arc::downgrade(&state.executor);
        let pool = state.pool.clone();
        proxy.on_budget_exceeded(std::sync::Arc::new(move |task_id: String| {
            if let Some(executor) = executor.upgrade() {
                executor.cancel(crate::runner::TaskContext {
                    pool: pool.clone(),
                    task_id,
                });
            }
        }));
    }

    // 录音转写：只在真正能转时才说"已启用"；没配好也要明确告知，
    // 免得用户录完发现只有音频、以为是客户端上传失败。
    if state.transcription.available() {
        tracing::info!(
            model = state.transcription.model().unwrap_or("-"),
            concurrency = config.asr.max_concurrency,
            "录音转写已启用（音频经本机转发给 ASR 厂商）"
        );
    } else if config.asr.enabled {
        tracing::warn!("asr.enabled=true 但转写 provider 未就绪：录音只归档、不出文本");
    } else {
        tracing::info!("录音转写未启用：录音只在本机与服务端归档，不出文本");
    }
    // 上次退出时还没转完的录音，重启后自动续跑；不依赖客户端再点一次。
    state.transcription.resume();
    if state.summary.available() {
        tracing::info!(
            model = state.summary.model().as_deref().unwrap_or("-"),
            "录音总结已启用（转写完成后自动生成）"
        );
    } else if config.summary.enabled {
        tracing::warn!("summary.enabled=true 但模型未就绪：录音只出转写稿，不生成总结");
    }
    state.summary.start();
    // 上次进程被杀时留在 `pending` 的压缩记录标成失败，而不是让"整理中"永远转下去。
    state.compaction.start();
    if state.summary_audio.available() {
        tracing::info!(
            model = state.summary_audio.model().unwrap_or("-"),
            voice = state.summary_audio.voice().unwrap_or("-"),
            "总结语音合成已启用（按需生成）"
        );
    } else if config.tts.enabled {
        tracing::warn!("tts.enabled=true 但 provider 未就绪：总结只出文字，不合成语音");
    }
    state.summary_audio.start();

    // 启动即回收：上次退出时仍在 running 的任务不能假装还在跑。
    let cutoff = now_ms() - config.task_timeout_ms;
    match task::recover_stale_running(&pool, cutoff).await {
        Ok(ids) if !ids.is_empty() => {
            tracing::warn!(
                count = ids.len(),
                "启动时回收悬空任务，转为 queued 等待重试"
            );
        }
        Ok(_) => {}
        Err(err) => tracing::error!(%err, "启动时回收悬空任务失败"),
    }

    // 启动即清理：用户删掉 chip 却没发送的附件，过了 TTL 就该连文件一起走。
    // 只在启动时做一次——这是"迟早要做但不急"的事，不必占 ticker。
    match crate::attachment::purge_orphans(&state).await {
        Ok(0) => {}
        Ok(removed) => tracing::info!(count = removed, "已清理过期的未发送附件"),
        Err(err) => tracing::warn!(%err, "清理过期附件失败"),
    }

    // 后台扫描：审批过期与悬空任务回收。随运行时退出而结束。
    let _ticker = ticker::spawn(state.clone());
    // 心跳与安全网是两条周期：这条只在记忆与心跳都开启时才起，测试不受影响。
    let _heartbeat = (state.config.memory.enabled && state.config.memory.heartbeat.enabled)
        .then(|| crate::heartbeat::spawn(state.clone()));

    // 历史会话可能全都停在「新会话」：启动后按首条提问补一次标题。
    // 不阻塞监听；没配模型时退化为截断，毫秒级完成。
    let title_pool = state.pool.clone();
    let title_model = state.completion_model();
    tokio::spawn(async move {
        match crate::title::backfill(&title_pool, title_model.as_deref()).await {
            Ok(updated) if updated > 0 => tracing::info!(count = updated, "已为历史会话补标题"),
            Ok(_) => {}
            Err(err) => tracing::warn!(%err, "回填历史会话标题失败"),
        }
    });

    let admin_router = admin::router(state.clone());
    let api_router = api::router(state.clone());

    tokio::select! {
        result = admin::serve(&config, admin_router) => {
            tracing::info!("管理面已停止");
            result?;
        }
        result = api::serve(state, api_router) => {
            tracing::info!("对外 API 已停止");
            result?;
        }
    }

    // 先让 worker 收到 shutdown，再由 supervisor 回收子进程。
    worker_handle.shutdown().await;
    cleanup(&config);
    pool.close().await;
    Ok(())
}

/// 尽力清理运行期文件。即使某个监听是被 `select!` 取消的，这里也能兜住残留。
fn cleanup(config: &Config) {
    #[cfg(unix)]
    {
        let _ = std::fs::remove_file(config.admin_socket_path());
    }
    let _ = std::fs::remove_file(config.api_port_path());
}
