import 'dart:convert';

/// 服务端统一错误体：`{ code, message, retryable, hint }`。
///
/// 客户端只依赖 `code`（稳定）与 `hint`（面向用户），`message` 用于日志。
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    required this.retryable,
    required this.hint,
    this.statusCode,
  });

  /// 解析错误响应体。结构不符时退化为 `internal_error`，不让解析失败盖住真实错误。
  factory ApiException.fromResponse(int statusCode, String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic>) {
        return ApiException(
          code: value['code'] as String? ?? 'internal_error',
          message: value['message'] as String? ?? body,
          retryable: value['retryable'] as bool? ?? false,
          hint: value['hint'] as String? ?? '',
          statusCode: statusCode,
        );
      }
    } on FormatException {
      // 落到下面的兜底
    }

    return ApiException(
      code: 'internal_error',
      message: body.isEmpty ? 'HTTP $statusCode' : body,
      retryable: statusCode >= 500,
      hint: '服务返回了无法解析的错误（HTTP $statusCode）',
      statusCode: statusCode,
    );
  }

  /// [baseUrl] 是这次尝试连的地址。
  ///
  /// 必须带上它：一句"默认 http://127.0.0.1:8787"在手机上完全是误导——
  /// 手机连的是电脑的局域网地址，而且那个地址必须走 https。
  factory ApiException.network(Object error, {String? baseUrl}) {
    final url = baseUrl?.trim() ?? '';
    final target = url.isEmpty ? '服务' : url;
    // 明文 + 非回环 = 几乎必然用错了协议（服务绑定局域网时会自动启用自签 TLS）。
    final schemeHint = url.startsWith('http://') && !_isLoopback(url)
        ? '；绑定局域网时客户端必须用 https://（服务会自动启用自签 TLS）'
        : '';

    return ApiException(
      code: 'network_error',
      message: '$error',
      retryable: true,
      hint:
          '连不上 $target：确认服务已启动、端口一致，'
          '且服务监听的是局域网地址（api_bind 用 0.0.0.0）$schemeHint'
          '${_unreachableHint(error)}',
    );
  }

  /// `No route to host`/`Network is unreachable` 是"包根本没出去"，与端口没监听
  /// （connection refused）是两回事：iOS 上最常见的原因是 App 没拿到本地网络权限。
  /// 这一条必须单独说清——否则用户会去反复检查服务端，而开关在手机设置里。
  static String _unreachableHint(Object error) {
    final text = '$error';
    final unreachable =
        text.contains('errno = 65') ||
        text.contains('errno = 51') ||
        text.contains('EHOSTUNREACH') ||
        text.contains('ENETUNREACH');
    if (!unreachable) {
      return '';
    }
    return '；这个错误表示包没发出本机：手机需与电脑同一 Wi-Fi（同一网段）、'
        '关掉 VPN/代理，并在 iOS「设置 → 隐私与安全性 → 本地网络」里允许本 App'
        '（列表里没有就要重装 App 后重新授权）';
  }

  static bool _isLoopback(String url) =>
      url.contains('127.0.0.1') ||
      url.contains('localhost') ||
      url.contains('[::1]');

  /// TLS 握手被拒。绝大多数情况是证书指纹与配对时记录的不一致。
  ///
  /// 这条不是"重试就能好"的错误，所以 `retryable = false`，并给出唯一的出路：
  /// 确认服务端没有换证书后再解除配对重新配对。
  factory ApiException.tlsPinning() {
    return const ApiException(
      code: 'tls_fingerprint_mismatch',
      message: 'server certificate rejected',
      retryable: false,
      hint:
          '服务端证书指纹与配对时不一致，可能被中间人；确认服务端重装或换过证书后，'
          '在设置里解除配对并重新配对',
    );
  }

  final String code;
  final String message;
  final bool retryable;
  final String hint;
  final int? statusCode;

  /// 给用户看的一句话。`hint` 为空时退回 `message`。
  String get userMessage => hint.isNotEmpty ? hint : message;

  @override
  String toString() => 'ApiException($code, HTTP $statusCode): $message';
}
