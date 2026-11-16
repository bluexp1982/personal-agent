import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session.dart';
import 'browser_models.dart';
import 'browser_targets.dart';
import 'browser_zoom.dart';
import 'local_static_server.dart';
import 'server_tunnel.dart';

/// 通道层交回来的一次可用会话。
///
/// [close] 负责释放本页占用的资源（桥接监听、静态服务、HttpClient）；
/// [staticServer] 只用于把内部 URL 还原成用户视角的路径。
class BrowserChannel {
  const BrowserChannel({
    required this.internalUri,
    required this.address,
    required this.close,
    this.staticServer,
  });

  final Uri internalUri;
  final String address;
  final Future<void> Function() close;
  final LocalStaticServer? staticServer;
}

/// 打开通道所需的服务端信息。
class BrowserOpenContext {
  const BrowserOpenContext({
    required this.baseUrl,
    required this.token,
    required this.tlsFingerprint,
  });

  final String baseUrl;
  final String token;
  final String? tlsFingerprint;
}

typedef BrowserChannelOpener = Future<BrowserChannel> Function(
  BrowserTarget target,
  BrowserOpenContext context,
);

/// 真实通道：本机端口直连、服务端端口走隧道、互联网直连、本机目录走静态服务。
Future<BrowserChannel> openBrowserChannel(
  BrowserTarget target,
  BrowserOpenContext context,
) async {
  switch (target) {
    case ClientPortTarget(:final host, :final port, :final initialUri):
      return BrowserChannel(
        internalUri: initialUri,
        address: portAddress(host: host, port: port, uri: initialUri),
        close: () async {},
      );

    case ClientDirectoryTarget(:final path):
      final server = await LocalStaticServer.start(root: path);
      return BrowserChannel(
        internalUri: server.baseUri,
        address: path,
        close: server.close,
        staticServer: server,
      );

    case ServerPortTarget(:final path):
      final bridge = await ServerTunnelBridge.start(
        baseUrl: context.baseUrl,
        token: context.token,
        tlsFingerprint: context.tlsFingerprint,
        target: tunnelTarget(target),
      );
      // 桥接根是 `http://127.0.0.1:<随机端口>/`；初始路径要拼在它后面，
      // 否则 `localhost:3000/about` 会停在首页。
      final uri = path == '/'
          ? bridge.baseUri
          : bridge.baseUri.resolve(path.substring(1));
      return BrowserChannel(
        internalUri: uri,
        address: portAddress(host: target.host, port: target.port, uri: uri),
        close: bridge.close,
      );

    case InternetTarget(:final uri):
      return BrowserChannel(
        internalUri: uri,
        address: uri.toString(),
        close: () async {},
      );
  }
}

/// 测试用替身入口：控制器只依赖这个函数，不直接碰网络与磁盘。
final Provider<BrowserChannelOpener> browserChannelOpenerProvider =
    Provider<BrowserChannelOpener>((ref) => openBrowserChannel);

/// 每个浏览器标签一个会话：`tabId` 与 `FilePaneTabState.browserTabs` 里的元素同一口径。
///
/// 用 family 而不是"一个控制器管一个 Map"：标签栏、内容区、测试都按 id 取状态，
/// 各个标签的状态互不牵连——新建或关闭一个标签不会让其它标签的 WebView 重建。
final browserSessionProvider =
    NotifierProvider.family<BrowserController, BrowserSessionState, String>(
      BrowserController.new,
    );

/// 单页浏览器状态机。
///
/// 只做三件事：解析输入、准备/替换通道资源、把 WebView 的事件收敛成状态。
/// WebView 控制器本身留在视图层（平台视图不能放进 Riverpod）。
class BrowserController extends Notifier<BrowserSessionState> {
  BrowserController(this.tabId);

  /// 本会话所属的浏览器标签 id。只在排查通道问题时打日志用。
  final String tabId;

  BrowserChannel? _channel;
  int _attempt = 0;
  bool _disposed = false;

  @override
  BrowserSessionState build() {
    // 切工具标签、收起右栏都不该销毁会话：资源由本 provider 持有。
    ref.keepAlive();
    ref.onDispose(() {
      _disposed = true;
      unawaited(_release());
    });
    return const BrowserSessionState();
  }

  /// 选择来源徽标。只影响下一次解析，不主动导航。
  void selectSource(BrowserSource source) {
    state = state.copyWith(source: source);
  }

