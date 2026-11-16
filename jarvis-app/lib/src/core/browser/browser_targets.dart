import 'dart:io';

import 'browser_models.dart';

/// 默认搜索引擎。首版固定 Bing：国内可直连，且不要求登录或 API Key。
Uri searchUri(String query) =>
    Uri.parse('https://www.bing.com/search')
        .replace(queryParameters: {'q': query});

/// 把地址栏输入解析成逻辑目标。纯函数，便于表驱动单测。
///
/// 规则与「浏览器界面规范」一致：
/// - `file://` / 绝对路径 / `~/` → 本机目录；
/// - 带 http(s) 的完整地址 → 互联网；
/// - `host:port` → 跟随来源徽标（本机直连 / 服务器隧道 / 互联网）；
/// - 纯数字 → 跟随来源徽标（默认徽标是「服务器」，所以 `3000` 默认走隧道）；
/// - 含空格的词 → 搜索引擎；
/// - 其余（带点或不带点的主机名）→ 互联网，无协议补 https。
BrowserTarget? parseBrowserInput(String raw, {required BrowserSource source}) {
  final text = raw.trim();
  if (text.isEmpty) {
    return null;
  }

  if (text.startsWith('file://')) {
    final uri = Uri.tryParse(text);
    if (uri == null || uri.path.isEmpty) {
      return null;
    }
    return ClientDirectoryTarget(uri.toFilePath());
  }

  if (_looksLikePath(text)) {
    return ClientDirectoryTarget(_expandHome(text));
  }

  final absolute = Uri.tryParse(text);
  if (absolute != null &&
      (absolute.scheme == 'http' || absolute.scheme == 'https') &&
      absolute.host.isNotEmpty) {
    return InternetTarget(absolute);
  }

  final parsed = _splitHostPort(text);
  if (parsed != null) {
    if (parsed.port <= 0 || parsed.port > 65535) {
      return null;
    }
    return switch (source) {
      BrowserSource.client => ClientPortTarget(
        host: parsed.host,
        port: parsed.port,
        path: parsed.path,
      ),
      BrowserSource.server => ServerPortTarget(
        host: parsed.host,
        port: parsed.port,
        path: parsed.path,
      ),
      BrowserSource.internet => InternetTarget(
        Uri.parse(
          'http://${hostPortText(parsed.host, parsed.port)}${parsed.path}',
        ),
      ),
    };
  }

  if (RegExp(r'^\d{1,5}$').hasMatch(text)) {
    final port = int.parse(text);
    if (port <= 0 || port > 65535) {
      return null;
    }
    return switch (source) {
      BrowserSource.client => ClientPortTarget(host: '127.0.0.1', port: port),
      BrowserSource.server => ServerPortTarget(host: '127.0.0.1', port: port),
      // 纯端口在互联网来源下没有意义：当作搜索词，避免打开一个必然失败的地址。
      BrowserSource.internet => InternetTarget(searchUri(text)),
    };
  }

  if (text.contains(' ')) {
    return InternetTarget(searchUri(text));
  }

  final host = text == 'localhost' ? 'http://$text' : 'https://$text';
  final uri = Uri.tryParse(host);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  return InternetTarget(uri);
}

/// 把服务端目标拼成隧道需要的 `host:port`；IPv6 必须加方括号。
String tunnelTarget(ServerPortTarget target) {
  final host = target.host.contains(':') ? '[${target.host}]' : target.host;
  return '$host:${target.port}';
}

/// 本机地址的主机名。这些地址指向"跑着服务的那台机器"，不是客户端自己。
const Set<String> _loopbackHosts = <String>{
  'localhost',
  '127.0.0.1',
  '::1',
  '0.0.0.0',
};

/// 把工具给的完整地址转成地址栏输入。
///
/// `preview_url` 给的是 `http://localhost:3000/` 这种完整 URL，直接喂给
/// [parseBrowserInput] 会被当成"互联网"直连；而 dev server 通常跑在**服务端**
/// 机器上，手机的 WebView 直连 localhost 只会连到手机自己。本机地址因此去掉
/// scheme，交给 `host:port` 分支按来源徽标分流（默认走服务器隧道）。
///
/// 非本机地址原样返回：公网页面就该直连。
String browserInputFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_loopbackHosts.contains(uri.host)) {
    return url;
  }

  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  final path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '$host:$port$path$query';
}

bool _looksLikePath(String text) {
  if (text.startsWith('/') || text.startsWith('~/')) {
    return true;
  }
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(text);
}

String _expandHome(String path) {
  if (!path.startsWith('~/')) {
    return path;
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return path;
  }
  return '$home${path.substring(1)}';
}

/// 拆 `host:port[/path]`，支持 `[::1]:3000`。
///
/// 地址栏显示的是逻辑地址，用户很可能把 `localhost:3000/about` 再粘回来；
/// 这里必须把路径一起留下，否则会被当成"域名 + 端口"再补一个 `https://`。
({String host, int port, String path})? _splitHostPort(String raw) {
  final match = RegExp(r'^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._\-]+):(\d{1,5})(.*)$')
      .firstMatch(raw);
  if (match == null) {
    return null;
  }

  final rawHost = match.group(1)!;
  final host = rawHost.startsWith('[')
      ? rawHost.substring(1, rawHost.length - 1)
      : rawHost;
  final port = int.tryParse(match.group(2)!);
  if (port == null) {
    return null;
  }

  final rest = match.group(3)!;
  if (rest.isEmpty) {
    return (host: host, port: port, path: '/');
  }
  if (rest.startsWith('/') || rest.startsWith('?') || rest.startsWith('#')) {
    return (
      host: host,
      port: port,
      path: rest.startsWith('/') ? rest : '/$rest',
    );
  }
  return null;
}
