import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

class LocalStaticException implements Exception {
  const LocalStaticException(this.message);

  final String message;

  @override
  String toString() => 'LocalStaticException($message)';
}

/// 只读静态服务：把用户选中的目录挂到本机回环端口上。
///
/// 为什么不用 `file://`：
/// - WKWebView / WebView2 下 `file://` 的模块脚本与 `fetch` 会被 CORS 拒绝；
/// - macOS 沙箱需要用户授权目录，跨文件访问还有额外限制；
/// - 相对路径、目录首页这些行为在三个平台上不一致。
///
/// 安全边界：
/// - 只绑 `127.0.0.1`，且路径带一段随机前缀：本机其它进程扫不到内容；
/// - 只读、只允许 GET/HEAD；
/// - 拒绝 `..`、隐藏文件与指向根目录之外的符号链接。
class LocalStaticServer {
  LocalStaticServer._({
    required this._root,
    required this._token,
    required this._server,
  });

  final String _root;
  final String _token;
  final HttpServer _server;

  int get port => _server.port;

  Uri get baseUri => Uri.parse('http://127.0.0.1:$port/$_token/');

  static Future<LocalStaticServer> start({required String root}) async {
    final directory = Directory(root);
    if (!await directory.exists()) {
      throw LocalStaticException('目录不存在：$root');
    }
    final resolved = await directory.resolveSymbolicLinks();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = LocalStaticServer._(
      root: resolved,
      token: _randomToken(),
      server: server,
    );
    unawaited(instance._serve());
    return instance;
  }

  /// 把内部 URL 还原成"用户视角"的相对路径，供地址栏拼接。
  String displayPath(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first != _token) {
      return '/';
    }
    final rest = segments
        .skip(1)
        .where((segment) => segment.isNotEmpty)
        .toList();
    return rest.isEmpty ? '/' : '/${rest.join('/')}';
  }

  Future<void> _serve() async {
    try {
      await for (final request in _server) {
        unawaited(_handle(request));
      }
    } on Object {
      // 关闭时 `HttpServer` 会结束流；这里没有需要补救的动作。
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != _token) {
        await _notFound(response);
        return;
      }

      final rest = segments
          .skip(1)
          .where((segment) => segment.isNotEmpty)
          .toList();
      if (rest.any((segment) => segment == '..' || segment == '.')) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      if (rest.any((segment) => segment.startsWith('.'))) {
        // 隐藏文件（.env / .git / .ssh）永远不通过浏览器面板暴露。
        await _notFound(response);
        return;
      }

      final candidate = rest.isEmpty ? _root : p.join(_root, p.joinAll(rest));
      final resolved = await _resolve(candidate);
      if (resolved == null) {
        await _notFound(response);
        return;
      }
      if (!p.isWithin(_root, resolved) && resolved != _root) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }

      final type = await FileSystemEntity.type(resolved, followLinks: true);
      if (type == FileSystemEntityType.directory) {
        // 目录没有尾斜杠时先重定向：否则页面里的相对资源会按上一级解析。
        if (!request.uri.path.endsWith('/')) {
          response.statusCode = HttpStatus.movedPermanently;
          response.headers.set(
            HttpHeaders.locationHeader,
            '${request.uri.path}/${request.uri.hasQuery ? '?${request.uri.query}' : ''}',
          );
          await response.close();
          return;
        }
        final indexFile = File(p.join(resolved, 'index.html'));
        if (await indexFile.exists()) {
          await _sendFile(request, response, indexFile);
        } else {
          await _sendListing(request, response, rest);
        }
        return;
      }

      if (type == FileSystemEntityType.file) {
        await _sendFile(request, response, File(resolved));
        return;
      }

      await _notFound(response);
    } on Object {
      // 单次请求失败不该影响整个服务：能回 500 就回，不能就断开。
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } on Object {
        // 响应已关闭。
      }
    }
  }

  Future<String?> _resolve(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      return switch (type) {
        FileSystemEntityType.file => await File(path).resolveSymbolicLinks(),
        FileSystemEntityType.directory => await Directory(
          path,
        ).resolveSymbolicLinks(),
        FileSystemEntityType.link => await File(path).resolveSymbolicLinks(),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  Future<void> _sendFile(
    HttpRequest request,
    HttpResponse response,
    File file,
  ) async {
    final length = await file.length();
    response.headers.contentType = _contentTypeFor(file.path);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _sendListing(
    HttpRequest request,
    HttpResponse response,
    List<String> rest,
  ) async {
    final directory = Directory(
      rest.isEmpty ? _root : p.join(_root, p.joinAll(rest)),
    );
    final entries = await directory.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final title = rest.isEmpty ? _root : rest.last;
    final buffer = StringBuffer()
      ..writeln('<!doctype html><html><head><meta charset="utf-8">')
      ..writeln('<title>${_escape(title)}</title>')
      ..writeln(
        '<style>body{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#222}'
        'h1{font-size:16px;margin:0 0 12px}ul{list-style:none;padding:0}'
        'li{margin:6px 0}a{color:#0a58ca;text-decoration:none}a:hover{text-decoration:underline}'
        '.dir{font-weight:600}</style></head><body>',
      )
      ..writeln('<h1>${_escape(title)}</h1><ul>');
    if (rest.isNotEmpty) {
      buffer.writeln('<li><a href="../">../</a></li>');
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) {
        continue;
      }
      final isDir = entity is Directory;
      final suffix = isDir ? '/' : '';
      buffer.writeln(
        '<li><a class="${isDir ? 'dir' : ''}" href="${Uri.encodeComponent(name)}$suffix">'
        '${_escape(name)}$suffix</a></li>',
      );
    }
    buffer.writeln('</ul></body></html>');

    final bytes = utf8.encode(buffer.toString());
    response.headers.contentType = ContentType.html;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(bytes);
    await response.close();
  }

  Future<void> _notFound(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    response.headers.contentType = ContentType.text;
    response.write('404 Not Found');
    await response.close();
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  static String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static ContentType _contentTypeFor(String path) {
    final extension = p.extension(path).toLowerCase();
    return switch (extension) {
      '.html' || '.htm' => ContentType.html,
      '.css' => ContentType('text', 'css', charset: 'utf-8'),
      '.js' || '.mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
      '.json' || '.map' => ContentType.json,
      '.svg' => ContentType('image', 'svg+xml'),
      '.png' => ContentType('image', 'png'),
      '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
      '.gif' => ContentType('image', 'gif'),
      '.webp' => ContentType('image', 'webp'),
      '.ico' => ContentType('image', 'x-icon'),
      '.woff' => ContentType('font', 'woff'),
      '.woff2' => ContentType('font', 'woff2'),
      '.ttf' => ContentType('font', 'ttf'),
      '.otf' => ContentType('font', 'otf'),
      '.wasm' => ContentType('application', 'wasm'),
      '.txt' || '.md' => ContentType.text,
      '.pdf' => ContentType('application', 'pdf'),
      '.mp4' => ContentType('video', 'mp4'),
      '.webm' => ContentType('video', 'webm'),
      _ => ContentType.binary,
    };
  }

  static String _escape(String value) => const HtmlEscape().convert(value);
}
