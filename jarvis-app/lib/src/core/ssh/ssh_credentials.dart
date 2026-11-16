// SSH 凭据与主机指纹的本地存储。
//
// 全部走 [SecretStore]（钥匙串优先、私有目录回退）：SSH 密码与配对令牌同级敏感，
// 放进 SharedPreferences 等于把"能不能登录服务器"写进了明文文件。

import '../secret_store.dart';

/// 「打开终端时自动登录」偏好的存储键。
///
/// 全局一个键而不是按 host 分组：客户端同一时间只与一台服务端配对，
/// 分组的唯一效果是重新配对后出现"同一台机器两套开关"。
const String kSshAutoLoginKey = 'ssh_auto_login';

/// 一个服务端主机对应一份 SSH 凭据。
///
/// 键按 `serverHost` 分组而不是按服务地址整串：同一台机器换端口（`api_bind` 改过）
/// 时，用户不该被要求重新输一遍用户名。
class SshCredentials {
  const SshCredentials(this._store);

  final SecretStore _store;

  static const String _usernamePrefix = 'ssh_username';
  static const String _passwordPrefix = 'ssh_password';
  static const String _hostKeyPrefix = 'ssh_host_key';

  String _key(String prefix, String host) => '$prefix:$host';

  Future<String?> readUsername(String host) =>
      _store.read(_key(_usernamePrefix, host));

  Future<String?> readPassword(String host) =>
      _store.read(_key(_passwordPrefix, host));

  /// 记录用户名；`password` 为 null 表示"不记住密码"，此时顺手清掉旧密码。
  ///
  /// 不清的话，"上次勾了记住、这次没勾"会留下一个用户以为已经删掉的密码。
  Future<void> save({
    required String host,
    required String username,
    String? password,
  }) async {
    await _store.write(_key(_usernamePrefix, host), username);
    if (password == null || password.isEmpty) {
      await _store.delete(_key(_passwordPrefix, host));
      return;
    }
    await _store.write(_key(_passwordPrefix, host), password);
  }

  /// 只改用户名，不动已保存的密码。
  ///
  /// 设置页"留空表示不修改密码"就靠这个：直接走 [save] 会把密码当成
  /// "这次不记住"删掉，用户只是想改个用户名却把密码弄丢了。
  Future<void> saveUsername({required String host, required String username}) =>
      _store.write(_key(_usernamePrefix, host), username);

  Future<String?> readHostKey(String host) =>
      _store.read(_key(_hostKeyPrefix, host));

  Future<void> saveHostKey(String host, String fingerprint) =>
      _store.write(_key(_hostKeyPrefix, host), fingerprint);

  /// 只清用户名与密码，保留主机指纹。
  ///
  /// 与 [forget] 的区别是"改密码"和"不再信任这台机器"：日常清凭据不该
  /// 顺带把中间人防护抹掉，否则下次连接等于重新 TOFU 一遍。
  Future<void> clear({required String host}) async {
    for (final prefix in <String>[_usernamePrefix, _passwordPrefix]) {
      await _store.delete(_key(prefix, host));
    }
  }

  /// 是否在打开终端时自动登录。未写入时默认 true。
  ///
  /// 只认明确的 `false`：脏值（空串、旧版本写坏的内容）一律按默认值处理，
  /// 与 [themeModeFromName] 的取舍一致——猜一个值只会让用户觉得"开关自己变了"。
  Future<bool> readAutoLogin() async {
    final raw = await _store.read(kSshAutoLoginKey);
    return raw != 'false';
  }

  Future<void> saveAutoLogin(bool enabled) =>
      _store.write(kSshAutoLoginKey, enabled ? 'true' : 'false');

  /// 解除配对时调用：那台机器已经不被信任，ssh 凭据与主机指纹必须一起清掉。
  Future<void> forget(String host) async {
    for (final prefix in <String>[
      _usernamePrefix,
      _passwordPrefix,
      _hostKeyPrefix,
    ]) {
      await _store.delete(_key(prefix, host));
    }
  }
}
