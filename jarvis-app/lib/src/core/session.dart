import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'api_error.dart';
import 'base32_codec.dart';
import 'client_platform.dart';
import 'dev_auto_connect.dart';
import 'device_identity.dart';
import 'pairing_code.dart';
import 'secret_store.dart';
import 'tls_pinning.dart';

/// 配对码归一化规则定义在 pairing_code.dart，界面与脚本共用同一份。
export 'pairing_code.dart';

/// 存储键。改名会导致老用户掉登录态，需谨慎。
const String kServerUrlKey = 'server_url';
const String kDeviceIdKey = 'device_id';
const String kDeviceNameKey = 'device_name';
const String kTokenKey = 'token';
const String kTokenExpiresKey = 'token_expires_at';
const String kServerFingerprintKey = 'server_fingerprint';

/// TLS 证书指纹。与 `server_fingerprint`（身份公钥指纹）是两件事：
/// 前者证明"连的是这台机器"，后者证明"配的是这台机器"。旧安装没有这个键，
/// 首次以 https 连接时会按 TOFU 接受并补写，不需要重新配对。
const String kServerTlsFingerprintKey = 'server_tls_fingerprint';
const String kIdentitySeedKey = 'identity_seed';

/// 桌面默认地址；手机端由 [defaultServerUrl] 返回空串（必须填电脑的局域网地址）。
///
/// 保留这个常量是为了兼容既有调用与测试，真正的取值统一走 `client_platform`。
const String kDefaultServerUrl = kDesktopServerUrl;

final Provider<SecretStore> secretStoreProvider = Provider<SecretStore>(
  (ref) => SecretStore(),
);

/// 已登录会话。
class SessionState {
  const SessionState({
    required this.serverUrl,
    this.deviceId,
    this.deviceName = '',
    this.token,
    this.tokenExpiresAt,
    this.serverFingerprint,
    this.serverTlsFingerprint,
    this.error,
  });

  final String serverUrl;
  final String? deviceId;
  final String deviceName;
  final String? token;
  final int? tokenExpiresAt;
  final String? serverFingerprint;

  /// 服务端 TLS 证书指纹；为空表示服务走明文 http（本机开发）。
  final String? serverTlsFingerprint;

  /// 已配对但自动登录失败时的原因，供界面提示。
  final String? error;

  bool get isPaired => deviceId != null;

  bool get hasToken => token != null;

  bool get isReady => isPaired && hasToken;

