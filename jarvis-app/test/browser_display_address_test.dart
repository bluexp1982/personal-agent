import 'package:jarvis_app/src/core/browser/browser_controller.dart';
import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/browser/browser_targets.dart';
import 'package:jarvis_app/src/core/browser/server_tunnel.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已配对、已登录的会话替身：控制器只读 `isReady` 与几个字段。
class _ReadySession extends SessionController {
  @override
  Future<SessionState> build() async => const SessionState(
    serverUrl: 'http://127.0.0.1:8787',
    deviceId: 'dev_test',
    token: 'token_test',
  );
}

void main() {
  const String tab = 'browser-1';

  /// 预览站给的真实地址：随机端口 + 访问令牌，都不该出现在地址栏里。
  const String previewUrl =
      'http://127.0.0.1:9999/f/abc123/pid_1/hello-demo/report.html';

  late ProviderContainer container;

  setUp(() {
    Future<BrowserChannel> fakeOpener(
      BrowserTarget target,
      BrowserOpenContext context,
    ) async {
      if (target is ServerPortTarget && target.port == 9) {
        throw const ServerTunnelException(
          ServerTunnelFailure.unavailable,
          'down',
          statusCode: 503,
        );
      }
      return BrowserChannel(
        internalUri: Uri.parse('http://127.0.0.1:5555/'),
        address: target.address,
        close: () async {},
      );
    }

    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(_ReadySession.new),
        browserChannelOpenerProvider.overrideWithValue(fakeOpener),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<BrowserController> ready() async {
    await container.read(sessionProvider.future);
    return container.read(browserSessionProvider(tab).notifier);
  }

  BrowserSessionState stateOf() => container.read(browserSessionProvider(tab));

  test('服务端给的展示地址盖住真实地址，但内部地址仍是真实的那一条', () async {
    final controller = await ready();

    await controller.open(
      browserInputFromUrl(previewUrl),
      display: 'hello-demo/report.html',
    );

    final state = stateOf();
    expect(state.address, 'hello-demo/report.html');
    expect(
      state.addressOverride,
      'hello-demo/report.html',
      reason: '入口页加载完成后地址栏还要靠它覆盖',
    );
    expect(
      state.internalUri.toString(),
      'http://127.0.0.1:5555/',
      reason: '加载用的是桥接地址，展示值是另一回事',
    );
  });

  test('页内跳转后展示值失效，如实显示当前位置', () async {
    final controller = await ready();
    await controller.open(
      browserInputFromUrl(previewUrl),
      display: 'hello-demo/report.html',
    );

    controller.syncView(uri: Uri.parse('http://127.0.0.1:5555/other.html'));

    expect(
      stateOf().address,
      isNot('hello-demo/report.html'),
      reason: '跳到别的页面还显示入口的展示值，用户会以为没动过',
    );
    expect(stateOf().address, contains('other.html'));
  });

  test('手动输入的地址不会继承上一次的展示值', () async {
    final controller = await ready();
    await controller.open(
      browserInputFromUrl(previewUrl),
      display: 'hello-demo/report.html',
    );

    await controller.open('3000');

    final state = stateOf();
    expect(state.addressOverride, isNull);
    expect(state.address, 'localhost:3000');
  });

  test('通道失败时展示地址仍然保留，错误卡上的地址才是用户认得的那个', () async {
    final controller = await ready();

    // 端口 9 在假 opener 里会抛 unavailable。
    await controller.open('9', display: 'hello-demo/report.html');

    final state = stateOf();
    expect(state.error, isNotNull);
    expect(state.address, 'hello-demo/report.html');
    expect(state.addressOverride, 'hello-demo/report.html');
  });
}
