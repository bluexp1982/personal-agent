import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/browser/browser_controller.dart';
import '../../core/browser/browser_favicon.dart';
import '../../core/browser/browser_models.dart';
import '../../core/browser/browser_zoom.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import 'browser_empty_view.dart';
import 'browser_toolbar.dart';

/// macOS 上用的 Safari 形态 UA。
///
/// WKWebView 自己的 UA 只到 `(KHTML, like Gecko)`，缺 `Version/x.y Safari/...` 这一段，
/// 于是一批按 UA 分流的站点会把它当成不支持的客户端：百度会返回一个
/// `<script>location.replace(https -> http)</script>` 的空壳，而 HSTS 又把这条 http
/// 请求升回 https，形成 https ⇄ http 死循环——页面永远白屏、标签永远转圈。
///
/// 前四段与 `navigator.userAgent` 的原值完全一致（OS 令牌本来就是固定的 `10_15_7`），
/// 只在末尾补 Safari 那一段。`Version` 写死是不得已：WebKit 不暴露自己的 Safari
/// 版本号，而站点认的是"有 Safari 这一段"，不是精确版本。
const String kSafariUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/18.0 Safari/605.1.15';

/// 右栏浏览器面板：导航栏 + 一个 WebView。
///
/// 每个浏览器标签一份（`tabId` 对应 `browserSessionProvider` 的一个实例）：
/// 面板标签是"一个标签一页"，这里只负责画出这一页，多标签的集合与顺序在
/// `filePaneTabProvider` 里。
class BrowserPane extends ConsumerStatefulWidget {
  const BrowserPane({super.key, required this.tabId});

  /// 本页所属的浏览器标签 id，与标签栏里那个标签同一口径。
  final String tabId;

  @override
  ConsumerState<BrowserPane> createState() => _BrowserPaneState();
}

class _BrowserPaneState extends ConsumerState<BrowserPane> {
  InAppWebViewController? _web;
  int _loadedRequest = 0;

  /// WebView 的"代数"。加一等于换一个全新的 WKWebView。
  ///
  /// 渲染进程崩掉（或 WebKit 卡死）之后，旧的 WKWebView 会变成一块白板，
  /// 再 `loadUrl` 也不会恢复——只有重建平台视图才能重新加载。
  int _webEpoch = 0;

  /// 主文档迟迟不回音时的兜底计时器（见 [_armStallWatch]）。
  Timer? _stallTimer;

  /// 主文档迟迟不回音的判定时长。
  ///
  /// 只兜「页面根本没开始渲染」这一种情况：正常站点几百毫秒就有进度，
  /// 15s 连主文档都没下来基本就是卡住/被拦了。
  static const Duration _stallTimeout = Duration(seconds: 15);

  /// 从页面里挑一张图标的脚本。
  ///
  /// 不用 `getFavicons()`：那是 Android 专有 API，macOS/WKWebView 上没有实现。
  /// `rel~="icon"` 同时命中 `icon` 与 `shortcut icon` 两种写法。
  static const String _faviconProbe = r'''
(function () {
  var links = document.querySelectorAll(
    'link[rel~="icon"], link[rel="apple-touch-icon"]'
  );
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute('href');
    if (href && href.trim()) return href.trim();
  }
  return '';
})()
''';

  BrowserController get _controller =>
      ref.read(browserSessionProvider(widget.tabId).notifier);

  /// 把缩放真正作用到页面上。
  ///
  /// 两条路来自平台能力差异，不是"降级"：
  /// - Apple（macOS / iOS）有原生 `WKWebView.pageZoom`，等价于给页面内容设
  ///   CSS zoom，但由系统维护，导航后不会丢；
  /// - Android / Windows 的插件没有暴露缩放因子（Windows 只开放
  ///   `supportZoom` 开关），只能注入 `document.documentElement.style.zoom`，
  ///   并在每次加载收尾时重放（导航会把内联样式冲掉）。
  ///
  /// 100% 时对 JS 分支是"把内联样式清空"，交回页面自己可能在用的 `zoom`。
  Future<void> _applyZoom(double zoom) async {
    final web = _web;
    if (web == null || Platform.isLinux) {
      return;
    }
    try {
      if (Platform.isMacOS || Platform.isIOS) {
        await web.setSettings(settings: _settingsFor(zoom));
        return;
      }
      await web.evaluateJavascript(source: zoomScript(zoom));
    } on Object {
      // 页面还没就绪 / 平台视图正在销毁时调用会抛：缩放是锦上添花，
      // 不该因为它把一次导航或一次点击变成错误。下一次 onLoadStop 还会重试。
    }
  }