  /// 请求聚焦地址栏（从开始页进入时用）。
  void requestFocus() {
    state = state.copyWith(focusRequest: state.focusRequest + 1);
  }

  /// 放大一档。已在梯度顶端时不动，绝不回环到另一头。
  void zoomIn() {
    final next = nextBrowserZoom(state.zoom);
    if (next != null) {
      state = state.copyWith(zoom: next);
    }
  }

  /// 缩小一档。已在底端时不动。
  void zoomOut() {
    final previous = previousBrowserZoom(state.zoom);
    if (previous != null) {
      state = state.copyWith(zoom: previous);
    }
  }

  /// 回到 100%。已经在 100% 时不产生一次多余的状态更新。
  void resetZoom() {
    if (state.zoom != 1) {
      state = state.copyWith(zoom: 1);
    }
  }

  /// 解析输入并打开页面。
  ///
  /// [display] 是服务端给的"展示用地址"：预览站的真实 URL 里有随机端口与
  /// 访问令牌，地址栏该显示 `hello-demo/report.html` 这种可读值。
  /// 不传就按 [raw] 自己推导（手动输入与页内导航走这条）。
  Future<void> open(String raw, {String? display}) async {
    final target = parseBrowserInput(raw, source: state.source);
    if (target == null) {
      state = state.copyWith(
        loading: false,
        error: const BrowserFailure(
          kind: BrowserFailureKind.invalidInput,
          message: 'browser input cannot be parsed',
          hint:
              '地址无法识别：可以填端口（3000）、地址（localhost:5173）或完整链接（https://example.com）',
        ),
      );
      return;
    }

    // 启动瞬间会话可能还在加载：同步读会拿到 null，把"还没加载完"误报成"没配对"。
    var session = ref.read(sessionProvider).value;
    if (session == null || !session.isReady) {
      try {
        final resolved = await ref.read(sessionProvider.future);
        if (resolved.isReady) {
          session = resolved;
        }
      } on Object {
        // 落到下面的未就绪分支。
      }
    }
    if (session == null || !session.isReady) {
      state = state.copyWith(
        loading: false,
        error: const BrowserFailure(
          kind: BrowserFailureKind.unauthenticated,
          message: 'session is not ready',
          hint: '还没连上服务端：先完成配对与登录再使用浏览器',
        ),
      );
      return;
    }

    final attempt = ++_attempt;
    // 先放掉旧通道，避免"服务器 3000 → 服务器 8080"时两条隧道同时存在。
    // 但不立刻清掉 `internalUri`：WebView 保持挂载，等新地址就绪后原地 loadUrl，
    // 这样换地址时不会先闪一帧空白再重建平台视图。
    await _release();
    if (_disposed || attempt != _attempt) {
      return;
    }

    state = state.copyWith(
      source: target.source,
      target: target,
      address: display ?? target.address,
      addressOverride: display,
      clearAddressOverride: display == null,
      loading: true,
      progress: 0,
      canGoBack: false,
      canGoForward: false,
      clearError: true,
      // 换地址等于换页面：旧标题与旧图标立刻作废，别让标签先显示上一站的名字。
      clearTitle: true,
      clearFavicon: true,
      focusRequest: state.focusRequest,
    );

    try {
      final channel = await ref.read(browserChannelOpenerProvider)(
        target,
        BrowserOpenContext(
          baseUrl: session.serverUrl,
          token: session.token!,
          tlsFingerprint: session.serverTlsFingerprint,
        ),
      );
      if (_disposed || attempt != _attempt) {
        await channel.close();
        return;
      }
      _channel = channel;
      state = state.copyWith(
        internalUri: channel.internalUri,
        pageUri: channel.internalUri,
        // 新页面从通道的 origin 起步：图标下载结果回来时靠它判断是否还停在原页面。
        pageOrigin: channel.internalUri.origin,
        // 有展示地址就用它：通道给的地址里带着隧道随机端口，不是给人看的。
        address: display ?? (channel.address.isEmpty ? state.address : channel.address),
        addressOverride: display,
        loading: true,
        progress: 0,
        requestId: ++_requestId,
        clearError: true,
      );
    } on Object catch (error) {
      if (_disposed || attempt != _attempt) {
        return;
      }
      // 通道没建起来：清掉页面，只留目标与错误卡。重试会按 address 重新解析。
      state = BrowserSessionState(
        source: target.source,
        target: target,
        address: display ?? target.address,
        addressOverride: display,
        error: _failureFor(error),
        focusRequest: state.focusRequest,
        // 通道没建起来不该顺带把缩放丢掉：比例属于标签，不属于某一次加载。
        zoom: state.zoom,
      );
    }
  }

