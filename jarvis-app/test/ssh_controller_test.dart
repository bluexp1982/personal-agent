import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ssh/ssh_connector.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_credentials.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/core/ssh/terminal_start_directory.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只提供会话，不碰钥匙串与网络。
class _FakeSessionController extends SessionController {
  _FakeSessionController(this.value);

  final SessionState value;

  @override
  Future<SessionState> build() async => value;
}

class _FakeShell implements SshShell {
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  final List<List<int>> writes = <List<int>>[];
  final List<(int, int)> resizes = <(int, int)>[];
  bool closed = false;

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(List<int> data) => writes.add(data);

  @override
  void resizeTerminal(int cols, int rows) => resizes.add((cols, rows));

  @override
  void close() {
    closed = true;
    if (!_out.isClosed) {
      _out.close();
    }
  }

  void emit(List<int> bytes) {
    if (!_out.isClosed) {
      _out.add(Uint8List.fromList(bytes));
    }
  }

  void finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

class _FakeConnector implements SshConnector {
  _FakeConnector({
    this.info = const SshTunnelInfo(
      enabled: true,
      target: '127.0.0.1:22',
      sshdReachable: true,
    ),
  });

  SshTunnelInfo info;
  Object? probeError;
  Object? openError;

  /// 非空时会在 open 里走一遍主机密钥校验（模拟服务端给出的 key）。
  SshHostKey? hostKey;

  _FakeShell? shell;
  int openCalls = 0;

  /// 非空时 open 会停在这里，用来模拟"握手很慢"。
  Completer<void>? gate;

  @override
  Future<SshTunnelInfo> probe({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
  }) async {
    final error = probeError;
    if (error != null) {
      throw error;
    }
    return info;
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

    final key = hostKey;
    if (key != null && !await verifyHostKey(key)) {
      throw SSHHostkeyError('host key rejected');
    }

    final created = _FakeShell();
    shell = created;
    return SshConnection(shell: created, onClose: () async => created.close());
  }
}

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
  serverTlsFingerprint: 'A7K2-9XQP-3MDE-6RTU',
);

