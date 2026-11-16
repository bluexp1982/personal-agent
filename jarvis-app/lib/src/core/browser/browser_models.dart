import 'package:flutter/foundation.dart';

/// 浏览器页面的来源。
///
/// 三个来源决定"地址怎么变成 WebView 能打开的 URL"：
/// - [client]：客户端本机的端口或目录；
/// - [server]：服务端本机的端口（经 WebSocket 隧道）；
/// - [internet]：客户端直接访问互联网。
enum BrowserSource { client, server, internet }

extension BrowserSourceLabel on BrowserSource {
  String get label => switch (this) {
    BrowserSource.client => '本机',
    BrowserSource.server => '服务器',
    BrowserSource.internet => '互联网',
  };
}

/// 拼 `host:port`。IPv6 必须加方括号，否则 `Uri.parse` 会把冒号当成坏端口。
String hostPortText(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// 把「端口 + 内部 URL」还原成地址栏要显示的逻辑地址。
///
/// 桥接页在 WebView 里是 `http://127.0.0.1:<随机端口>/path`，但用户不该看到
/// 这个内部端口：地址栏统一显示 `localhost:3000/path`。
String portAddress({
  required String host,
  required int port,
  required Uri uri,
}) {
  final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  final fragment = uri.hasFragment ? '#${uri.fragment}' : '';
  return '${displayHostPort(host, port)}$path$query$fragment';
}

/// 回环地址统一显示成 `localhost`：桥接端口本身不展示，用户认知里只有本地服务。
String displayHost(String host) =>
    (host == '127.0.0.1' || host == '::1' || host == 'localhost')
    ? 'localhost'
    : host;

/// `host:port` 的用户视角写法（IPv6 补方括号）。
String displayHostPort(String host, int port) =>
    hostPortText(displayHost(host), port);

/// 标签上显示的名字。空白标签给固定文案，读不到标题就退回域名。
const String kBrowserBlankTabLabel = '新标签页';

/// 没有标题时的兜底名字：端口目标给 `localhost:5173`，目录给末段，互联网给域名。
String? browserHostLabel(BrowserTarget? target) => switch (target) {
  ServerPortTarget(:final host, :final port) ||
  ClientPortTarget(:final host, :final port) => displayHostPort(host, port),
  ClientDirectoryTarget(:final path) => directoryName(path),
  InternetTarget(:final uri) => uri.host.isEmpty ? null : uri.host,
  null => null,
};

/// `path` 的最后一段（目录名）。根目录本身没有名字，返回 null。
String? directoryName(String path) {
  final parts = path
      .split(RegExp(r'[/\\]'))
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? null : parts.last;
}

/// 面板标签上的文字：页面标题 → 域名 → 「新标签页」。
///
/// 做成纯函数是因为标签栏、测试与后续可能的命令面板都要同一套口径，
/// 而这几条回退规则放进 widget 里就只能靠界面测试去验证。
String browserTabLabel(BrowserSessionState state) {
  final title = state.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  if (state.internalUri == null) {
    return kBrowserBlankTabLabel;
  }
  return browserHostLabel(state.target) ?? '浏览器';
}

/// 逻辑目标。真正的 `internalUri` 由通道层生成，界面只用逻辑地址。
@immutable
sealed class BrowserTarget {
  const BrowserTarget();

  BrowserSource get source;

  /// 地址栏里显示的值（页面内导航后由控制器按内部 URL 反解）。
  String get address;
}

/// 客户端本机端口，例如本机的 Vite `localhost:5173`。
final class ClientPortTarget extends BrowserTarget {
  const ClientPortTarget({
    required this.host,
    required this.port,
    this.path = '/',
  });

  final String host;
  final int port;

  /// 首次加载的路径（含查询与片段），默认根路径。
  final String path;

  Uri get initialUri => Uri.parse('http://${hostPortText(host, port)}$path');

  @override
  BrowserSource get source => BrowserSource.client;

  @override
  String get address => portAddress(host: host, port: port, uri: initialUri);

  @override
  bool operator ==(Object other) =>
      other is ClientPortTarget &&
      other.host == host &&
      other.port == port &&
      other.path == path;

  @override
  int get hashCode => Object.hash(BrowserSource.client, host, port, path);
}

/// 客户端本机目录：由回环静态服务托管，避免 `file://` 的 CORS 与沙箱限制。
final class ClientDirectoryTarget extends BrowserTarget {
  const ClientDirectoryTarget(this.path);

  final String path;

  @override
  BrowserSource get source => BrowserSource.client;

  @override
  String get address => path;

  @override
  bool operator ==(Object other) =>
      other is ClientDirectoryTarget && other.path == path;

  @override
  int get hashCode => Object.hash(BrowserSource.client, path);
}

/// 服务端本机端口，经 `/api/browser/tunnel` 隧道访问。
final class ServerPortTarget extends BrowserTarget {
  const ServerPortTarget({
    required this.host,
    required this.port,
    this.path = '/',
  });

  final String host;
  final int port;

  /// 首次加载的路径（含查询与片段），默认根路径。
  final String path;

  Uri get initialUri => Uri.parse('http://${hostPortText(host, port)}$path');

  @override
  BrowserSource get source => BrowserSource.server;

  @override
  String get address => portAddress(host: host, port: port, uri: initialUri);

  @override
  bool operator ==(Object other) =>
      other is ServerPortTarget &&
      other.host == host &&
      other.port == port &&
      other.path == path;

  @override
  int get hashCode => Object.hash(BrowserSource.server, host, port, path);
}

/// 互联网地址。直接交给 WebView，用客户端自己的网络出口。
final class InternetTarget extends BrowserTarget {
  const InternetTarget(this.uri);

  final Uri uri;

  @override
  BrowserSource get source => BrowserSource.internet;

  @override
  String get address => uri.toString();

  @override
  bool operator ==(Object other) => other is InternetTarget && other.uri == uri;

  @override
  int get hashCode => Object.hash(BrowserSource.internet, uri);
}

/// 失败归类。界面据此决定展示哪几个动作，而不是把所有失败都叫"网络错误"。
enum BrowserFailureKind {
  invalidInput,

  /// 目标不在服务端白名单，或不是回环地址。
  targetDenied,

  /// 服务端没开浏览器隧道，或目标端口拒连。
  unavailable,

  /// 配对失效，需要重新登录。
  unauthenticated,

  /// 客户端本地目录不可读。
  localFile,

  /// 其余网络/平台问题。
  network,
}

@immutable
class BrowserFailure {
  const BrowserFailure({
    required this.kind,
    required this.message,
    required this.hint,
  });

  final BrowserFailureKind kind;

  /// 面向开发者的一句话，用于日志与排查。
  final String message;

  /// 面向用户、可直接展示的一句话。
  final String hint;

  bool get canRetry =>
      kind == BrowserFailureKind.unavailable ||
      kind == BrowserFailureKind.network;

  bool get canSwitchToServer =>
      kind == BrowserFailureKind.unavailable ||
      kind == BrowserFailureKind.network;
}

/// 一个浏览器标签的会话状态：一个地址、一份历史、一个 WebView。
///
/// 多标签不在这里表达——标签集合与顺序在 `filePaneTabProvider` 里，
/// 每个标签按 id 各持一份本状态。
@immutable
class BrowserSessionState {
  const BrowserSessionState({
    this.source = BrowserSource.server,
    this.target,
    this.internalUri,
    this.pageUri,
    this.address = '',
    this.addressOverride,
    this.title,
    this.loading = false,
    this.progress = 0,
    this.zoom = 1,
    this.canGoBack = false,
    this.canGoForward = false,
    this.error,
    this.requestId = 0,
    this.focusRequest = 0,
    this.favicon,
    this.faviconOrigin,
    this.pageOrigin,
  });

  /// 地址栏徽标当前选中的来源；打开页面后会跟随实际目标。
  final BrowserSource source;

  final BrowserTarget? target;

  /// 通道搭好时的入口地址。桥接端口只存在这里，不展示。
  ///
  /// 一次打开只写一次：地址栏的显示换算（`displayAddress`）靠它判断"是不是还在
  /// 桥接页里"，所以它不能跟着页内跳转走。
  final Uri? internalUri;

  /// WebView 此刻真正的地址：页内跳转、pushState 之后会跟着变。
  ///
  /// 刷新、重建 WebView、在系统浏览器打开都要用它而不是 [internalUri]——
  /// 后者永远停在最初那一页，照它刷新就会"显示的是新地址、回去的是老地址"。
  final Uri? pageUri;

  /// 地址栏显示的文本（逻辑地址）。
  final String address;

  /// 服务端给的"展示用地址"（项目名 + 相对路径、运行目标名等）。
  ///
  /// 只在**入口页**生效：预览站的真实 URL 里带随机端口与访问令牌，
  /// 地址栏显示它既难读、又等于把令牌摊在用户面前。页内跳转后
  /// 由 [`BrowserController.displayAddress`] 按实际地址接管。
  final String? addressOverride;

  final String? title;
  final bool loading;
  final double progress;

  /// 页面缩放比例（1 = 100%）。
  ///
  /// 记在会话里而不是视图里：切标签、收起右栏都不该把比例忘掉；
  /// 页内跳转、刷新、重载也保持。关标签时整个 provider 被 invalidate，
  /// 于是自然回到 100%——这正是"只记当前标签页"的口径。
  final double zoom;

  final bool canGoBack;
  final bool canGoForward;
  final BrowserFailure? error;

  /// 站点图标（favicon）字节。取不到就是 null，界面退回地球图标。
  ///
  /// 直接存字节而不是 URL：图标可能来自隧道端口或 data URI，标签栏没法自己下载，
  /// 而且同一张图在多个标签间共享同一个 `Uint8List` 实例，`Image.memory` 才不会重复解码。
  final Uint8List? favicon;

  /// [favicon] 所属页面的 origin。页内跳到别的站点后旧图标必须失效，
  /// 但同源子页面共用一张图标，所以用 origin 而不是完整 URL 作判据。
  final String? faviconOrigin;

  /// 当前页面所在的 origin（页内导航会跟着变）。
  ///
  /// 与 [faviconOrigin] 分开：前者是"现在在哪"，后者是"图标是哪一站的"。
  /// 图标异步回来时要拿它对一下，否则上一站的结果会贴到新页面上。
  final String? pageOrigin;

  /// 每次发起一次新的加载就加一。视图据此判断"要不要重新 loadUrl"，
  /// 而不是监听 `internalUri`——同一个地址刷新时 URI 不变。
  final int requestId;

  /// 「从开始页进入浏览器」时请求聚焦地址栏。
  final int focusRequest;

  bool get hasPage => internalUri != null;

  bool get isEmpty => target == null && internalUri == null && error == null;

  BrowserSessionState copyWith({
    BrowserSource? source,
    BrowserTarget? target,
    Uri? internalUri,
    Uri? pageUri,
    String? address,
    String? addressOverride,
    String? title,
    bool? loading,
    double? progress,
    double? zoom,
    bool? canGoBack,
    bool? canGoForward,
    BrowserFailure? error,
    int? requestId,
    int? focusRequest,
    Uint8List? favicon,
    String? faviconOrigin,
    String? pageOrigin,
    bool clearError = false,
    bool clearPage = false,
    bool clearTitle = false,
    bool clearFavicon = false,
    bool clearAddressOverride = false,
  }) {
    final dropFavicon = clearPage || clearFavicon;
    final dropOverride = clearPage || clearAddressOverride;
    return BrowserSessionState(
      source: source ?? this.source,
      target: clearPage ? null : (target ?? this.target),
      internalUri: clearPage ? null : (internalUri ?? this.internalUri),
      pageUri: clearPage ? null : (pageUri ?? this.pageUri),
      address: clearPage ? '' : (address ?? this.address),
      addressOverride: dropOverride
          ? null
          : (addressOverride ?? this.addressOverride),
      title: clearPage || clearTitle ? null : (title ?? this.title),
      loading: loading ?? this.loading,
      progress: progress ?? this.progress,
      zoom: zoom ?? this.zoom,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      error: clearError ? null : (error ?? this.error),
      requestId: requestId ?? this.requestId,
      focusRequest: focusRequest ?? this.focusRequest,
      favicon: dropFavicon ? null : (favicon ?? this.favicon),
      faviconOrigin: dropFavicon ? null : (faviconOrigin ?? this.faviconOrigin),
      pageOrigin: clearPage ? null : (pageOrigin ?? this.pageOrigin),
    );
  }
}