  /// 页面加载完成后补一次缩放（仅非 100% 时）。
  ///
  /// Apple 端 `pageZoom` 挂在 WebView 上、导航不会清；但硬重载之后的新视图
  /// 在 `initialSettings` 里已经带上，这里再补一次也无害且幂等。
  void _reapplyZoom() {
    if (!mounted) {
      return;
    }
    final zoom = ref.read(browserSessionProvider(widget.tabId)).zoom;
    if (zoom != 1) {
      unawaited(_applyZoom(zoom));
    }
  }

  /// WebView 设置。带 [zoom] 是因为 Apple 端的页面缩放就藏在这一组里
  /// （`pageZoom`，WKWebView 的原生属性），调档时得整份重建再 `setSettings`。
  ///
  /// 不缓存成一份可变的静态对象：缩放在标签之间独立，静态缓存会让 A 标签的
  /// 比例被 B 标签覆盖；而每次新建时这些字段的取值都必须与原来完全一致。
  static InAppWebViewSettings _settingsFor(double zoom) => InAppWebViewSettings(
    javaScriptEnabled: true,
    mediaPlaybackRequiresUserGesture: true,
    useShouldOverrideUrlLoading: true,
    supportZoom: true,
    // 远程页面不能读本地文件：浏览器面板不是文件浏览器。
    allowFileAccess: false,
    allowContentAccess: false,
    allowFileAccessFromFileURLs: false,
    // 见 [kSafariUserAgent]：不补这一段，百度会陷入 https ⇄ http 死循环。
    //
    // 为什么不用 `applicationNameForUserAgent`：插件在 macOS 上只在
    // `configuration.applicationNameForUserAgent` 非 nil 时才拼接，而它是 nil，
    // 所以那个设置在这里是空操作（实测 UA 没变）。只能整串指定。
    //
    // 为什么只对 macOS 生效：Android / Windows 的 WebView 默认 UA 本来就是
    // Chrome / Edge 形态，改成 Safari 反而会让站点按 Safari 的特性做降级。
    userAgent: Platform.isMacOS ? kSafariUserAgent : null,
    // Apple 端才有这一格（iOS 14+ / macOS 11+）。其他平台传了也不生效，
    // 那边的缩放由 [zoomScript] 注入的 CSS 完成。
    pageZoom: zoom.clamp(kBrowserZoomMin, kBrowserZoomMax).toDouble(),
    isInspectable: kDebugMode,
  );

  @override
  void dispose() {
    _stallTimer?.cancel();
    super.dispose();
  }

