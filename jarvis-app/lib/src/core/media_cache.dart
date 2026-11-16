import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'api_error.dart';
import 'session.dart';

/// 视频来源的两条路：项目文件树里的视频、会话产物里的视频。
///
/// 合并成一个 provider 而不是各写一份：两条路都是"按 id 取字节、落到临时文件、
/// 复用同一个文件"，差别只在端点与鉴权参数。
enum VideoSourceScope {
  /// `/api/projects/{id}/raw`：项目里的视频文件。
  projectFile,

  /// `/api/media/{id}/content`：文生视频的产物。
  conversationMedia,
}

/// 视频播放源的缓存键。
///
/// 用类而不是 Record：Record 里的 `Map` 没有值相等语义，
/// provider 会每次重建 key，临时文件复用就失效了。
class VideoSourceKey {
  const VideoSourceKey({
    required this.scope,
    required this.ownerId,
    required this.extension,
    this.path = '',
  });

  /// 项目文件：`ownerId` 是 projectId、`path` 是文件绝对路径。
  const VideoSourceKey.projectFile({
    required String projectId,
    required String path,
    required String extension,
  }) : this(
         scope: VideoSourceScope.projectFile,
         ownerId: projectId,
         path: path,
         extension: extension,
       );

  /// 会话产物：`ownerId` 是媒体 id。
  const VideoSourceKey.conversationMedia({
    required String mediaId,
    required String extension,
  }) : this(
         scope: VideoSourceScope.conversationMedia,
         ownerId: mediaId,
         path: '',
         extension: extension,
       );

  final VideoSourceScope scope;

  /// 项目 id 或媒体 id。
  final String ownerId;

  /// 项目文件绝对路径；会话产物为空。
  final String path;

  /// 缓存文件名后缀，含点（如 `.mp4`）。
  final String extension;

  @override
  bool operator ==(Object other) {
    return other is VideoSourceKey &&
        other.scope == scope &&
        other.ownerId == ownerId &&
        other.path == path &&
        other.extension == extension;
  }

  @override
  int get hashCode => Object.hash(scope, ownerId, path, extension);

  @override
  String toString() => 'VideoSourceKey(${scope.name}, $ownerId, $path)';
}

/// 视频播放源：下载到临时目录，返回一个可随机读取的本地文件。
///
/// 不走 `projectFileBytesProvider`：那个把整片字节放进内存，而视频还要
/// 求拖动进度——播放器需要的是文件，不是一段 `Uint8List`。
/// 同样不用 `getBytes`：几十 MB 在内存里复制一遍毫无收益。
final videoFileProvider = FutureProvider.autoDispose.family<File, VideoSourceKey>(
  (ref, key) async {
    final client = ref.watch(apiClientProvider);
    if (client == null) {
      throw _noClient();
    }

    final directory = await getTemporaryDirectory();
    final target = File('${directory.path}/jarvis-video/${_cacheName(key)}');

    return switch (key.scope) {
      VideoSourceScope.projectFile => client.downloadToFile(
        '/api/projects/${Uri.encodeComponent(key.ownerId)}/raw',
        target: target,
        // `download=true` 跳过 64 MB 查看器上限：上限的本意是拦住把大文件
        // 塞进内存，而视频本来就不进内存。超过上限就播不了没有道理。
        query: <String, String>{'path': key.path, 'download': 'true'},
      ),
      VideoSourceScope.conversationMedia => client.downloadToFile(
        '/api/media/${Uri.encodeComponent(key.ownerId)}/content',
        target: target,
        query: const <String, String>{'download': 'true'},
      ),
    };
  },
  // 下载失败通常是确定的（文件被删、越界、磁盘满），自动重试只会一直转圈。
  retry: (retryCount, error) => null,
);

/// 图片产物的字节：与视频不同，图片直接进内存交给 `Image.memory`，
/// 不需要落临时文件，也不需要随机读取。
///
/// `autoDispose`：关掉标签就释放几十 MB 的可能，与 `projectFileBytesProvider`
/// 同一口径（查看器只在标签活着时需要这些字节）。
final mediaImageBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, mediaId) async {
    final client = ref.watch(apiClientProvider);
    if (client == null) {
      throw _noClient();
    }
    final result = await client.getBytes(
      '/api/media/${Uri.encodeComponent(mediaId)}/content',
    );
    return result.bytes;
  },
  retry: (retryCount, error) => null,
);

/// 视频封面（生成时抽的第一帧）。
///
/// **拿不到是常态**：旧视频、服务端没装 ffmpeg、封面文件被清理都会 404。
/// 所以返回可空字节而不是抛错——封面只是卡片上的锦上添花，任何失败都退回
/// 播放图标占位块，不该在会话里弹一条错误。
final mediaPosterProvider = FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, mediaId) async {
    final client = ref.watch(apiClientProvider);
    if (client == null) {
      return null;
    }
    try {
      final result = await client.getBytes(
        '/api/media/${Uri.encodeComponent(mediaId)}/poster',
      );
      return result.bytes.isEmpty ? null : result.bytes;
    } on ApiException {
      return null;
    }
  },
  retry: (retryCount, error) => null,
);

/// 缓存文件名：路径可能很长且带分隔符，用哈希压成定长，
/// 后缀保留原扩展名，方便排查"这份缓存到底是什么"。
String _cacheName(VideoSourceKey key) {
  final digest = sha256
      .convert(utf8.encode('${key.scope.name}/${key.ownerId}/${key.path}'))
      .toString()
      .substring(0, 20);
  return '${key.scope.name}-$digest${_safeExtension(key.extension)}';
}

/// 只留 `[a-z0-9]` 且不超过 8 个字符：扩展名来自服务端返回的 mime 或文件名，
/// 不排除异常值，直接拼进路径会变成一次路径注入。
String _safeExtension(String raw) {
  final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.]'), '');
  if (!normalized.startsWith('.') || normalized.length < 2) {
    return '.bin';
  }
  return normalized.substring(0, normalized.length > 9 ? 9 : normalized.length);
}

/// 从文件路径里取扩展名（含点），取不到时给 `.bin`。
String videoExtensionOfPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return '.bin';
  }
  return name.substring(dot);
}

ApiException _noClient() {
  return const ApiException(
    code: 'unauthenticated',
    message: 'no client',
    retryable: false,
    hint: '尚未登录，请重新配对',
  );
}
