import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 产物导出的结果。取消不是错误，调用方据此决定要不要提示。
enum ExportOutcome { saved, shared, cancelled }

class ExportResult {
  const ExportResult(this.outcome, {this.path});

  const ExportResult.cancelled() : this(ExportOutcome.cancelled);

  final ExportOutcome outcome;

  /// 仅桌面"另存为"有值。
  final String? path;
}

/// 产物导出。
///
/// 为什么必须抽象：桌面用系统保存对话框，手机没有"选目录"这回事
/// （`file_selector` 的 `getSaveLocation` 在 Android/iOS 根本没有实现），
/// 只能交给系统分享面板。平台判断收在 [createArtifactExporter] 一处，
/// 页面只认这个接口。
abstract class ArtifactExporter {
  Future<ExportResult> export({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  });
}

/// 桌面：系统保存对话框（用户自己选位置）。
class DesktopArtifactExporter implements ArtifactExporter {
  const DesktopArtifactExporter();

  @override
  Future<ExportResult> export({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  }) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) {
      return const ExportResult.cancelled();
    }
    await File(location.path).writeAsBytes(bytes);
    return ExportResult(ExportOutcome.saved, path: location.path);
  }
}

/// 移动端：写到哪里由系统决定，用户通过分享面板存到"文件"、相册或发给其他应用。
class MobileArtifactExporter implements ArtifactExporter {
  const MobileArtifactExporter();

  @override
  Future<ExportResult> export({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$suggestedName');
    await file.writeAsBytes(bytes, flush: true);

    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: mime)],
        fileNameOverrides: <String>[suggestedName],
        // iPad / macOS 上分享面板需要一个锚点矩形，否则会抛异常。
        sharePositionOrigin: shareOrigin,
      ),
    );
    return const ExportResult(ExportOutcome.shared);
  }
}

ArtifactExporter createArtifactExporter({TargetPlatform? platform}) {
  final target = platform ?? defaultTargetPlatform;
  return switch (target) {
    TargetPlatform.android ||
    TargetPlatform.iOS => const MobileArtifactExporter(),
    _ => const DesktopArtifactExporter(),
  };
}

final Provider<ArtifactExporter> artifactExporterProvider =
    Provider<ArtifactExporter>((ref) => createArtifactExporter());

/// 由 mime 推导文件后缀；未知类型给 `.bin` 而不是猜一个可能错的后缀。
String extensionForMime(String mime) {
  return switch (mime.split(';').first.trim()) {
    'text/plain' => '.txt',
    'text/markdown' => '.md',
    'application/json' => '.json',
    'image/png' => '.png',
    'image/jpeg' => '.jpg',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'video/mp4' => '.mp4',
    // 另外三种容器 media_kit 直接能播：后缀认错会让用户拿到的文件
    // 在自己的播放器里打不开，而内容其实完全正常。
    'video/quicktime' => '.mov',
    'video/webm' => '.webm',
    'video/x-matroska' => '.mkv',
    'application/pdf' => '.pdf',
    _ => '.bin',
  };
}

/// 产物落盘时的建议文件名。
String artifactFileName({
  required String kind,
  required String id,
  required String mime,
}) {
  final safeKind = kind.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return '$safeKind-$id${extensionForMime(mime)}';
}
