import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_error.dart';
import 'artifact_exporter.dart';
import 'models.dart';
import 'session.dart';

/// 产物保存的两个目标。
enum MediaSaveTarget {
  /// 服务端项目目录下的 `artifacts/`。
  project,

  /// 客户端所在设备（桌面系统保存框 / 移动端分享面板）。
  local,
}

extension MediaSaveTargetLabel on MediaSaveTarget {
  String get label => switch (this) {
    MediaSaveTarget.project => '保存到项目',
    MediaSaveTarget.local => '保存到本地',
  };
}

/// 保存到项目：返回 null 表示成功，否则是给命名框显示的失败原因。
///
/// 不抛异常：调用方是对话框，抛出去只会变成红屏，而"重名了，换个名字"
/// 恰恰要留在框里让用户直接改。
Future<String?> saveMediaToProject(
  BuildContext context,
  WidgetRef ref, {
  required String mediaId,
  required String name,
}) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return '服务未连接，无法保存到项目';
  }
  final messenger = ScaffoldMessenger.maybeOf(context);

  try {
    final result = await client.saveMediaToProject(mediaId, name);
    messenger?.showSnackBar(
      SnackBar(content: Text('已保存到项目：${result.path}')),
    );
    return null;
  } on ApiException catch (error) {
    // 409 重名 / 目录不可写都由服务端给出可执行文案，原样展示。
    return error.userMessage;
  }
}

/// 保存到本地：桌面弹系统保存框，移动端走系统分享面板。
///
/// 这条路径要把整片字节读进内存（系统保存框只接受字节），所以视频
/// 「存到本机」的成本比「存到项目」高一个数量级——文案上不说，但实现上
/// 不该顺手在预览时触发它。
Future<String?> saveMediaToLocal(
  BuildContext context,
  WidgetRef ref, {
  required MediaAsset asset,
  required String name,
}) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return '服务未连接，无法保存到本机';
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = _shareOrigin(context);

  try {
    final result = await client.getBytes(
      '/api/media/${Uri.encodeComponent(asset.id)}/content',
      query: const <String, String>{'download': 'true'},
    );
    final exported = await ref
        .read(artifactExporterProvider)
        .export(
          suggestedName: name,
          bytes: result.bytes,
          mime: asset.mime,
          shareOrigin: origin,
        );

    switch (exported.outcome) {
      case ExportOutcome.saved:
        messenger?.showSnackBar(
          SnackBar(content: Text('已保存到 ${exported.path}')),
        );
      case ExportOutcome.shared:
        messenger?.showSnackBar(
          const SnackBar(content: Text('已打开系统分享面板，选择保存位置')),
        );
      case ExportOutcome.cancelled:
        // 用户自己取消的：不要用 SnackBar 再打扰一次。
        break;
    }
    return null;
  } on ApiException catch (error) {
    return error.userMessage;
  } catch (error) {
    return '保存失败：$error';
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
