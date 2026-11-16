import 'package:jarvis_app/src/core/browser/browser_controller.dart';
import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/browser/browser_zoom.dart';
import 'package:jarvis_app/src/core/browser/server_tunnel.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:flutter/foundation.dart';
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
  /// 两个标签的 id：与标签栏里的 `browserTabs` 同一口径，这里只要互不相同。
  const String first = 'browser-1';
  const String second = 'browser-2';

  late List<BrowserTarget> opened;
  late int closed;
  late ProviderContainer container;

  BrowserChannel channelFor(BrowserTarget target) {
    return BrowserChannel(
      internalUri: Uri.parse('http://127.0.0.1:5555/'),
      address: target.address,
      close: () async {
        closed++;
      },
    );
  }

  setUp(() {
    opened = <BrowserTarget>[];
    closed = 0;

    Future<BrowserChannel> fakeOpener(
      BrowserTarget target,
      BrowserOpenContext context,
    ) async {
      opened.add(target);
      if (target is ServerPortTarget && target.port == 9) {
        throw const ServerTunnelException(
          ServerTunnelFailure.unavailable,
          'down',
          statusCode: 503,
        );
      }
      return channelFor(target);
    }

    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(_ReadySession.new),
        browserChannelOpenerProvider.overrideWithValue(fakeOpener),
      ],
    );
    addTearDown(container.dispose);
  });

  BrowserSessionState stateOf([String id = first]) =>
      container.read(browserSessionProvider(id));

  Future<BrowserController> ready([String id = first]) async {
    await container.read(sessionProvider.future);
    return container.read(browserSessionProvider(id).notifier);
  }

  test('默认来源是服务器，打开后地址显示逻辑端口而不是桥接端口', () async {
    final controller = await ready();
    expect(stateOf().source, BrowserSource.server);

    await controller.open('3000');

    final state = stateOf();
    expect(state.target, isA<ServerPortTarget>());
    expect(state.internalUri.toString(), 'http://127.0.0.1:5555/');
    expect(state.address, 'localhost:3000');
    expect(state.loading, isTrue);
    expect(state.requestId, greaterThan(0));
    expect(opened, hasLength(1));
  });

  test('换端口先释放旧通道，再建新的', () async {
    final controller = await ready();

    await controller.open('3000');
    await controller.open('8080');

    expect(closed, 1, reason: '旧隧道必须先关，不能两条同时活着');
    expect(opened, hasLength(2));
    expect(
      (opened.last as ServerPortTarget).port,
      8080,
    );
    expect(stateOf().address, 'localhost:8080');
  });

  test('来源徽标改成「本机」后，纯端口落到客户端', () async {
    final controller = await ready();
    controller.selectSource(BrowserSource.client);

    await controller.open('5173');

    expect(opened.single, isA<ClientPortTarget>());
    expect(stateOf().address, 'localhost:5173');
  });

  test('通道失败时给出可重试的失败原因，并清掉旧页面', () async {
    final controller = await ready();

    await controller.open('3000');
    await controller.open('9');

    final state = stateOf();
    expect(state.error, isNotNull);
    expect(state.error!.kind, BrowserFailureKind.unavailable);
    expect(state.error!.canRetry, isTrue);
    expect(state.internalUri, isNull, reason: '通道没建起来就不该露出旧页面');
    expect(closed, 1, reason: '旧通道仍然要释放');
  });

  test('无法识别的输入不进通道层', () async {
    final controller = await ready();

    await controller.open('   ');

    expect(opened, isEmpty);
    expect(stateOf().error?.kind, BrowserFailureKind.invalidInput);
  });

  test('页面内跳转把内部 origin 还原成逻辑地址；跳到外部站点则如实显示', () async {
    final controller = await ready();
    await controller.open('3000');

    controller.syncView(uri: Uri.parse('http://127.0.0.1:5555/about?x=1'));
    expect(stateOf().address, 'localhost:3000/about?x=1');

    controller.syncView(uri: Uri.parse('https://example.com/outside'));
    expect(
      stateOf().address,
      'https://example.com/outside',
      reason: '跳出桥接 origin 后不能再套 localhost:3000',
    );
  });

  test('页内跳转记下当前页地址，刷新据此回到当前页而不是入口页', () async {
    final controller = await ready();
    await controller.open('3000');
    expect(stateOf().pageUri.toString(), 'http://127.0.0.1:5555/');

    controller.syncView(uri: Uri.parse('http://127.0.0.1:5555/harness/'));

    final state = stateOf();
    expect(state.pageUri.toString(), 'http://127.0.0.1:5555/harness/');
    expect(
      state.internalUri.toString(),
      'http://127.0.0.1:5555/',
      reason: '入口地址不动：地址栏的逻辑地址换算仍然靠它',
    );
    expect(state.address, 'localhost:3000/harness/');
  });

  test('换代重建 WebView 时清掉前进后退，不留下点不动的亮按钮', () async {
    final controller = await ready();
    await controller.open('3000');
    controller.syncView(canGoBack: true, canGoForward: true);

    // 新的平台视图没有历史：旧的可用性必须作废。
    controller.resetHistory();

    expect(stateOf().canGoBack, isFalse);
    expect(stateOf().canGoForward, isFalse);
  });

  test('关闭会话释放通道并回到空态', () async {
    final controller = await ready();
    await controller.open('3000');

    await controller.closeSession();

    expect(closed, 1);
    expect(stateOf().isEmpty, isTrue);
  });

  test('重试只递增请求号，不重建通道', () async {
    final controller = await ready();
    await controller.open('3000');
    final before = stateOf().requestId;

    controller.reload();

    final state = stateOf();
    expect(state.requestId, before + 1);
    expect(opened, hasLength(1), reason: '刷新复用同一条隧道');
  });

  test('两个浏览器标签的会话互不影响', () async {
    final a = await ready(first);
    final b = await ready(second);

    await a.open('3000');
    await b.open('8080');

    expect(stateOf(first).address, 'localhost:3000');
    expect(stateOf(second).address, 'localhost:8080');
    expect(opened, hasLength(2));
    expect(closed, 0, reason: '一个标签换地址不该动另一个标签的通道');
  });

  test('关掉一个标签只释放它自己的通道', () async {
    final a = await ready(first);
    final b = await ready(second);
    await a.open('3000');
    await b.open('8080');

    container.invalidate(browserSessionProvider(first));
    await Future<void>.delayed(Duration.zero);

    expect(closed, 1, reason: '只该收掉被关的那个标签的隧道');
    expect(stateOf(second).address, 'localhost:8080', reason: '另一个标签还活着');
  });

  test('点停止要把「加载中」收回来', () async {
    final controller = await ready();
    await controller.open('3000');
    expect(stateOf().loading, isTrue);

    // 平台不会再为"用户主动停止"发 onLoadStop，状态得自己收尾。
    controller.stopLoad();

    expect(stateOf().loading, isFalse);
    expect(stateOf().progress, 1);
  });

  test('新一次导航开始时清掉上一页的失败', () async {
    final controller = await ready();
    await controller.open('3000');
    controller.reportError('boom');
    expect(stateOf().error, isNotNull);

    // 后退 / 前进会以一次新的导航开始，上一页的失败卡不该再盖住新页面。
    controller.syncView(loading: true, progress: 0.05, clearError: true);

    expect(stateOf().error, isNull);
    expect(stateOf().loading, isTrue);
  });

  test('主文档一直没回音时给出可重试的错误，而不是无限转圈', () async {
    final controller = await ready();
    await controller.open('3000');

    controller.reportStalled();

    final state = stateOf();
    expect(state.loading, isFalse);
    expect(state.error?.kind, BrowserFailureKind.network);
    expect(state.error!.canRetry, isTrue);
  });

  test('页面已经在渲染时，看门狗不该打断它', () async {
    final controller = await ready();
    await controller.open('3000');
    // 有进度 = 请求有回音：长连接、SSE、没结束的 XHR 都是正常现象。
    controller.syncView(progress: 0.6);

    controller.reportStalled();

    expect(stateOf().error, isNull);
    expect(stateOf().loading, isTrue, reason: '还在加载就该继续显示进度');
  });

  test('标题去掉首尾空白，空标题归一成 null', () async {
    final controller = await ready();
    await controller.open('3000');

    controller.syncTitle('  示例站点  ');
    expect(stateOf().title, '示例站点');

    controller.syncTitle('   ');
    expect(stateOf().title, isNull);
  });

  test('图标回填后挂在当前页面上，跳到别的站点就失效', () async {
    final controller = await ready();
    await controller.open('3000');

    final icon = Uint8List.fromList(<int>[1, 2, 3]);
    controller.syncFavicon(icon, page: Uri.parse('http://127.0.0.1:5555/'));
    expect(stateOf().favicon, same(icon), reason: '同一份字节，标签栏不必重复解码');
    expect(stateOf().faviconOrigin, 'http://127.0.0.1:5555');

    // 同源子页面共用同一张图标，不该被清掉。
    controller.syncView(uri: Uri.parse('http://127.0.0.1:5555/about'));
    expect(stateOf().favicon, same(icon));

    // 跳出 origin 后旧站点的图标必须消失。
    controller.syncView(uri: Uri.parse('https://example.com/x'));
    expect(stateOf().favicon, isNull);
    expect(stateOf().faviconOrigin, isNull);
  });

  test('图标回来时页面已经换了 origin，结果丢弃', () async {
    final controller = await ready();
    await controller.open('3000');

    final stale = Uint8List.fromList(<int>[9]);
    controller.syncFavicon(stale, page: Uri.parse('http://127.0.0.1:5555/'));
    controller.syncView(uri: Uri.parse('https://example.com/x'));

    controller.syncFavicon(stale, page: Uri.parse('http://127.0.0.1:5555/'));

    expect(stateOf().favicon, isNull, reason: '上一站的图标不能贴到新页面上');
  });

  test('打开新地址会清掉上一页的标题与图标', () async {
    final controller = await ready();
    await controller.open('3000');
    controller.syncTitle('旧页面');
    controller.syncFavicon(
      Uint8List.fromList(<int>[1]),
      page: Uri.parse('http://127.0.0.1:5555/'),
    );

    await controller.open('8080');

    expect(stateOf().title, isNull);
    expect(stateOf().favicon, isNull);
  });

  test('缩放按 Chrome 梯度逐档走，两端不回环', () async {
    final controller = await ready();
    expect(stateOf().zoom, 1, reason: '新标签默认 100%');

    controller.zoomIn();
    expect(stateOf().zoom, 1.10);
    controller.zoomOut();
    expect(stateOf().zoom, 1.00);

    for (var i = 0; i < 20; i++) {
      controller.zoomOut();
    }
    expect(stateOf().zoom, kBrowserZoomMin, reason: '到下限后不再变化');

    for (var i = 0; i < 40; i++) {
      controller.zoomIn();
    }
    expect(stateOf().zoom, kBrowserZoomMax, reason: '到上限后不回环');

    controller.resetZoom();
    expect(stateOf().zoom, 1);
  });

  test('缩放属于标签：刷新、换地址都保持，另一个标签不受影响', () async {
    final a = await ready(first);
    final b = await ready(second);
    await a.open('3000');
    await b.open('8080');

    a.zoomIn();
    a.zoomIn();
    expect(stateOf(first).zoom, 1.25);
    expect(stateOf(second).zoom, 1, reason: '两个标签各记各的');

    a.reload();
    expect(stateOf(first).zoom, 1.25, reason: '刷新不该把比例丢掉');

    await a.open('8081');
    expect(stateOf(first).zoom, 1.25, reason: '同一标签换地址也保持');
  });

  test('通道建失败也保留缩放，比例不属于某一次加载', () async {
    final controller = await ready();
    await controller.open('3000');
    controller.zoomIn();
    expect(stateOf().zoom, 1.10);

    await controller.open('9');

    expect(stateOf().error, isNotNull);
    expect(stateOf().zoom, 1.10);
  });
}