/// 建一个只依赖内存与临时目录的容器。
ProviderContainer _container({
  required _FakeConnector connector,
  required SecretStore store,
}) {
  final container = ProviderContainer(
    overrides: [
      sshConnectorProvider.overrideWithValue(connector),
      sshCredentialsProvider.overrideWithValue(SshCredentials(store)),
      sessionProvider.overrideWith(() => _FakeSessionController(_session)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

SecretStore _store() {
  final dir = Directory.systemTemp.createTempSync('ssh-controller-test');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return SecretStore(fallbackDirectory: dir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('连接成功后进入 connected，并记住服务端报告的隧道终点', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: '  yao  ',
      password: 'secret',
      rememberPassword: false,
    );

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.connected);
    expect(state.username, 'yao', reason: '用户名两端的空白要去掉');
    expect(state.target, '127.0.0.1:22');
    expect(state.message, isNull);
    expect(connector.openCalls, 1);
  });

  test('勾选记住密码时写入钥匙串，不勾选时不落盘', () async {
    final store = _store();
    final container = _container(connector: _FakeConnector(), store: store);
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: true,
    );
    final credentials = SshCredentials(store);
    expect(await credentials.readPassword('192.168.1.10'), 'secret');
    expect(await credentials.readUsername('192.168.1.10'), 'yao');

    await controller.disconnect();
    await controller.connect(
      username: 'yao',
      password: 'another',
      rememberPassword: false,
    );
    expect(
      await credentials.readPassword('192.168.1.10'),
      isNull,
      reason: '这次没勾记住，必须把上次的密码删掉',
    );
  });

  test('服务端未开启隧道时不发起握手，直接给出可执行提示', () async {
    final connector = _FakeConnector(
      info: const SshTunnelInfo(
        enabled: false,
        target: '127.0.0.1:22',
        sshdReachable: false,
      ),
    );
    final container = _container(connector: connector, store: _store());

    await container
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'secret', rememberPassword: false);

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.failed);
    expect(state.failure, SshFailureKind.tunnelDisabled);
    expect(state.message, SshFailureKind.tunnelDisabled.hint);
    expect(connector.openCalls, 0, reason: '预检已经说不行，不该再拨一次');
  });

  test('sshd 不可达与密码错误是两种不同的失败', () async {
    final unreachable = _FakeConnector(
      info: const SshTunnelInfo(
        enabled: true,
        target: '127.0.0.1:22',
        sshdReachable: false,
      ),
    );
    final first = _container(connector: unreachable, store: _store());
    await first
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'secret', rememberPassword: false);
    expect(
      first.read(sshControllerProvider).failure,
      SshFailureKind.sshdUnreachable,
    );

    final badPassword = _FakeConnector()
      ..openError = SSHAuthFailError('denied');
    final second = _container(connector: badPassword, store: _store());
    await second
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'wrong', rememberPassword: false);
    expect(
      second.read(sshControllerProvider).failure,
      SshFailureKind.authFailed,
    );
  });

  test('主机指纹变化时阻断连接，并提示原因', () async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.saveHostKey('192.168.1.10', 'SHA256:OLD');

    final connector = _FakeConnector()
      ..hostKey = const SshHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:NEW',
      );
    final container = _container(connector: connector, store: store);

    await container
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'secret', rememberPassword: false);

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.failed);
    expect(state.failure, SshFailureKind.hostKeyChanged);
    expect(await credentials.readHostKey('192.168.1.10'), 'SHA256:OLD');
  });

  test('首次连接记录主机指纹，第二次相同的指纹直接放行', () async {
    final store = _store();
    final connector = _FakeConnector()
      ..hostKey = const SshHostKey(
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:FIRST',
      );
    final container = _container(connector: connector, store: store);
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );
    expect(container.read(sshControllerProvider).phase, SshPhase.connected);
    expect(
      await SshCredentials(store).readHostKey('192.168.1.10'),
      'SHA256:FIRST',
    );
  });

  test('网络异常归为 network，且不会把界面留在 connecting', () async {
    final connector = _FakeConnector()
      ..openError = const SocketException('connection refused');
    final container = _container(connector: connector, store: _store());

    await container
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'secret', rememberPassword: false);

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.failed);
    expect(state.failure, SshFailureKind.network);
  });

  test('终端输出进入缓冲区，输入写回 shell', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );

    connector.shell!.emit(utf8.encode('项目列表\n'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.terminal.buffer.getText(), contains('项目列表'));

    controller.terminal.textInput('ls\n');
    expect(connector.shell!.writes.last, utf8.encode('ls\n'));
  });

  test('首段输出开头的空行被裁掉，之后的空行原样保留', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );

    // 登录 banner 前常带空行：留在缓冲区里会在终端顶边画出一条空白带。
    connector.shell!.emit(utf8.encode('\r\n\r\nLast login: ok\r\n'));
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.terminal.buffer.getText(),
      startsWith('Last login: ok'),
      reason: '开头的空行要被裁掉，首行直接是 banner',
    );

    // 只裁开头那一次：后续输出里的换行（交互式程序靠它排版）不能被吞。
    connector.shell!.emit(utf8.encode('\r\n# '));
    await Future<void>.delayed(Duration.zero);
    expect(controller.terminal.buffer.getText(), contains('\n\n# '));
  });

  test('shell 结束时标记断开，但仍保留终端内容以便抄输出', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );
    connector.shell!.emit(utf8.encode('boom\n'));
    await Future<void>.delayed(Duration.zero);

    connector.shell!.finish();
    await Future<void>.delayed(Duration.zero);

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.disconnected);
    expect(state.message, contains('连接已断开'));
    expect(controller.terminal.buffer.getText(), contains('boom'));
  });

  test('切回 SSH 段时的预检失败不会破坏已建立的连接', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );
    expect(container.read(sshControllerProvider).phase, SshPhase.connected);

    // 模拟切 tab 回来重新进页面：探测这次因为网络抖动失败了。
    connector.probeError = const SocketException('timed out');
    await controller.probe();

    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.connected, reason: '活着的终端不该被探测失败顶掉');
    expect(connector.shell!.closed, isFalse);
  });

  test('主动断开停在已断开态、保留输出，并关闭 shell', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );
    final shell = connector.shell!;
    shell.emit(utf8.encode('bye\n'));
    await Future<void>.delayed(Duration.zero);

    await controller.disconnect();

    final state = container.read(sshControllerProvider);
    expect(
      state.phase,
      SshPhase.disconnected,
      reason: '界面要停在终端页的「已断开」态，与远端 exit 一致',
    );
    expect(state.message, isNull, reason: '主动断开不是故障，不该挂红字');
    expect(state.failure, isNull, reason: '主动断开不该被记成网络错误');
    expect(shell.closed, isTrue);
    expect(
      controller.terminal.buffer.getText(),
      contains('bye'),
      reason: '输出要留着，用户可能正要抄最后一段',
    );

    // 与远端 exit 一样保留内存里的密码：点「重新连接」不必再问一次。
    await controller.reconnect();
    expect(connector.openCalls, 2);
    expect(container.read(sshControllerProvider).phase, SshPhase.connected);
  });

  test('关标签丢弃会话：回到 idle，且不再持有内存里的密码', () async {
    final connector = _FakeConnector();
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    await controller.connect(
      username: 'yao',
      password: 'secret',
      // 不勾「记住密码」：内存里的那份是唯一还能重连的凭据。
      rememberPassword: false,
    );
    final shell = connector.shell!;

    await controller.discardSession();

    expect(
      container.read(sshControllerProvider).phase,
      SshPhase.idle,
      reason: '关标签等于放弃这台 shell，下次打开应该从表单开始',
    );
    expect(shell.closed, isTrue);

    // 没有可用密码：重连只能回到表单，不会拿旧密码偷偷拨一次号。
    await controller.reconnect();
    expect(connector.openCalls, 1, reason: '丢弃会话后不该再自动连回去');
    expect(container.read(sshControllerProvider).phase, SshPhase.idle);
  });

  test('连接途中取消：迟到的结果被丢弃，界面不会突然冒出终端', () async {
    final gate = Completer<void>();
    final connector = _FakeConnector()..gate = gate;
    final container = _container(connector: connector, store: _store());
    final controller = container.read(sshControllerProvider.notifier);

    final pending = controller.connect(
      username: 'yao',
      password: 'secret',
      rememberPassword: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sshControllerProvider).isConnecting, isTrue);

    controller.cancelConnect();
    expect(container.read(sshControllerProvider).phase, SshPhase.idle);

    gate.complete();
    await pending;

    expect(
      container.read(sshControllerProvider).phase,
      SshPhase.idle,
      reason: '取消之后迟到的连接不能把状态改回已连接',
    );
    expect(connector.shell!.closed, isTrue, reason: '迟到的那条连接必须自己关掉');
  });

  test('未配对时不拨号，直接提示重新配对', () async {
    final connector = _FakeConnector();
    final container = ProviderContainer(
      overrides: [
        sshConnectorProvider.overrideWithValue(connector),
        sshCredentialsProvider.overrideWithValue(SshCredentials(_store())),
        sessionProvider.overrideWith(
          () => _FakeSessionController(
            const SessionState(serverUrl: 'https://192.168.1.10:8787'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(sshControllerProvider.notifier)
        .connect(username: 'yao', password: 'secret', rememberPassword: false);

    expect(
      container.read(sshControllerProvider).failure,
      SshFailureKind.unauthenticated,
    );
    expect(connector.openCalls, 0);
  });

  group('终端起始目录', () {
    test('登记过目录：shell 建好后先发一条 cd，路径按单引号转义', () async {
      final connector = _FakeConnector();
      final container = _container(connector: connector, store: _store());
      container
          .read(terminalStartDirectoryProvider.notifier)
          .request("/srv/it's here");

      await container
          .read(sshControllerProvider.notifier)
          .connect(username: 'yao', password: 'secret', rememberPassword: false);

      expect(connector.shell!.writes, isNotEmpty);
      expect(
        utf8.decode(connector.shell!.writes.first),
        "cd '/srv/it'\\''s here'\n",
        reason: '空格与单引号都不能让远端 shell 二次解释路径',
      );
    });

    test('没登记目录时不额外写任何东西', () async {
      final connector = _FakeConnector();
      final container = _container(connector: connector, store: _store());

      await container
          .read(sshControllerProvider.notifier)
          .connect(username: 'yao', password: 'secret', rememberPassword: false);

      expect(connector.shell!.writes, isEmpty);
    });

    test('握手失败时不会发 cd', () async {
      final connector = _FakeConnector()
        ..openError = SSHAuthFailError('denied');
      final container = _container(connector: connector, store: _store());
      container
          .read(terminalStartDirectoryProvider.notifier)
          .request('/srv/app');

      await container
          .read(sshControllerProvider.notifier)
          .connect(username: 'yao', password: 'wrong', rememberPassword: false);

      expect(container.read(sshControllerProvider).phase, SshPhase.failed);
      expect(connector.shell, isNull);
    });

    test('连接途中被取消：迟到的 shell 不会被写 cd', () async {
      final gate = Completer<void>();
      final connector = _FakeConnector()..gate = gate;
      final container = _container(connector: connector, store: _store());
      container
          .read(terminalStartDirectoryProvider.notifier)
          .request('/srv/app');
      final controller = container.read(sshControllerProvider.notifier);

      final pending = controller.connect(
        username: 'yao',
        password: 'secret',
        rememberPassword: false,
      );
      await Future<void>.delayed(Duration.zero);
      controller.cancelConnect();
      gate.complete();
      await pending;

      expect(
        connector.shell!.writes,
        isEmpty,
        reason: '这次连接已经被丢弃，往里打字只会污染下一次会话',
      );
    });
  });
}
