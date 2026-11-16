import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// 本地密钥与令牌存储。
///
/// 优先用系统钥匙串（macOS Keychain / Windows DPAPI / Linux Secret Service）；
/// 钥匙串不可用时（未签名构建、headless Linux、测试环境）退化为应用私有目录下的
/// 0600 文件——保证开发期可用，同时不把令牌写进日志或项目目录。
class SecretStore {
  SecretStore({FlutterSecureStorage? storage, this.fallbackDirectory})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 钥匙串不可用时的回退目录；为空则按平台默认位置。
  final Directory? fallbackDirectory;
  final Map<String, String> _cache = <String, String>{};

  /// 本进程内是否已判定钥匙串不可用。
  ///
  /// macOS 的 ad-hoc 签名（没有 DEVELOPMENT_TEAM）拿不到
  /// `keychain-access-groups`，data protection keychain 会稳定返回 -34018。
  /// 判定一次后就不再重试，避免每次读写都往 stderr 打同一条日志。
  bool _keychainUnavailable = false;
  bool _fallbackLogged = false;

  Future<String?> read(String key) async {
    if (_cache.containsKey(key)) {
      return _cache[key];
    }

    if (!_keychainUnavailable) {
      try {
        final value = await _storage.read(key: key);
        if (value != null) {
          _cache[key] = value;
          return value;
        }
      } on Exception catch (error) {
        // 钥匙串不可用不是错误：走文件回退即可。
        _markKeychainUnavailable(error);
      }
    }

    final file = await _fallbackFile();
    final values = await _readFallback(file);
    final value = values[key];
    if (value != null) {
      _cache[key] = value;
    }
    return value;
  }

  Future<void> write(String key, String value) async {
    _cache[key] = value;
    if (!_keychainUnavailable) {
      try {
        await _storage.write(key: key, value: value);
        return;
      } on Exception catch (error) {
        _markKeychainUnavailable(error);
      }
    }

    final file = await _fallbackFile();
    final values = await _readFallback(file);
    values[key] = value;
    await _writeFallback(file, values);
  }

  Future<void> delete(String key) async {
    _cache.remove(key);
    if (!_keychainUnavailable) {
      try {
        await _storage.delete(key: key);
      } on Exception catch (error) {
        _markKeychainUnavailable(error);
      }
    }

    final file = await _fallbackFile();
    final values = await _readFallback(file);
    if (values.remove(key) != null) {
      await _writeFallback(file, values);
    }
  }

  Future<void> clear() async {
    _cache.clear();
    if (!_keychainUnavailable) {
      try {
        await _storage.deleteAll();
      } on Exception catch (error) {
        _markKeychainUnavailable(error);
      }
    }

    final file = await _fallbackFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 记下"这个进程不再用钥匙串"，并且只提示一次。
  ///
  /// release 里文件回退是这台机器的正常路径，不该占日志；debug 留一条便于定位
  /// 是签名问题还是插件问题，后续读写不再重复刷屏。
  void _markKeychainUnavailable(Object error) {
    _keychainUnavailable = true;
    if (_fallbackLogged) {
      return;
    }
    _fallbackLogged = true;
    if (!kDebugMode) {
      return;
    }
    stderr.writeln(
      '[secret-store] 钥匙串不可用（未签名构建或缺少 keychain-access-groups），'
      '本次运行改用本地 0600 文件，后续不再重复提示。原因：$error',
    );
  }

  Future<File> _fallbackFile() async {
    final dir = fallbackDirectory ?? await _defaultDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/secrets.json');
  }

  /// 回退目录。
  ///
  /// 移动端**不能**用环境变量拼路径：Android/iOS 没有 `HOME`，拼出来会是
  /// `null/Library/...` 这种无效路径，回退本身就会失败。系统给的
  /// `getApplicationSupportDirectory()` 已经是应用私有的，不需要再加子目录。
  /// 桌面保持原有路径，避免老用户配对信息"消失"。
  static Future<Directory> _defaultDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return getApplicationSupportDirectory();
    }

    final env = Platform.environment;
    if (Platform.isMacOS) {
      return Directory(
        '${env['HOME']}/Library/Application Support/personal-agent',
      );
    }
    if (Platform.isWindows) {
      final appData = env['APPDATA'] ?? env['USERPROFILE'];
      return Directory('$appData\\personal-agent');
    }
    final configHome = env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config';
    return Directory('$configHome/personal-agent');
  }

  Future<Map<String, String>> _readFallback(File file) async {
    if (!await file.exists()) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded.map((key, value) => MapEntry(key, '$value'));
      }
    } on FormatException {
      // 文件损坏时按空处理：宁可要求重新配对，也不要因解析失败卡住启动。
    }
    return <String, String>{};
  }

  Future<void> _writeFallback(File file, Map<String, String> values) async {
    await file.writeAsString(jsonEncode(values), flush: true);
    // 只在真的有 chmod 的桌面 Unix 上收紧权限：Android 没有这个命令，
    // iOS 沙箱内文件本来就只有本应用可读，执行它只是徒增一次失败。
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        await Process.run('chmod', <String>['600', file.path]);
      } on ProcessException {
        // 忽略
      }
    }
  }
}
