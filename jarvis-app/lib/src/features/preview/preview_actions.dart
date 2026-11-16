import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/artifact_exporter.dart';
import '../../core/models.dart';
import '../../core/session.dart';

/// 把一个项目文件交给「另存为 / 系统分享」。
///
/// 走带 `download=true` 的原始字节端点：那个开关跳过 64 MB 查看器上限——
/// 大文件打不开，但应当存得下来（用户点的是"保存"，不是"预览"）。
///
/// 桌面弹系统保存框、手机推系统分享面板，平台差异全在
/// [createArtifactExporter] 那一处收敛，这里不判断平台。
///
/// 失败只用 SnackBar 提示，不抛给调用方：入口是工具栏上的一个按钮，
/// 抛出异常只会变成一次红屏，用户拿不到"为什么没存下来"。
Future<void> saveProjectFile(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  required String path,
}) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return;
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = _shareOrigin(context);

  try {
    final result = await client.getBytes(
      '/api/projects/${Uri.encodeComponent(projectId)}/raw',
      query: <String, String>{'path': path, 'download': 'true'},
    );
    final exported = await ref
        .read(artifactExporterProvider)
        .export(
          suggestedName: fileNameOf(path),
          bytes: result.bytes,
          // 类型缺失时给通用二进制，宁可让系统按扩展名判断，
          // 也不要自己编一个可能错的 image/*。
          mime: result.contentType ?? 'application/octet-stream',
          shareOrigin: origin,
        );
    if (exported.outcome == ExportOutcome.saved) {
      messenger?.showSnackBar(
        SnackBar(content: Text('已保存到 ${exported.path}')),
      );
    }
  } on ApiException catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(error.userMessage)));
  }
}

/// 把会话草稿里的生成文件交给「另存为 / 系统分享」。
///
/// 草案不在项目目录里，`/api/projects/{id}/raw` 够不着；服务端为这条路径
/// 单开了一个只读端点（`/api/conversations/{id}/draft-file`），语义与项目端点一致：
/// `download=true` 跳过查看器上限、附件头让系统保存框拿到正确文件名。
Future<void> saveDraftFile(
  BuildContext context,
  WidgetRef ref, {
  required String conversationId,
  required String path,
}) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return;
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = _shareOrigin(context);

  try {
    final result = await client.getBytes(
      '/api/conversations/${Uri.encodeComponent(conversationId)}/draft-file',
      query: <String, String>{'path': path, 'download': 'true'},
    );
    final exported = await ref
        .read(artifactExporterProvider)
        .export(
          suggestedName: fileNameOf(path),
          bytes: result.bytes,
          mime: result.contentType ?? 'application/octet-stream',
          shareOrigin: origin,
        );
    if (exported.outcome == ExportOutcome.saved) {
      messenger?.showSnackBar(
        SnackBar(content: Text('已保存到 ${exported.path}')),
      );
    }
  } on ApiException catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(error.userMessage)));
  }
}

/// iPad / macOS 上分享面板需要一个锚点矩形，否则会抛异常。
Rect? _shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}