  SessionState copyWith({
    String? serverUrl,
    String? deviceId,
    String? deviceName,
    String? token,
    int? tokenExpiresAt,
    String? serverFingerprint,
    String? serverTlsFingerprint,
    String? error,
    bool clearError = false,
  }) {
    return SessionState(
      serverUrl: serverUrl ?? this.serverUrl,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      token: token ?? this.token,
      tokenExpiresAt: tokenExpiresAt ?? this.tokenExpiresAt,
      serverFingerprint: serverFingerprint ?? this.serverFingerprint,
      serverTlsFingerprint: serverTlsFingerprint ?? this.serverTlsFingerprint,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final AsyncNotifierProvider<SessionController, SessionState> sessionProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
      SessionController.new,
    );

/// 会话：加载本地状态、静默登录、配对完成后落盘。
class SessionController extends AsyncNotifier<SessionState> {
  @override
  Future<SessionState> build() async {
    final store = ref.watch(secretStoreProvider);

    final serverUrl =
        await store.read(kServerUrlKey) ??
        defaultServerUrl(platform: defaultTargetPlatform);
    final deviceId = await store.read(kDeviceIdKey);
    final deviceName = await store.read(kDeviceNameKey) ?? '';
    final fingerprint = await store.read(kServerFingerprintKey);
    final tlsFingerprint = await store.read(kServerTlsFingerprintKey);

    if (deviceId == null) {
      return SessionState(
        serverUrl: serverUrl,
        deviceName: deviceName,
        serverFingerprint: fingerprint,
        serverTlsFingerprint: tlsFingerprint,
      );
    }

    final token = await store.read(kTokenKey);
    final expiresAt = int.tryParse(await store.read(kTokenExpiresKey) ?? '');
    var stillValid =
        token != null &&
        (expiresAt == null ||
            DateTime.now().millisecondsSinceEpoch < expiresAt - 60000);

    // 开发模式额外做一次令牌自检：设备被吊销后本地令牌仍然带着未来的过期时间，
    // 只有真打一次接口才知道它已经作废。不查的话自动配对永远不会触发，
    // 用户看到的是"打开了但每个面板都报 401"。
    if (stillValid && DevAutoConnect.enabled) {
      stillValid = await _devTokenAlive(
        serverUrl: serverUrl,
        token: token,
        pinnedTlsFingerprint: tlsFingerprint,
      );
      if (!stillValid) {
        // 令牌用不上（设备被吊销 / 存的地址已经连不上）：直接交给自动配对，
        // 不要再拿旧地址试登录——那会先白等一轮 15 秒的连接超时。
        return SessionState(
          serverUrl: serverUrl,
          deviceId: deviceId,
          deviceName: deviceName,
          serverFingerprint: fingerprint,
          serverTlsFingerprint: tlsFingerprint,
          error: '当前配置连不上服务（开发模式将用注入的地址重试）',
        );
      }
    }

    if (stillValid) {
      return SessionState(
        serverUrl: serverUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        token: token,
        tokenExpiresAt: expiresAt,
        serverFingerprint: fingerprint,
        serverTlsFingerprint: tlsFingerprint,
      );
    }

    // 令牌过期：用长期密钥静默换一个新的，失败则让界面提示重新登录。
    try {
      final fresh = await _login(
        serverUrl: serverUrl,
        deviceId: deviceId,
        store: store,
        pinnedTlsFingerprint: tlsFingerprint,
      );
      return SessionState(
        serverUrl: serverUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        token: fresh.token,
        tokenExpiresAt: fresh.expiresAt,
        serverFingerprint: fingerprint,
        // 老安装没有记录过证书指纹：这次登录握手就是首次见到它，补记下来。
        serverTlsFingerprint: fresh.tlsFingerprint ?? tlsFingerprint,
      );
    } on ApiException catch (error) {
      return SessionState(
        serverUrl: serverUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        serverFingerprint: fingerprint,
        serverTlsFingerprint: tlsFingerprint,
        error: error.userMessage,
      );
    }
  }

  /// 配对完成：落盘设备信息并立即登录。
  Future<void> completePairing({
    required String serverUrl,
    required String deviceId,
    required String deviceName,
    String? fingerprint,
    String? tlsFingerprint,
  }) async {
    final store = ref.read(secretStoreProvider);
    await store.write(kServerUrlKey, serverUrl);
    await store.write(kDeviceIdKey, deviceId);
    await store.write(kDeviceNameKey, deviceName);
    if (fingerprint != null) {
      await store.write(kServerFingerprintKey, fingerprint);
    }
    if (tlsFingerprint != null) {
      await store.write(kServerTlsFingerprintKey, tlsFingerprint);
    }

    final session = await _login(
      serverUrl: serverUrl,
      deviceId: deviceId,
      store: store,
      pinnedTlsFingerprint: tlsFingerprint,
    );
    state = AsyncData(
      SessionState(
        serverUrl: serverUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        token: session.token,
        tokenExpiresAt: session.expiresAt,
        serverFingerprint: fingerprint,
        serverTlsFingerprint: session.tlsFingerprint ?? tlsFingerprint,
      ),
    );
  }

  /// 当前配置到底还能不能连上（只为开发模式的自动配对服务）。
  ///
  /// 注意这**不是**单纯的"令牌有没有过期"：存的地址换了 IP、服务重装、设备被吊销，
  /// 本地令牌看起来都还"有效"。所以这里只认"真打一次接口成功"，其余一律算连不上，
  /// 交给自动配对去用注入的地址重试——但清不清本地身份由
  /// [shouldForgetAfterLoginFailure] 决定，网络不通不会清。
  Future<bool> _devTokenAlive({
    required String serverUrl,
    required String token,
    String? pinnedTlsFingerprint,
  }) async {
    final client = ApiClient(
      baseUrl: serverUrl,
      token: token,
      httpClient: createPinnedClient(
        baseUrl: serverUrl,
        pinned: pinnedTlsFingerprint,
      ),
    );
    try {
      await client.getJson('/api/auth/me');
      return true;
    } on ApiException {
      return false;
    } finally {
      client.close();
    }
  }

  /// 用长期密钥在任意地址换一次令牌。
  ///
  /// 公开出来是为了让"服务换了地址"的场景能先拿旧身份试一次：换 IP/端口不等于
  /// 换机器，试通了就只更新地址，不必重新配对、也不会多一条设备记录。
  Future<({String token, int? expiresAt, String? tlsFingerprint})> loginAt({
    required String serverUrl,
    required String deviceId,
    String? pinnedTlsFingerprint,
  }) async {
    final result = await _login(
      serverUrl: serverUrl,
      deviceId: deviceId,
      store: ref.read(secretStoreProvider),
      pinnedTlsFingerprint: pinnedTlsFingerprint,
    );
    return (
      token: result.token,
      expiresAt: result.expiresAt,
      tlsFingerprint: result.tlsFingerprint,
    );
  }

  /// 开发模式自动配对：只有 `dev.sh client` 注入了参数时才会被调用。
  ///
  /// 顺序刻意是"先救旧身份，失败再清身份重配"：
  /// 1. 已配对时先用长期密钥对新地址登录——服务只是换了 IP/端口时这一步就够了；
  /// 2. 只有服务端明确不认这台设备才 [forgetDevice]，用新密钥重新配对
  ///    （服务端 `devices.pubkey` 是全局唯一，留着旧公钥重新配对必然 409）；
  /// 3. 网络不通时不清身份，直接把原因交回界面。
  ///
  /// 成功返回 null（此时 `state` 已带令牌）；失败返回给人看的原因。
  Future<String?> devAutoPair({
    required String serverUrl,
    required String code,
  }) async {
    final current = state.value;
    final store = ref.read(secretStoreProvider);

    if (current?.deviceId != null) {
      try {
        final fresh = await loginAt(
          serverUrl: serverUrl,
          deviceId: current!.deviceId!,
          pinnedTlsFingerprint: current.serverTlsFingerprint,
        );
        final tls = fresh.tlsFingerprint ?? current.serverTlsFingerprint;
        await store.write(kServerUrlKey, serverUrl);
        if (tls != null) {
          await store.write(kServerTlsFingerprintKey, tls);
        }
        state = AsyncData(
          current.copyWith(
            serverUrl: serverUrl,
            token: fresh.token,
            tokenExpiresAt: fresh.expiresAt,
            serverTlsFingerprint: tls,
            clearError: true,
          ),
        );
        return null;
      } on ApiException catch (error) {
        if (!shouldForgetAfterLoginFailure(error.code)) {
          return error.userMessage;
        }
        await forgetDevice();
      }
    }

    // 走到这里说明本地没有可用身份（或已被服务端拒绝）：用注入的码走一次完整配对。
    await ref
        .read(pairingProvider.notifier)
        .start(
          serverUrl: serverUrl,
          code: code,
          deviceName: deviceLabel(
            platform: defaultTargetPlatform,
            hostname: Platform.localHostname,
          ),
          platform: platformName(defaultTargetPlatform),
          // 地址与码来自本机启动器，不再要求人工核对指纹；TOFU 仍会记录并 pin。
          pinnedFingerprint: null,
        );

    final pairing = ref.read(pairingProvider);
    if (pairing.phase == PairingPhase.approved) {
      return null;
    }
    return pairing.message.isEmpty ? '自动配对没有完成' : pairing.message;
  }

  /// 手动重试登录（配对完好但令牌拿不到时使用）。
  Future<void> retryLogin() async {
    final current = state.value;
    if (current == null || current.deviceId == null) {
      return;
    }

    state = const AsyncLoading();
    final store = ref.read(secretStoreProvider);
    try {
      final session = await _login(
        serverUrl: current.serverUrl,
        deviceId: current.deviceId!,
        store: store,
        pinnedTlsFingerprint: current.serverTlsFingerprint,
      );
      state = AsyncData(
        current.copyWith(
          token: session.token,
          tokenExpiresAt: session.expiresAt,
          serverTlsFingerprint: session.tlsFingerprint,
          clearError: true,
        ),
      );
    } on ApiException catch (error) {
      state = AsyncData(current.copyWith(error: error.userMessage));
    }
  }

  /// 解除配对：清掉设备身份与令牌，需要重新扫码/输码。
  Future<void> forgetDevice() async {
    final store = ref.read(secretStoreProvider);
    for (final key in <String>[
      kDeviceIdKey,
      kDeviceNameKey,
      kTokenKey,
      kTokenExpiresKey,
      kServerFingerprintKey,
      // 解除配对意味着"我不再信任那台机器"，证书基准必须一起清掉，
      // 否则重新配对时会被旧指纹挡住，用户只能去删数据目录。
      kServerTlsFingerprintKey,
      kIdentitySeedKey,
    ]) {
      await store.delete(key);
    }
    final serverUrl =
        state.value?.serverUrl ??
        defaultServerUrl(platform: defaultTargetPlatform);
    state = AsyncData(SessionState(serverUrl: serverUrl));
  }

  Future<_LoginResult> _login({
    required String serverUrl,
    required String deviceId,
    required SecretStore store,
    String? pinnedTlsFingerprint,
  }) async {
    final identity = await loadOrCreateIdentity(store);
    String? observed;
    final client = ApiClient(
      baseUrl: serverUrl,
      httpClient: createPinnedClient(
        baseUrl: serverUrl,
        pinned: pinnedTlsFingerprint,
        onObserved: (fingerprint) => observed = fingerprint,
      ),
    );
    try {
      final challenge = await client.postJson(
        '/api/auth/challenge',
        <String, String>{'device_id': deviceId},
      );
      final challengeValue = challenge['challenge'] as String?;
      if (challengeValue == null) {
        throw const ApiException(
          code: 'internal_error',
          message: '缺少 challenge',
          retryable: false,
          hint: '服务返回了预期之外的数据',
        );
      }

      // 签名对象是 base32 解码后的 32 字节，不是字符串本身。
      final signature = await identity.sign(base32Decode(challengeValue));
      final verified = await client.postJson(
        '/api/auth/verify',
        <String, String>{
          'device_id': deviceId,
          'challenge': challengeValue,
          'signature': base32Encode(signature),
        },
      );

      final token = verified['token'] as String?;
      final expiresAt = verified['expires_at'] as int?;
      if (token == null) {
        throw const ApiException(
          code: 'internal_error',
          message: '缺少 token',
          retryable: false,
          hint: '服务返回了预期之外的数据',
        );
      }

      await store.write(kTokenKey, token);
      if (expiresAt != null) {
        await store.write(kTokenExpiresKey, '$expiresAt');
      }
      return _LoginResult(
        token: token,
        expiresAt: expiresAt,
        tlsFingerprint: observed,
      );
    } finally {
      client.close();
    }
  }
}

class _LoginResult {
  const _LoginResult({
    required this.token,
    this.expiresAt,
    this.tlsFingerprint,
  });

  final String token;
  final int? expiresAt;

  /// 本次连接实际见到的证书指纹（明文 http 时为 null）。
  final String? tlsFingerprint;
}

/// 读取或首次生成客户端身份。
Future<DeviceIdentity> loadOrCreateIdentity(SecretStore store) async {
  final seed = await store.read(kIdentitySeedKey);
  if (seed != null && seed.isNotEmpty) {
    return DeviceIdentity.fromSeed(base32Decode(seed));
  }

  final identity = await DeviceIdentity.generate();
  await store.write(
    kIdentitySeedKey,
    base32Encode(await identity.exportSeed()),
  );
  return identity;
}

/// 配对流程状态。
enum PairingPhase { idle, submitting, waiting, approved, failed }

class PairingState {
  const PairingState({
    required this.phase,
    this.message = '',
    this.fingerprint,
    this.tlsFingerprint,
    this.code,
  });

  const PairingState.idle() : this(phase: PairingPhase.idle);

  final PairingPhase phase;
  final String message;

  /// 失败时的稳定错误码，界面据此决定是否给"解除配对"这条出路。
  final String? code;

  /// 服务端**身份**公钥指纹（配对批准后由服务端给出）。
  final String? fingerprint;

  /// 服务端**TLS 证书**指纹（握手时观察到的）。明文 http 时为 null。
  final String? tlsFingerprint;

  bool get isBusy =>
      phase == PairingPhase.submitting || phase == PairingPhase.waiting;
}

final NotifierProvider<PairingController, PairingState> pairingProvider =
    NotifierProvider<PairingController, PairingState>(PairingController.new);

/// 配对：提交配对码 → 轮询状态 → 本机确认后自动登录。
class PairingController extends Notifier<PairingState> {
  @override
  PairingState build() => const PairingState.idle();

  /// [pinnedFingerprint] 是配对页里用户已经核对过的证书指纹。
  /// 已配对过的机器以存储里的记录为准——用户不该在每次重新配对时被允许"跳过核对"。
  Future<void> start({
    required String serverUrl,
    required String code,
    required String deviceName,
    required String platform,
    String? pinnedFingerprint,
  }) async {
    if (state.isBusy) {
      return;
    }

    state = const PairingState(
      phase: PairingPhase.submitting,
      message: '正在提交配对码…',
    );

    final store = ref.read(secretStoreProvider);
    final stored = await store.read(kServerTlsFingerprintKey);
    String? observed;
    final client = ApiClient(
      baseUrl: serverUrl,
      httpClient: createPinnedClient(
        baseUrl: serverUrl,
        pinned: stored ?? pinnedFingerprint,
        onObserved: (fingerprint) => observed = fingerprint,
      ),
    );

    try {
      final identity = await loadOrCreateIdentity(store);
      final pending = await client.postJson(
        '/api/pair/request',
        <String, String>{
          // 这里统一归一化：无论调用方（配对页、冒烟脚本）传的是
          // `77JJ-VQ3F-2YZK` 还是 `77jjvq3f2yzk`，发出去的都是同一个码。
          'code': normalizePairingCode(code),
          'device_name': deviceName,
          'platform': platform,
          'client_pubkey': await identity.publicKeyBase32(),
        },
      );

      final requestId = pending['request_id'] as String?;
      if (requestId == null) {
        throw const ApiException(
          code: 'internal_error',
          message: '缺少 request_id',
          retryable: false,
          hint: '服务返回了预期之外的数据',
        );
      }

      state = PairingState(
        phase: PairingPhase.waiting,
        message: '等待本机确认。请在运行服务的机器上执行：jarvis-service pair --approve <id>',
        tlsFingerprint: observed,
      );

      // 5 分钟票据，1.5 秒一轮，最多 200 轮；超时按失败处理。
      for (var attempt = 0; attempt < 200; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final status = await client.getJson('/api/pair/requests/$requestId');
        final value = status['status'] as String? ?? 'pending';

        switch (value) {
          case 'approved':
            final deviceId = status['device_id'] as String?;
            if (deviceId == null) {
              throw const ApiException(
                code: 'internal_error',
                message: '批准但缺少 device_id',
                retryable: false,
                hint: '服务返回了预期之外的数据',
              );
            }
            final fingerprint = status['server_fingerprint'] as String?;
            await ref
                .read(sessionProvider.notifier)
                .completePairing(
                  serverUrl: serverUrl,
                  deviceId: deviceId,
                  deviceName: deviceName,
                  fingerprint: fingerprint,
                  tlsFingerprint: observed,
                );
            state = PairingState(
              phase: PairingPhase.approved,
              message: '配对完成',
              fingerprint: fingerprint,
              tlsFingerprint: observed,
            );
            return;
          case 'rejected':
            throw const ApiException(
              code: 'forbidden',
              message: 'pairing rejected',
              retryable: false,
              hint: '本机拒绝了这次配对',
            );
          case 'expired':
            throw const ApiException(
              code: 'unauthenticated',
              message: 'pairing expired',
              retryable: true,
              hint: '配对码已过期，请在本机重新生成',
            );
          case 'locked':
            throw const ApiException(
              code: 'unauthenticated',
              message: 'pairing locked',
              retryable: true,
              hint: '错误次数过多，票据已作废，请重新生成配对码',
            );
          default:
            continue;
        }
      }

      throw const ApiException(
        code: 'rate_limited',
        message: 'pairing timeout',
        retryable: true,
        hint: '等待确认超时，请重新生成配对码',
      );
    } on ApiException catch (error) {
      state = PairingState(
        phase: PairingPhase.failed,
        message: error.userMessage,
        tlsFingerprint: observed,
        code: error.code,
      );
    } finally {
      client.close();
    }
  }

  void reset() => state = const PairingState.idle();
}

/// 已登录后的 API 客户端。未就绪时为 null。
final Provider<ApiClient?> apiClientProvider = Provider<ApiClient?>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session == null || !session.isReady) {
    return null;
  }
  final client = ApiClient(
    baseUrl: session.serverUrl,
    token: session.token,
    httpClient: createPinnedClient(
      baseUrl: session.serverUrl,
      pinned: session.serverTlsFingerprint,
    ),
  );
  ref.onDispose(client.close);
  return client;
});

// 模式（CODE / WORK）已经从界面移除：不再保存"当前视角"，也不再按它取列表。
// 需要 Git 能力的项目由创建时的「Git 仓库」开关决定，服务端以项目记录为准。
