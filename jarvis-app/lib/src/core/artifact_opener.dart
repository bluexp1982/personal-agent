import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 打开产物之后的实际结果。
///
/// 移动端没有"用其他应用打开"的稳定通道，只能弹系统分享面板；这不是降级，
/// 而是平台本身的口径——把两种结果分开报，调用方才能给出准确的提示。
enum OpenOutcome { opened, shared }

/// 把产物交给系统去打开（视频用默认播放器、图片用默认看图工具）。
///
/// 与 `ArtifactExporter` 的分工：那个是"保存/分享一份副本"，这个是
/// "现在就用系统应用打开它"。桌面写临时文件再拉起默认程序，移动端退回分享面板。
abstract class ArtifactOpener {
  Future<OpenOutcome> open({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  });
}

/// 平台 → 拉起默认程序的命令行。
///
/// 抽成纯函数是为了能单测：真正 `Process.run` 在测试里既慢又依赖系统。
/// 返回 null 表示这个平台没有命令行通道（移动端走分享面板）。
List<String>? openCommandFor(TargetPlatform platform, String path) {
  return switch (platform) {
    // `open` 会用文件关联的默认程序，比 `start` 的参数怪癖少。
    TargetPlatform.macOS => <String>['open', path],
    TargetPlatform.linux => <String>['xdg-open', path],
    // `start` 的第一个引号参数是窗口标题，占位给空串，否则路径被当成标题。
    TargetPlatform.windows => <String>['cmd', '/c', 'start', '', path],
    TargetPlatform.android || TargetPlatform.iOS => null,
    _ => null,
  };
}

/// 桌面：写临时文件 → 用系统默认程序打开。
class DesktopArtifactOpener implements ArtifactOpener {
  const DesktopArtifactOpener({this.platform});

  /// 测试可注入；为空时取当前平台。
  final TargetPlatform? platform;

  @override
  Future<OpenOutcome> open({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  }) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$suggestedName');
    await file.writeAsBytes(bytes, flush: true);

    final command = openCommandFor(platform ?? defaultTargetPlatform, file.path);
    if (command == null) {
      // 理论上到不了：真到了就说明平台判断变了，交给分享面板兜底比报错好。
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: mime)],
          fileNameOverrides: <String>[suggestedName],
          sharePositionOrigin: shareOrigin,
        ),
      );
      return OpenOutcome.shared;
    }

    final result = await Process.run(command.first, command.sublist(1));
    if (result.exitCode != 0) {
      throw ProcessException(
        command.first,
        command.sublist(1),
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return OpenOutcome.opened;
  }
}

/// 移动端：没有"用其他应用打开"的稳定通道，交给系统分享面板。
class MobileArtifactOpener implements ArtifactOpener {
  const MobileArtifactOpener();

  @override
  Future<OpenOutcome> open({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  }) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$suggestedName');
    await file.writeAsBytes(bytes, flush: true);

    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: mime)],
        fileNameOverrides: <String>[suggestedName],
        // iPad / macOS 上分享面板需要锚点，否则会抛异常。
        sharePositionOrigin: shareOrigin,
      ),
    );
    return OpenOutcome.shared;
  }
}

ArtifactOpener createArtifactOpener({TargetPlatform? platform}) {
  final target = platform ?? defaultTargetPlatform;
  return switch (target) {
    TargetPlatform.android || TargetPlatform.iOS => const MobileArtifactOpener(),
    _ => DesktopArtifactOpener(platform: target),
  };
}

final Provider<ArtifactOpener> artifactOpenerProvider =
    Provider<ArtifactOpener>((ref) => createArtifactOpener());
