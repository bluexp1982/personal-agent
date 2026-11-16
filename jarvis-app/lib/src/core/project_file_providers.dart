import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_error.dart';
import 'models.dart';
import 'session.dart';

/// 项目文件列表的缓存键。
///
/// `path` 为空表示「从项目根开始」：根路径由服务端解析并返回，
/// 客户端不拿 `Project.path` 自己拼，兼容 macOS 规范化与移动端。
typedef ProjectListingKey = ({
  String projectId,
  String path,
  bool showHidden,
});

/// 一层目录的内容。展开目录时才 watch，收起即停止监听。
final projectListingProvider =
    FutureProvider.family<ProjectListing, ProjectListingKey>((
      ref,
      key,
    ) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final json = await client.getJson(
        '/api/projects/${Uri.encodeComponent(key.projectId)}/files',
        query: <String, String>{
          if (key.path.isNotEmpty) 'path': key.path,
          if (key.showHidden) 'show_hidden': 'true',
        },
      );
      return ProjectListing.fromJson(json);
    }, retry: _noRetry);

typedef ProjectFileKey = ({String projectId, String path});

/// 文件内容。预览标签关闭后 autoDispose 释放，避免把大文本留在内存里。
final projectFileContentProvider = FutureProvider.autoDispose
    .family<FileContent, ProjectFileKey>((ref, key) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final json = await client.getJson(
        '/api/projects/${Uri.encodeComponent(key.projectId)}/file',
        query: <String, String>{'path': key.path},
      );
      return FileContent.fromJson(json);
    }, retry: _noRetry);

/// 文件原始字节：图片 / PDF 查看器的数据源。
///
/// 与文本内容共用同一个 key，但走 `/raw` 端点：那边是完整字节，这边有
/// 512 KB 截断与 UTF-8 校验，两者不能混。生命周期同样跟随标签：
/// 关掉即 autoDispose 释放，避免把几十 MB 的图/PDF 留在内存里。
final projectFileBytesProvider = FutureProvider.autoDispose
    .family<ProjectFileBytes, ProjectFileKey>((ref, key) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final result = await client.getBytes(
        '/api/projects/${Uri.encodeComponent(key.projectId)}/raw',
        query: <String, String>{'path': key.path},
      );
      return ProjectFileBytes(
        bytes: result.bytes,
        size: result.bytes.length,
        contentType: result.contentType,
      );
    }, retry: _noRetry);

/// 文件浏览失败是确定性的（越界、权限、二进制、目录被删），自动重试只会
/// 让界面停在转圈上；保留手动「重试」按钮，由用户决定何时再试。
Duration? _noRetry(int retryCount, Object error) => null;

ApiException _noClient() {
  return const ApiException(
    code: 'unauthenticated',
    message: 'no client',
    retryable: false,
    hint: '尚未登录，请重新配对',
  );
}
