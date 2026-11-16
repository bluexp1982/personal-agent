import 'package:flutter/foundation.dart';

/// 开发模式自动配对注入的参数。
///
/// `./scripts/dev.sh client` 会用 `--dart-define-from-file=.dev/client-pairing.json`
/// 把「服务地址 + 一次性配对码」带进来；脚本在配对结束（或被回收）后会删掉那个文件。
///
/// 只在 debug 构建生效：`String.fromEnvironment` 是编译期常量，release 包里压根没有
/// 这两个值；再加一层 [kDebugMode]，即使有人给 release 塞了 define 也不会触发。
///
/// 为什么值得做：开发时手填地址、抄 12 位码、再对着终端核对证书指纹，一天要做很多次；
/// 而这些信息本来就是本机脚本刚刚生成的，让脚本直接递给客户端没有任何信任问题。
class DevAutoConnect {
  const DevAutoConnect._();

  static const String _url = String.fromEnvironment('PA_DEV_SERVER_URL');
  static const String _code = String.fromEnvironment('PA_DEV_PAIR_CODE');

  /// 是否具备自动配对条件：debug 构建 + 两个参数都在。
  static bool get enabled => kDebugMode && _url.isNotEmpty && _code.isNotEmpty;

  /// 脚本注入的服务地址（形如 `https://127.0.0.1:8788`）。
  static String get serverUrl => _url;

  /// 脚本注入的一次性配对码（12 位，5 分钟有效）。
  static String get pairCode => _code;
}

/// 登录失败后是否该清掉本地身份、改用新密钥重新配对。
///
/// 只有"服务端明确不认这台设备"才清：
/// - `unauthenticated` / `forbidden` / `not_found`：设备被吊销、公钥不认识；
/// - `tls_fingerprint_mismatch`：证书换了，旧基准已经不可信。
///
/// 网络不通（`network_error`）**绝不能**清：服务没起来是最常见的情况，
/// 清掉等于把一份好好的配对毁了，下次还得重新配。
///
/// 其余错误（限流、服务端 5xx 等）也不清——它们跟身份无关。
bool shouldForgetAfterLoginFailure(String? code) {
  return switch (code) {
    'unauthenticated' ||
    'forbidden' ||
    'not_found' ||
    'tls_fingerprint_mismatch' => true,
    _ => false,
  };
}