  /// 页面在卡住之前先盯一会儿：平台不会为"请求悬着"发任何回调，
  /// 光靠 `onLoadStop` 收尾会让标签永久转圈（用户点停止也没反应）。
  void _armStallWatch() {
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallTimeout, () {
      if (!mounted) {
        return;
      }
      _log('主文档 ${_stallTimeout.inSeconds}s 没有回音');
      _controller.reportStalled();
    });
  }

  void _cancelStallWatch() => _stallTimer?.cancel();

  /// 硬重载：丢掉当前 WKWebView，用同一地址建一个新的。
  ///
  /// 只用在"这个 WebView 已经不可用"的场合（渲染进程挂掉、错误卡重试）：
  /// 代价是丢掉页内历史与滚动位置，换来的是真能恢复。
  void _hardReload() {
    _log('硬重载（第 ${_webEpoch + 1} 个 WebView）');
    _cancelStallWatch();
    setState(() {
      _webEpoch++;
      _web = null;
    });
    // 新的 WebView 没有历史，旧的 `canGoBack` / `canGoForward` 立刻作废：
    // 留着它们按钮会亮着，点下去什么都不发生。
    _controller.resetHistory();
    _controller.reload();
  }

  /// 调试日志。浏览器卡住时几乎全靠这几行区分"没收到回调"和"回调被丢弃"，
  /// 只在 debug 构建里打，不出现在发布版的日志里。
  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[browser ${widget.tabId}] $message');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(browserSessionProvider(widget.tabId));
    final controller = _controller;

    ref.listen<BrowserSessionState>(browserSessionProvider(widget.tabId), (
      previous,
      next,
    ) {
      // 重新加载的是"现在这一页"（`pageUri` 跟着页内导航走），
      // 不是通道的入口地址：否则点过链接之后一刷新就回到最初那一页。
      if (next.requestId != _loadedRequest && next.internalUri != null) {
        _loadedRequest = next.requestId;
        _load(next.pageUri ?? next.internalUri!);
      }
      // 一次新加载开始（open / 重试）就重新计时；页面有进度或收尾就撤掉。
      if (next.loading && previous?.loading != true) {
        _armStallWatch();
      } else if (!next.loading) {
        _cancelStallWatch();
      }
      // 调档本身只改状态；真正作用到页面的地方在这里，工具条与快捷键
      // 共用同一条出口，不会出现"按钮能缩、快捷键不缩"的两套实现。
      if (next.zoom != previous?.zoom) {
        unawaited(_applyZoom(next.zoom));
      }
    });

    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        BrowserToolbar(
          state: session,
          onSubmit: (value) {
            FocusScope.of(context).unfocus();
            unawaited(controller.open(value));
          },
          onBack: () => unawaited(_go(back: true)),
          onForward: () => unawaited(_go(back: false)),
          // 地址栏里的文字和页面不是同一个地址 = 用户改了地址但没回车：
          // 当成导航，否则"地址栏显示新地址、刷新回到老地址"。
          onReload: (value) {
            final text = value.trim();
            if (text.isEmpty || text == session.address) {
              controller.reload();
              return;
            }
            FocusScope.of(context).unfocus();
            unawaited(controller.open(text));
          },
          // 停止之后平台不会再发 `onLoadStop`，状态得自己收回来：
          // 否则点了叉照样转圈，看着像按钮坏了。
          onStop: () {
            _log('用户点了停止');
            unawaited(_web?.stopLoading());
            controller.stopLoad();
          },
          onOpenExternal: () => unawaited(_openExternal(session)),
          onSelectSource: controller.selectSource,
          onZoomIn: controller.zoomIn,
          onZoomOut: controller.zoomOut,
          onZoomReset: controller.resetZoom,
        ),
        if (session.loading)
          Semantics(
            label: '加载进度',
            child: LinearProgressIndicator(
              value: session.progress > 0 && session.progress < 1
                  ? session.progress
                  : null,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: scheme.primary,
            ),
          ),
        Expanded(child: _content(session)),
      ],
    );
  }

  Widget _content(BrowserSessionState session) {
    if (session.internalUri == null) {
      if (session.error != null) {
        return _errorView(session);
      }
      return BrowserEmptyView(onPickDirectory: _pickDirectory);
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _webView(session),
        if (session.error != null)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: _errorView(session),
          ),
      ],
    );
  }

  Widget _errorView(BrowserSessionState session) {
    final controller = _controller;
    final failure = session.error!;

    return BrowserErrorView(
      failure: failure,
      // 重试用硬重载：已经出错的 WebView 可能连 `loadUrl` 都不响应了
      // （用户点刷新没反应通常就是这种），重建一个才有意义。
      onRetry: failure.canRetry
          ? () {
              if (session.hasPage) {
                _hardReload();
              } else {
                unawaited(controller.open(session.address));
              }
            }
          : null,
      onSwitchToServer: session.target is ClientPortTarget
          ? () => unawaited(controller.openAsServer())
          : null,
      onOpenExternal: session.internalUri == null
          ? null
          : () => unawaited(_openExternal(session)),
    );
  }

  Widget _webView(BrowserSessionState session) {
    if (Platform.isLinux) {
      return _linuxFallback(session);
    }

    return InAppWebView(
      // key 带 tabId 与「代数」：多个浏览器标签同时挂着时平台视图不能互相顶替，
      // 换代则用来强制重建一个已经失效的 WebView（见 [_hardReload]）。
      key: ValueKey<String>('browser-webview-${widget.tabId}-$_webEpoch'),
      // 重建 WebView（硬重载）时也要落在当前页，不是通道的入口页。
      initialUrlRequest: URLRequest(
        url: WebUri((session.pageUri ?? session.internalUri!).toString()),
      ),
      // 硬重载会重建平台视图：比例必须跟着新视图一起进去，否则用户按了
      // 「重试」之后页面突然从 150% 跳回 100%。
      initialSettings: _settingsFor(session.zoom),
      onWebViewCreated: (controller) {
        _log('WebView 已创建');
        _web = controller;
        _loadedRequest = session.requestId;
      },
      // 平台回调可能在面板已经拆掉之后才到（关标签、切走、测试结束都会这样）：
      // 那时 `ref` 已失效，读 provider 会抛异常。每个回调先看一眼 [mounted]。
      onLoadStart: (controller, url) {
        if (!mounted) {
          return;
        }
        _log('onLoadStart $url');
        // 新一次导航开始了：上一页留下的失败卡必须收掉，否则后退/前进时
        // 页面明明在加载，上面却盖着一张"加载失败"。
        _controller.syncView(loading: true, progress: 0.05, clearError: true);
      },
      onProgressChanged: (controller, progress) {
        if (!mounted) {
          return;
        }
        // 进度到 100 就算完成：有的站点（WKWebView 上尤其常见）不发 `onLoadStop`，
        // 只认那个回调会让标签永远停在"加载中"。
        if (progress >= 100) {
          _cancelStallWatch();
          _controller.syncView(loading: false, progress: 1);
          // 顺带补一次按钮状态：不发 `onLoadStop` 的站点不会给别机会，
          // 只等它的话后退/前进按钮会停在上一页的可用性上。
          unawaited(_syncHistory(controller, null));
          // 同上：不认 `onLoadStop` 的站点也得把 CSS 缩放补回去，
          // 否则 Android / Windows 上每跳一页比例就丢一次。
          _reapplyZoom();
          return;
        }
        // 主文档已经有进度 = 请求有回音，不用再盯着超时了。
        if (progress > 5) {
          _cancelStallWatch();
        }
        _controller.syncView(progress: progress / 100);
      },
      // 标题跨平台可用（`getFavicons` 是 Android 专有，这里不用它）。
      onTitleChanged: (controller, title) {
        if (!mounted) {
          return;
        }
        _log('onTitleChanged $title');
        _controller.syncTitle(title);
      },
      onLoadStop: (controller, url) {
        if (!mounted) {
          return;
        }
        _log('onLoadStop $url');
        _cancelStallWatch();
        unawaited(_syncHistory(controller, url, loading: false, progress: 1));
        unawaited(_syncFavicon(controller, url));
        // 导航会把页面上的内联样式冲掉：非 100% 时必须重新注入。
        _reapplyZoom();
      },
      onUpdateVisitedHistory: (controller, url, isReload) {
        if (!mounted) {
          return;
        }
        _log('onUpdateVisitedHistory $url');
        unawaited(_syncHistory(controller, url));
      },
      onReceivedError: (controller, request, error) {
        // 子资源失败不该盖住整页：一行图片挂掉时页面本身还是可用的。
        if (!mounted || request.isForMainFrame != true) {
          return;
        }
        // 后退 / 前进 / 连续跳转会把上一次还没跑完的导航取消掉，
        // WebKit 会为它补一条 `NSURLErrorCancelled(-999)`。这不是失败：
        // 报出去就会用错误卡盖住已经加载好的页面——"点后退有几率提示加载失败"
        // 看到的就是它。
        if (error.type == WebResourceErrorType.CANCELLED) {
          _log('忽略被取消的导航 ${request.url}');
          return;
        }
        _log('onReceivedError ${error.description}');
        _cancelStallWatch();
        _controller.reportError(error.description);
      },
      // 4xx/5xx 不走 `onReceivedError`，但同样意味着"这一页打不开"，
      // 不收尾就会一直转圈。
      onReceivedHttpError: (controller, request, response) {
        if (!mounted || request.isForMainFrame != true) {
          return;
        }
        _log('onReceivedHttpError ${response.statusCode}');
        _cancelStallWatch();
        _controller.reportError('HTTP ${response.statusCode}');
      },
      // WebKit 的渲染进程崩掉后 WebView 会变成一块白板，之后也不再回调任何导航事件，
      // 连 `loadUrl` 都没反应。重建平台视图是唯一能恢复的做法。
      onWebContentProcessDidTerminate: (controller) {
        if (!mounted) {
          return;
        }
        _log('渲染进程终止');
        _hardReload();
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url;
        _log(
          'shouldOverrideUrlLoading $url '
          'type=${navigationAction.navigationType} '
          'main=${navigationAction.isForMainFrame}',
        );
        if (url == null) {
          return NavigationActionPolicy.ALLOW;
        }
        final scheme = url.scheme.toLowerCase();
        if (scheme == 'http' ||
            scheme == 'https' ||
            scheme == 'about' ||
            scheme == 'data' ||
            scheme == 'blob') {
          return NavigationActionPolicy.ALLOW;
        }
        if (scheme == 'mailto' || scheme == 'tel') {
          unawaited(
            launchUrl(
              Uri.parse(url.toString()),
              mode: LaunchMode.externalApplication,
            ),
          );
        }
        return NavigationActionPolicy.CANCEL;
      },
    );
  }

  /// 后退 / 前进，并在平台报告之前先把按钮状态拉正。
  ///
  /// 只发 `goBack()` 的话，状态全指望后续的导航回调：同文档跳转（`#hash`、
  /// `pushState`）或者已经被缓存的页面不一定再发事件，按钮就停在旧值上——
  /// 亮着的点不动、该亮的又点不到。
  Future<void> _go({required bool back}) async {
    final web = _web;
    if (web == null) {
      return;
    }
    if (back) {
      await web.goBack();
    } else {
      await web.goForward();
    }
    if (!mounted) {
      return;
    }
    // 只刷按钮：这一刻新页面的 URL 可能还没提交，回填地址会让地址栏闪一下旧值。
    await _syncHistory(web, null);
  }

  /// 历史同步的世代号。
  ///
  /// `canGoBack()` / `canGoForward()` 各是一次跨平台往返，两次采样很容易交错
  /// 返回（页面自己 `pushState`、连点后退都会造成）。谁最后回来谁写，
  /// 就会把过期的历史快照盖到按钮上——表现就是"有时能用有时不能用"。
  int _historySeq = 0;

  /// 采样一次平台的历史（以及可选的地址）并回填状态。
  ///
  /// [url] 传 null 表示只刷按钮与加载态，不动地址栏。
  Future<void> _syncHistory(
    InAppWebViewController controller,
    WebUri? url, {
    bool? loading,
    double? progress,
  }) async {
    final seq = ++_historySeq;
    final bool canGoBack;
    final bool canGoForward;
    try {
      canGoBack = await controller.canGoBack();
      canGoForward = await controller.canGoForward();
    } on Object catch (error) {
      // 平台视图正在销毁（关标签、换代）：这一次采样没有意义，别让异常冒出去。
      _log('读取前进后退可用性失败：$error');
      return;
    }
    // 采样期间又发生了一次导航：这份快照已经过期，丢掉。
    if (!mounted || seq != _historySeq) {
      return;
    }
    _controller.syncView(
      uri: url == null ? null : Uri.tryParse(url.toString()),
      loading: loading,
      progress: progress,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
    );
  }

  /// 页面加载完成后取一次站点图标。
  ///
  /// 先问页面要 `<link rel="icon">`，拿不到就用同源 `/favicon.ico`；
  /// 下载失败一律把图标清掉（标签回退地球图标），不影响页面本身。
  Future<void> _syncFavicon(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final page = url == null ? null : Uri.tryParse(url.toString());
    if (page == null || !page.hasScheme) {
      return;
    }

    String? href;
    try {
      final result = await controller.evaluateJavascript(source: _faviconProbe);
      href = result is String ? result : null;
    } on Object {
      // 取不到声明就用兜底地址，下面的解析会退回 /favicon.ico。
      href = null;
    }
    if (!mounted) {
      return;
    }

    final iconUri = browserFaviconUri(href, page);
    if (iconUri == null) {
      _controller.syncFavicon(null, page: page);
      return;
    }

    final bytes = await ref.read(browserFaviconLoaderProvider).load(iconUri);
    if (!mounted) {
      return;
    }
    _controller.syncFavicon(bytes, page: page);
  }

  void _load(Uri uri) {
    final web = _web;
    if (web == null) {
      // WebView 还没创建：`initialUrlRequest` 会用当前状态里的地址加载。
      return;
    }
    unawaited(web.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString()))));
  }

  Future<void> _pickDirectory() async {
    final path = await getDirectoryPath(confirmButtonText: '打开');
    if (path == null || !mounted) {
      return;
    }
    await _controller.open(path);
  }

  Future<void> _openExternal(BrowserSessionState session) async {
    // 用户看到的是当前页地址；拿入口地址交给系统浏览器会打开最开始那一页。
    final uri = session.pageUri ?? session.internalUri;
    if (uri == null) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _linuxFallback(BrowserSessionState session) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.public_off_rounded,
                size: 26,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                '当前平台不支持内嵌浏览器；通道已经建立，可以在系统浏览器里打开。',
                textAlign: TextAlign.center,
                style: AppText.of(context).hint.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => unawaited(_openExternal(session)),
                child: const Text(
                  '在系统浏览器打开',
                  style: TextStyle(fontSize: AppFontSize.sm),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
