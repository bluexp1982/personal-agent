import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单张图标的大小上限。favicon 正常只有几 KB，超过这个量级的多半是
/// 被 302 到了某个 HTML 页面，没必要把整页字节读进内存。
const int kFaviconMaxBytes = 512 * 1024;

/// 单张图标的请求超时。图标只是锦上添花，卡住标签栏不值得。
const Duration kFaviconTimeout = Duration(seconds: 5);

/// 缓存条数。够覆盖一个工作日的站点集合，又不至于把图片堆在内存里。
const int kFaviconCacheSize = 64;

/// 页面声明的 icon href → 真正能下载的地址。
///
/// 取不到就退回同源 `/favicon.ico`（浏览器约定俗成的兜底位置）：
/// 大多数站点没写 `<link rel="icon">`，但根目录确实放着这张图。
///
/// 明确不可用的地址返回 null，交给界面回退地球图标：
/// - `svg` 能下载但 Flutter 解不了，与其塞进 `Image.memory` 触发异常，不如不给；
/// - 非 http(s)/data 的 scheme（`blob:`、`about:`）在 Dart 侧取不到字节。
Uri? browserFaviconUri(String? href, Uri page) {
  final raw = href?.trim() ?? '';
  if (raw.isEmpty) {
    return _fallbackIconUri(page);
  }

  final Uri resolved;
  try {
    resolved = page.resolve(raw);
  } on FormatException {
    return _fallbackIconUri(page);
  }

  switch (resolved.scheme) {
    case 'http':
    case 'https':
      return _isSvgPath(resolved.path) ? null : resolved;
    case 'data':
      return _isSvgMime(resolved.data?.mimeType) ? null : resolved;
    default:
      return null;
  }
}

/// `data:` 图标的内联字节。非图片或超限一律 null。
Uint8List? decodeFaviconDataUri(Uri icon) {
  if (icon.scheme != 'data') {
    return null;
  }
  try {
    final data = icon.data;
    if (data == null) {
      return null;
    }
    final mime = data.mimeType.toLowerCase();
    if (_isSvgMime(mime) || !mime.startsWith('image/')) {
      return null;
    }
    final bytes = data.contentAsBytes();
    if (bytes.isEmpty || bytes.length > kFaviconMaxBytes) {
      return null;
    }
    return bytes;
  } on Object {
    return null;
  }
}

Uri? _fallbackIconUri(Uri page) {
  if (page.scheme != 'http' && page.scheme != 'https') {
    return null;
  }
  return page.resolve('/favicon.ico');
}

bool _isSvgPath(String path) => path.toLowerCase().endsWith('.svg');

bool _isSvgMime(String? mime) => (mime ?? '').toLowerCase().contains('svg');

/// 图标下载入口。测试注入替身，生产走 `dart:io` 的 [HttpClient]。
///
/// 之所以能在 Dart 侧直接下载：通道层是本机 `127.0.0.1` 上的 TCP 监听
/// （桥接与静态服务都是），同源地址在客户端这边本来就通。
typedef FaviconFetcher = Future<Uint8List?> Function(Uri icon);

/// 站点图标下载 + LRU 缓存。
///
/// 命中时返回**同一个** [Uint8List] 实例：`MemoryImage` 按字节数组的引用相等，
/// 每次新建一份会让标签栏反复解码同一张图。
class BrowserFaviconLoader {
  BrowserFaviconLoader({
    this.fetcher,
    this.client,
    this.cacheSize = kFaviconCacheSize,
  });

  /// 注入的下载实现；为 null 时走内置的 HTTP 下载。
  final FaviconFetcher? fetcher;

  /// 注入的 HTTP 客户端；为 null 时每次请求自建一个用完即关。
  final HttpClient? client;

  final int cacheSize;

  /// 值为 null 表示"这张图确认取不到"，负缓存同样参与 LRU：
  /// 否则每次切标签都会重试一遍注定失败的请求。
  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};
  final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  Future<Uint8List?> load(Uri icon) {
    final key = icon.toString();
    if (_cache.containsKey(key)) {
      final hit = _cache.remove(key);
      _cache[key] = hit;
      return Future<Uint8List?>.value(hit);
    }

    final pending = _inflight[key];
    if (pending != null) {
      return pending;
    }

    final future = (fetcher ?? _download)(icon).then((bytes) {
      _remember(key, bytes);
      return bytes;
    });
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  void _remember(String key, Uint8List? bytes) {
    _cache[key] = bytes;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<Uint8List?> _download(Uri icon) async {
    if (icon.scheme == 'data') {
      return decodeFaviconDataUri(icon);
    }
    final http = client ?? (HttpClient()..connectionTimeout = kFaviconTimeout);
    final owned = client == null;
    try {
      final request = await http.getUrl(icon).timeout(kFaviconTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'image/*');
      final response = await request.close().timeout(kFaviconTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final type = (response.headers.contentType?.mimeType ?? '').toLowerCase();
      if (!type.startsWith('image/') || _isSvgMime(type)) {
        await response.drain<void>();
        return null;
      }
      return await _readCapped(response);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('取站点图标失败：$error');
      }
      return null;
    } finally {
      // 自建的 client 用完即关；外部传进来的由调用方负责。
      if (owned) {
        http.close(force: true);
      }
    }
  }

  Future<Uint8List?> _readCapped(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > kFaviconMaxBytes) {
        return null;
      }
    }
    final bytes = builder.takeBytes();
    return bytes.isEmpty ? null : bytes;
  }
}

final Provider<BrowserFaviconLoader> browserFaviconLoaderProvider =
    Provider<BrowserFaviconLoader>((ref) => BrowserFaviconLoader());
