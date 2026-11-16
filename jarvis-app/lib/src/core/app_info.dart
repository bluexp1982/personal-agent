import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 运行中客户端自己的版本信息。
///
/// 取自安装包（`pubspec.yaml` 的 `version: x.y.z+build` 会写进各平台产物），
/// 而不是 Lua 常量：发版只改 pubspec，界面自动跟着变，不会出现"改了清单却
/// 忘了改 Dart 常量"的漂移。
@immutable
class AppBuildInfo {
  const AppBuildInfo({required this.version, this.buildNumber = ''});

  /// 语义版本，例如 `0.13.0`。
  final String version;

  /// 构建号，例如 `1`；部分平台可能为空串。
  final String buildNumber;

  /// 界面展示用：`0.13.0 (1)`，没有构建号时只显示版本。
  String get display =>
      buildNumber.isEmpty ? version : '$version ($buildNumber)';
}

/// 安装包版本。
///
/// 走 `FutureProvider` 而不是每次在 widget 里 `await`：设置弹窗反复开关、
/// 多栏切换都会读同一份缓存，插件调用只在进程里发生一次。
final FutureProvider<AppBuildInfo> appBuildInfoProvider =
    FutureProvider<AppBuildInfo>((ref) async {
      final info = await PackageInfo.fromPlatform();
      return AppBuildInfo(version: info.version, buildNumber: info.buildNumber);
    });