  /// 把当前客户端端口改从服务器打开（错误卡上的动作）。
  Future<void> openAsServer() async {
    final target = state.target;
    if (target is! ClientPortTarget) {
      return;
    }
    final address = '${hostPortText(target.host, target.port)}${target.path}';
    selectSource(BrowserSource.server);
    await open(address);
  }

  /// 用户点了「停止」：把界面从"加载中"收回来。
  ///
  /// `stopLoading()` 之后平台不会再发 `onLoadStop`，状态必须自己收尾——
  /// 否则点了叉照样转圈，看着像按钮坏了。
  void stopLoad() {
    if (!state.loading) {
      return;
    }
    state = state.copyWith(loading: false, progress: 1);
  }

  /// 主文档迟迟没有回音（视图层的看门狗触发）。
  ///
  /// 只认「还没开始渲染」这一种：一旦有了进度，长连接、SSE、没结束的 XHR
  /// 都是正常现象，不该被当成卡死。
  void reportStalled() {
    if (!state.loading || state.progress > 0.05) {
      return;
    }
    state = state.copyWith(
      loading: false,
      progress: 1,
      error: const BrowserFailure(
        kind: BrowserFailureKind.network,
        message: 'main frame stalled',
        hint: '页面一直没有响应：检查网络或代理后重试，或在系统浏览器里打开',
      ),
    );
  }

  /// 就地重新加载当前页面（刷新按钮、错误卡的「重试」）。
  ///
  /// 只递增请求号，具体加载哪个地址由视图层决定：它拿的是 [BrowserSessionState.pageUri]
  /// ——页内跳转后的当前地址，而不是通道的入口地址。
  void reload() {
    if (state.internalUri == null) {
      return;
    }
    state = state.copyWith(
      loading: true,
      progress: 0,
      requestId: ++_requestId,
      clearError: true,
    );
  }

  /// 换了一个全新的 WebView（渲染进程崩溃、错误卡重试）：平台视图的历史清零。
  ///
  /// 旧的 `canGoBack` / `canGoForward` 必须跟着作废，否则按钮亮着、点下去什么都不发生。
  void resetHistory() {
    if (!state.canGoBack && !state.canGoForward) {
      return;
    }
    state = state.copyWith(canGoBack: false, canGoForward: false);
  }

  /// WebView 事件回填：地址、标题、进度与前进后退可用性。
  ///
  /// [clearError] 给"新一次导航开始了 / 这一页已经画完了"用：上一页的失败记录
  /// 这时已经过期，留着它会用错误卡盖住正常加载出来的页面（后退、前进最常见）。
  void syncView({
    Uri? uri,
    String? title,
    bool? loading,
    double? progress,
    bool? canGoBack,
    bool? canGoForward,
    bool clearError = false,
  }) {
    // 页内跳到别的站点：旧站点的图标不能留在标签上。同源子页面共用一张图标，
    // 所以只按 origin 判断，不因为换了个 path 就把图标清掉。
    final staleIcon = uri != null && uri.origin != state.faviconOrigin;
    state = state.copyWith(
      // 页内跳转后这里就是"刷新要回到的那一页"。
      pageUri: uri,
      address: uri == null ? null : displayAddress(uri),
      title: title,
      loading: loading,
      progress: progress,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      pageOrigin: uri?.origin,
      clearFavicon: staleIcon,
      clearError: clearError,
    );
  }

  /// 回填页面标题。空串归一成 null，标签会退回域名而不是显示一行空白。
  void syncTitle(String? title) {
    final text = title?.trim();
    state = state.copyWith(
      title: text == null || text.isEmpty ? null : text,
      clearTitle: text == null || text.isEmpty,
    );
  }

