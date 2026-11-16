import 'dart:io';

import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_credentials.dart';
import 'package:jarvis_app/src/features/settings/settings_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _paired = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const SessionState _unpaired = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
);

const String _host = '192.168.1.10';

class _FakeSessionController extends SessionController {
  _FakeSessionController(this.value);

  final SessionState value;

  @override
  Future<SessionState> build() async => value;
}

SecretStore _store() {
  final dir = Directory.systemTemp.createTempSync('ssh-login-card-test');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return SecretStore(fallbackDirectory: dir);
}

ProviderContainer _container(SecretStore store, SessionState session) {
  final container = ProviderContainer(
    overrides: [
      secretStoreProvider.overrideWithValue(store),
      sshCredentialsProvider.overrideWithValue(SshCredentials(store)),
      apiClientProvider.overrideWithValue(null),
      sessionProvider.overrideWith(() => _FakeSessionController(session)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpPage(
  WidgetTester tester,
  ProviderContainer container,
  SessionState session,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 1400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SettingsSectionView(
            session: session,
            section: SettingsSection.connection,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('卡片渲染：默认自动登录开启，密码输入框是密文', (tester) async {
    final container = _container(_store(), _paired);
    await _pumpPage(tester, container, _paired);

    expect(find.text('SSH 登录'), findsOneWidget);
    expect(find.text('打开终端时自动登录'), findsOneWidget);
    expect(find.text('未保存'), findsOneWidget);
    expect(container.read(sshAutoLoginProvider), isTrue);

    final password = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(password.obscureText, isTrue, reason: '设置页也不该把密码画成明文');

    expect(tester.takeException(), isNull);
  });

  testWidgets('保存凭据：写入存储、密码框清空、状态变成已保存', (tester) async {
    final store = _store();
    final container = _container(store, _paired);
    await _pumpPage(tester, container, _paired);

    await tester.enterText(find.byType(TextField).at(0), 'yao');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final credentials = SshCredentials(store);
    expect(await credentials.readUsername(_host), 'yao');
    expect(await credentials.readPassword(_host), 'secret');
    expect(find.text('已保存'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
      reason: '保存后不该把密码留在输入框里',
    );
    expect(find.text('SSH 凭据已保存，打开终端将自动登录'), findsOneWidget);
  });

  testWidgets('密码留空再保存不覆盖已存密码', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final container = _container(store, _paired);
    await _pumpPage(tester, container, _paired);

    await tester.enterText(find.byType(TextField).at(0), 'yao2');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(await credentials.readUsername(_host), 'yao2');
    expect(
      await credentials.readPassword(_host),
      'secret',
      reason: '只想改用户名时不能把密码顺手清了',
    );
  });

  testWidgets('清除凭据后回到未保存状态', (tester) async {
    final store = _store();
    final credentials = SshCredentials(store);
    await credentials.save(host: _host, username: 'yao', password: 'secret');

    final container = _container(store, _paired);
    await _pumpPage(tester, container, _paired);

    expect(find.text('已保存'), findsOneWidget);

    await tester.tap(find.text('清除凭据'));
    await tester.pumpAndSettle();

    expect(await credentials.readUsername(_host), isNull);
    expect(await credentials.readPassword(_host), isNull);
    expect(find.text('未保存'), findsOneWidget);
  });

  testWidgets('未配对时禁用保存并给出说明', (tester) async {
    final container = _container(_store(), _unpaired);
    await _pumpPage(tester, container, _unpaired);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    expect(button.onPressed, isNull, reason: '没有会话令牌就没有可登录的目标');
    expect(find.text('还没有配对服务端：完成配对后才能保存 SSH 凭据'), findsOneWidget);
  });

  testWidgets('关掉自动登录开关会立刻落盘', (tester) async {
    final store = _store();
    final container = _container(store, _paired);
    await _pumpPage(tester, container, _paired);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(container.read(sshAutoLoginProvider), isFalse);
    expect(await SshCredentials(store).readAutoLogin(), isFalse);
  });
}
