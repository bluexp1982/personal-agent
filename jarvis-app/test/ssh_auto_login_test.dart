import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ssh/ssh_connector.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_credentials.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/features/ssh/ssh_page.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const String _host = '192.168.1.10';

class _FakeSessionController extends SessionController {
  _FakeSessionController(this.value);

  final SessionState value;

  @override
  Future<SessionState> build() async => value;
}

class _FakeShell implements SshShell {
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(List<int> data) {}

  @override
  void resizeTerminal(int cols, int rows) {}

  @override
  void close() {
    if (!_out.isClosed) {
      _out.close();
    }
  }

  /// 模拟远端 / 隧道那头结束：客户端据此进入"已断开"。
  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

class _FakeConnector implements SshConnector {
  static const SshTunnelInfo _ready = SshTunnelInfo(
    enabled: true,
    target: '127.0.0.1:22',
    sshdReachable: true,
  );

  Object? openError;
  int openCalls = 0;
  int probeCalls = 0;

  /// 最近一次建立的 shell，用来模拟掉线。
  _FakeShell? shell;

  /// 非空时 open 会停在这里，用来观察"重连进行中"的界面。
  Completer<void>? gate;

  @override
  Future<SshTunnelInfo> probe({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
  }) async {
    probeCalls++;
    return _ready;
  }

  @override
  Future<SshConnection> open({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
    required String username,
    required String password,
    required Future<bool> Function(SshHostKey key) verifyHostKey,
    int cols = 80,
    int rows = 24,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    openCalls++;
    final error = openError;
    if (error != null) {
      throw error;
    }
    final gate = this.gate;
    if (gate != null) {
      await gate.future;
    }
    final created = _FakeShell();
    shell = created;
    return SshConnection(shell: created, onClose: () async => created.close());
  }
}

SecretStore _store() {
  final dir = Directory.systemTemp.createTempSync('ssh-auto-login-test');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return SecretStore(fallbackDirectory: dir);
}

ProviderContainer _container({
  required SshCredentials credentials,
  required _FakeConnector connector,
}) {
  final container = ProviderContainer(
    overrides: [
      sshConnectorProvider.overrideWithValue(connector),
      sshCredentialsProvider.overrideWithValue(credentials),
      sessionProvider.overrideWith(() => _FakeSessionController(_session)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 打开一个只挂着终端页的界面（右侧面板里的那一页）。
Widget _pageHarness(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: SshPage(allowFullscreen: false)),
    ),
  );
}

/// 等一串真实异步（钥匙串回退文件的 IO）落定：`pumpAndSettle` 遇上终端里的
/// 光标闪烁会一直等下去，所以只推进固定帧数。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自动登录开关默认开，落盘后能读回关闭状态', () async {
    final store = _store();
    final credentials = SshCredentials(store);

    expect(await credentials.readAutoLogin(), isTrue, reason: '未写入时默认开');

    await credentials.saveAutoLogin(false);
    expect(await credentials.readAutoLogin(), isFalse);
    expect(await store.read(kSshAutoLoginKey), 'false');

    // 换一个容器模拟重启：偏好要从盘上读回来。
    final reopened = _container(
      credentials: SshCredentials(store),
      connector: _FakeConnector(),
    );
    expect(
      await reopened.read(sshAutoLoginProvider.notifier).restore(),
      isFalse,
    );
    expect(reopened.read(sshAutoLoginProvider), isFalse);
  });

  test('存储里的脏值回落为「开」', () async {
    final store = _store();
    await store.write(kSshAutoLoginKey, 'neon');
    expect(await SshCredentials(store).readAutoLogin(), isTrue);
  });

