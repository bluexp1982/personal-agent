import 'package:flutter/foundation.dart';

/// 平台差异的唯一事实源。
///
/// 手机与桌面在这个产品里有三处必须不同：**默认服务地址**、**设备名**、
/// **地址校验**。把它们写成纯函数（平台作为参数传入）而不是在页面里读
/// `Platform.isAndroid`，是为了能直接单测，也避免"某个页面忘了改"。
///
/// 桌面默认地址保持 `http://127.0.0.1:8787`：服务与客户端同机时明文回环是既有例外。
/// 手机上这个地址永远连不上——服务在另一台机器上，且非回环绑定会强制 TLS。
const String kDesktopServerUrl = 'http://127.0.0.1:8787';

bool isMobilePlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

/// 新建会话/配对页的初始服务地址。
String defaultServerUrl({required TargetPlatform platform}) =>
    isMobilePlatform(platform) ? '' : kDesktopServerUrl;

/// 与服务端 `pairing` 的 `platform` 字段对齐的可读值。
String platformName(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.macOS => 'macos',
  TargetPlatform.windows => 'windows',
  TargetPlatform.linux => 'linux',
  TargetPlatform.fuchsia => 'fuchsia',
};

/// 设备显示名。
///
/// 移动端不用主机名：`Platform.localHostname` 在手机上通常返回 `localhost`，
/// 显示成「iPhone · localhost」只会让人困惑。桌面保留主机名，因为一台人可能有多台。
String deviceLabel({
  required TargetPlatform platform,
  required String hostname,
}) {
  final host = hostname.trim();
  return switch (platform) {
    TargetPlatform.android => 'Android 手机',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => host.isEmpty ? 'Mac' : 'Mac · $host',
    TargetPlatform.windows => host.isEmpty ? 'Windows' : 'Windows · $host',
    TargetPlatform.linux => host.isEmpty ? 'Linux' : 'Linux · $host',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}

/// 服务地址校验。返回 null 表示合法。
///
/// 手机上强制 `https://`：局域网访问必然走自签 TLS，
/// 允许填 http 只会造出"连不上但看不出原因"的体验。
String? serverUrlValidator(String? value, {required TargetPlatform platform}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) {
    return isMobilePlatform(platform)
        ? '请填写电脑的局域网地址，如 https://192.168.1.10:8787'
        : '请填写服务地址';
  }

  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null || uri.host.isEmpty) {
    return '地址格式不对，形如 https://192.168.1.10:8787';
  }

  if (isMobilePlatform(platform) && uri.scheme != 'https') {
    return '手机上必须用 https://（服务端绑定局域网地址时会自动启用自签 TLS）';
  }

  return null;
}
