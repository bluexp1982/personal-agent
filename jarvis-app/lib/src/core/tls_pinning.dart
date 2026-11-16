import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'base32_codec.dart';

/// 服务端自签证书的信任处理。
///
/// 为什么不走系统信任链：服务是跑在自己机器上的自签证书，没有公信 CA 可依。
/// 唯一可靠的判据是"这张证书的指纹是不是首次配对时见到的那一张"——
/// 与 SSH 首次连接记录 host key 是同一套语义（TOFU）。
///
/// 指纹格式必须与服务端 `identity::format_digest` 完全一致：
/// `base32(sha256(证书DER))` 取前 16 字符，每 4 字符一组。
/// 两端口径不一致会表现为"每次连接都提示指纹不匹配"，比不做校验更难排查。

/// 由证书 DER 计算指纹，形如 `A7K2-9XQP-3MDE-6RTU`。
String certificateFingerprint(List<int> der) {
  final digest = sha256.convert(der).bytes;
  final encoded = base32Encode(digest);
  final head = encoded.length <= 16 ? encoded : encoded.substring(0, 16);

  final groups = <String>[];
  for (var start = 0; start < head.length; start += 4) {
    final end = start + 4 > head.length ? head.length : start + 4;
    groups.add(head.substring(start, end));
  }
  return groups.join('-');
}

/// 是否接受观察到的证书。
///
/// `pinned == null` 表示首次连接（还没有可比较的基准）：接受，但调用方必须
/// 把指纹展示出来让人工核对——静默接受 TOFU 与不做校验没有区别。
bool shouldAcceptCertificate({required String observed, String? pinned}) {
  if (pinned == null || pinned.isEmpty) {
    return true;
  }
  return observed == pinned;
}

/// 地址是否走 TLS。只有 `https://` 才需要指纹校验。
bool isTlsUrl(String baseUrl) =>
    baseUrl.trim().toLowerCase().startsWith('https://');

/// 错误是否来自 TLS 层（用户层应看到"证书不被接受"而不是"网络不通"）。
bool isTlsFailure(Object error) => error is TlsException;

/// 配对提交前的信任门。
///
/// 三种情况：
/// - 明文 http：不需要证书核对（本机开发）；
/// - https 但还没探测到指纹：允许提交，这一步就是去取指纹；
/// - https 且已看到指纹：必须由人勾选"已核对"才允许把配对码发出去。
bool canSubmitPairing({
  required String serverUrl,
  String? observedFingerprint,
  required bool confirmed,
}) {
  if (!isTlsUrl(serverUrl)) {
    return true;
  }
  if (observedFingerprint == null) {
    return true;
  }
  return confirmed;
}

/// 建立带指纹校验的裸 `HttpClient`。
///
/// 单独暴露裸对象是为了 WebSocket：`WebSocket.connect` 的 `customClient` 只接受
/// `HttpClient`，不接受 `http.Client`。证书指纹的判定必须只有这一份实现，
/// 否则 HTTP 与 SSH 隧道会各写一套，迟早出现"一处校验、一处放行"。
HttpClient createPinnedHttpClient({
  required String baseUrl,
  String? pinned,
  void Function(String observed)? onObserved,
}) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  if (!isTlsUrl(baseUrl)) {
    return client;
  }

  // badCertificateCallback 只在证书本身不被信任时触发；自签证书必然走到这里，
  // 因此这条路径就是"每次连接都核对指纹"的实际落点。
  client.badCertificateCallback = (certificate, host, port) {
    final observed = certificateFingerprint(certificate.der);
    onObserved?.call(observed);
    return shouldAcceptCertificate(observed: observed, pinned: pinned);
  };

  return client;
}

/// 建立带指纹校验的 HTTP 客户端。
///
/// `onObserved` 在每次握手时上报真实指纹，供配对页展示。
http.Client createPinnedClient({
  required String baseUrl,
  String? pinned,
  void Function(String observed)? onObserved,
}) {
  return IOClient(
    createPinnedHttpClient(
      baseUrl: baseUrl,
      pinned: pinned,
      onObserved: onObserved,
    ),
  );
}

/// 只握手、不发业务请求，取回服务端证书指纹。
///
/// 配对页用它"先看指纹再决定要不要把配对码发出去"：先发配对码再核对，
/// 等于把码交给了一个还没确认身份的对端。
Future<String?> probeTlsFingerprint(String baseUrl) async {
  if (!isTlsUrl(baseUrl)) {
    return null;
  }

  final uri = Uri.parse(baseUrl.trim());
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  String? observed;
  client.badCertificateCallback = (certificate, host, port) {
    observed = certificateFingerprint(certificate.der);
    return true;
  };

  try {
    // 任意一条存在的 /api 路径都足以完成握手；未授权响应正好说明服务在。
    final request = await client.getUrl(uri.resolve('/api/auth/me'));
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }

  // 证书被系统信任（例如将来换成公网证书）时回调不会触发，返回 null 表示无需固定。
  return observed;
}