  /// 回填站点图标。
  ///
  /// [page] 是抓图时所在的页面：请求回来时用户可能已经跳到别的站点，
  /// origin 对不上的旧图标一律丢弃，否则新页面会顶着上一站的图标。
  void syncFavicon(Uint8List? bytes, {required Uri page}) {
    // `pageOrigin` 由页内导航回填；首屏还没收到导航事件时退到通道 origin。
    final current = state.pageOrigin ?? state.internalUri?.origin;
    if (_disposed || current != page.origin) {
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      state = state.copyWith(clearFavicon: true);
      return;
    }
    state = state.copyWith(favicon: bytes, faviconOrigin: page.origin);
  }

  /// 主框架加载失败。子资源失败不进来：一行图片挂掉不该盖住整页。
  void reportError(String description) {
    state = state.copyWith(
      loading: false,
      progress: 1,
      error: BrowserFailure(
        kind: BrowserFailureKind.network,
        message: description,
        hint: '页面加载失败：检查地址、服务端状态或网络后重试',
      ),
    );
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// 把一个标签的会话重置成空白页：释放通道、作废在飞的加载，状态回到初始值。
  ///
  /// 关标签走的是销毁 provider（`onDispose` 里同样会释放），这条路留给
  /// "标签留着但用户要一键清空这一页"的场景与测试。
  Future<void> closeSession() async {
    _attempt++;
    await _release();
    state = const BrowserSessionState();
  }

  /// 把内部 URL 还原成地址栏显示的逻辑地址。
  ///
  /// 桥接页的 origin 是 `127.0.0.1:<随机端口>`；如果页面被导航到了外部站点，
  /// 就如实显示外部地址，不硬套 `localhost:<目标端口>`。
  String displayAddress(Uri uri) {
    final internal = state.internalUri;

    // 服务端给的展示地址只在**入口页**生效：预览站的真实地址里有随机端口
    // 与访问令牌，换成可读标签是必要的；但页内跳转之后，"现在在哪"
    // 只能按实际地址回答，硬套展示值会让用户以为还停在首页。
    final override = state.addressOverride;
    if (override != null && internal != null && uri == internal) {
      return override;
    }

    final sameOrigin = internal == null || uri.origin == internal.origin;

    switch (state.target) {
      case ServerPortTarget(:final host, :final port):
        return sameOrigin
            ? portAddress(host: host, port: port, uri: uri)
            : uri.toString();
      case ClientPortTarget(:final host, :final port):
        return sameOrigin
            ? portAddress(host: host, port: port, uri: uri)
            : uri.toString();
      case ClientDirectoryTarget(:final path):
        if (!sameOrigin) {
          return uri.toString();
        }
        final suffix = _channel?.staticServer?.displayPath(uri) ?? '/';
        return suffix == '/' ? path : '$path$suffix';
      case InternetTarget():
        return uri.toString();
      case null:
        return uri.toString();
    }
  }

  Future<void> _release() async {
    final channel = _channel;
    _channel = null;
    if (channel == null) {
      return;
    }
    try {
      await channel.close();
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('释放浏览器通道失败（$tabId）：$error');
      }
    }
  }

  BrowserFailure _failureFor(Object error) {
    if (error is ServerTunnelException) {
      return switch (error.failure) {
        ServerTunnelFailure.denied => BrowserFailure(
          kind: BrowserFailureKind.targetDenied,
          message: error.message,
          hint: '该端口未被服务端允许：在服务端配置的 browser.allowed_ports 里加上它后重启',
        ),
        ServerTunnelFailure.unavailable => BrowserFailure(
          kind: BrowserFailureKind.unavailable,
          message: error.message,
          hint: '服务端连不上这个端口：确认对应服务已启动，或检查 browser.enabled 是否打开',
        ),
        ServerTunnelFailure.unauthenticated => BrowserFailure(
          kind: BrowserFailureKind.unauthenticated,
          message: error.message,
          hint: '登录已失效：回到设置页重新登录后再试',
        ),
        ServerTunnelFailure.network => BrowserFailure(
          kind: BrowserFailureKind.network,
          message: error.message,
          hint: '连不上服务端：检查服务地址与网络后重试',
        ),
      };
    }
    if (error is LocalStaticException) {
      return BrowserFailure(
        kind: BrowserFailureKind.localFile,
        message: error.message,
        hint: '这个目录读不了：换一个目录再试',
      );
    }
    return BrowserFailure(
      kind: BrowserFailureKind.network,
      message: error.toString(),
      hint: '浏览器打开失败：检查地址后重试',
    );
  }

  int _requestId = 0;
}