  test('清除凭据只删用户名与密码，保留主机指纹', () async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');
    await credentials.saveHostKey(_host, 'SHA256:OK');

    await credentials.clear(host: _host);

    expect(await credentials.readUsername(_host), isNull);
    expect(await credentials.readPassword(_host), isNull);
    expect(
      await credentials.readHostKey(_host),
      'SHA256:OK',
      reason: '清凭据不等于不再信任那台机器，指纹要留着防中间人',
    );
  });

  test('设置页保存时留空的密码不覆盖已存值', () async {
    final store = _store();
    final credentials = SshCredentials(store);
    final container = _container(
      credentials: credentials,
      connector: _FakeConnector(),
    );

    final notifier = container.read(sshSavedCredentialsProvider.notifier);
    await notifier.save(username: 'yao', password: 'secret');
    await notifier.save(username: 'yao2', password: '');

    expect(await credentials.readPassword(_host), 'secret');
    expect(await credentials.readUsername(_host), 'yao2');

    await notifier.clear();
    expect(await credentials.readPassword(_host), isNull);
    expect(await credentials.readUsername(_host), isNull);
  });

  test('完整凭据 + 开关开时给出可自动登录的决策', () async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final container = _container(
      credentials: credentials,
      connector: _FakeConnector(),
    );
    final plan = await container
        .read(sshControllerProvider.notifier)
        .loadAutoLoginPlan();

    expect(plan.autoLogin, isTrue);
    expect(plan.canAutoLogin, isTrue);
    expect(plan.credentials.username, 'yao');
    expect(plan.credentials.password, 'secret');
  });

  test('开关关闭 / 密码缺失 / 已连接时都不自动登录', () async {
    final store = _store();
    final credentials = SshCredentials(store);
    final connector = _FakeConnector();
    final container = _container(
      credentials: credentials,
      connector: connector,
    );
    final controller = container.read(sshControllerProvider.notifier);

    // 只有用户名、没有密码：开关开着也不能自动登录。
    await credentials.saveUsername(host: _host, username: 'yao');
    expect((await controller.loadAutoLoginPlan()).canAutoLogin, isFalse);

    // 密码补上但开关关掉。
    await credentials.save(host: _host, username: 'yao', password: 'secret');
    await container.read(sshAutoLoginProvider.notifier).setEnabled(false);
    final disabled = await controller.loadAutoLoginPlan();
    expect(disabled.autoLogin, isFalse);
    expect(disabled.canAutoLogin, isFalse);

    // 开关打开，但已经连着：不该再拨一次号。
    await container.read(sshAutoLoginProvider.notifier).setEnabled(true);
    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: true,
    );
    expect((await controller.loadAutoLoginPlan()).canAutoLogin, isFalse);
  });

  testWidgets('打开终端即自动登录，不经过连接表单', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final connector = _FakeConnector();
    final container = _container(
      credentials: credentials,
      connector: connector,
    );

    await tester.pumpWidget(_pageHarness(container));
    expect(
      find.text('连接服务器'),
      findsNothing,
      reason: '自动登录过程中不该把表单画出来：那看起来像界面替用户点了按钮',
    );
    await _pumpFrames(tester);

    expect(connector.openCalls, 1, reason: '已保存凭据 + 开关开，应当直接登录');
    expect(find.text('连接服务器'), findsNothing, reason: '自动登录走通后不该再看到连接表单');
    expect(container.read(sshControllerProvider).isConnected, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 5);
  });

  testWidgets('关闭自动登录后打开终端只显示预填好的表单', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');
    await credentials.saveAutoLogin(false);

    final connector = _FakeConnector();
    final container = _container(
      credentials: credentials,
      connector: connector,
    );

    await tester.pumpWidget(_pageHarness(container));
    await _pumpFrames(tester);

    expect(connector.openCalls, 0, reason: '开关关掉后只能由用户点连接');
    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.text('yao'), findsOneWidget, reason: '用户名应该已经预填');
    expect(find.text('secret'), findsOneWidget, reason: '密码也应该已经预填');

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 5);
  });

  testWidgets('自动登录失败退回表单，并说明原因', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'wrong');

    final connector = _FakeConnector()..openError = SSHAuthFailError('denied');
    final container = _container(
      credentials: credentials,
      connector: connector,
    );

    await tester.pumpWidget(_pageHarness(container));
    await _pumpFrames(tester);

    expect(connector.openCalls, 1);
    expect(
      container.read(sshControllerProvider).failure,
      SshFailureKind.authFailed,
    );
    expect(
      find.text(SshFailureKind.authFailed.hint),
      findsOneWidget,
      reason: '失败原因要复用既有文案，用户才知道下一步做什么',
    );
    expect(find.text('连接服务器'), findsOneWidget, reason: '失败后必须回到表单');
    expect(find.text('wrong'), findsOneWidget, reason: '密码要预填，改一下就能重试');

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 5);
  });

  testWidgets('点重连不落回表单：终端留在原地并显示重连中', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final connector = _FakeConnector();
    final container = _container(
      credentials: credentials,
      connector: connector,
    );

    await tester.pumpWidget(_pageHarness(container));
    await _pumpFrames(tester);
    expect(container.read(sshControllerProvider).isConnected, isTrue);

    // 隧道那头断了：界面变成"已断开 + 重新连接"。
    connector.shell!.finish();
    await _pumpFrames(tester, frames: 5);
    expect(container.read(sshControllerProvider).phase, SshPhase.disconnected);

    // 让重连停在握手中，好观察这一段的界面。
    connector.gate = Completer<void>();
    await tester.tap(find.byTooltip('重连'));
    await _pumpFrames(tester, frames: 5);

    expect(
      find.text('连接服务器'),
      findsNothing,
      reason: '重连是用户已经点过按钮的动作，不该再翻出要他重填密码的表单',
    );
    expect(find.text('正在重连…'), findsOneWidget);

    connector.gate!.complete();
    await _pumpFrames(tester);
    expect(connector.openCalls, 2);
    expect(container.read(sshControllerProvider).isConnected, isTrue);
    expect(find.text('正在重连…'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 5);
  });

  testWidgets('重连失败才回到表单并说明原因', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final connector = _FakeConnector();
    final container = _container(
      credentials: credentials,
      connector: connector,
    );

    await tester.pumpWidget(_pageHarness(container));
    await _pumpFrames(tester);

    connector.shell!.finish();
    await _pumpFrames(tester, frames: 5);
    expect(container.read(sshControllerProvider).phase, SshPhase.disconnected);

    connector.openError = SSHAuthFailError('denied');
    await tester.tap(find.byTooltip('重连'));
    await _pumpFrames(tester);

    expect(
      find.text(SshFailureKind.authFailed.hint),
      findsOneWidget,
      reason: '重连失败要给出原因，而不是无声停住',
    );
    expect(find.text('连接服务器'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 5);
  });
}
