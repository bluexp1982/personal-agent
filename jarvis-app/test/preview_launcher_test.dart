import 'package:jarvis_app/src/core/browser/browser_controller.dart';
import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/preview_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预览打开策略：同一个页面复用右栏标签，不同页面新开。
///
/// 隧道换成替身（与 `browser_controller_test` 同一写法）：这里验的是标签
/// 复不复用、重开时用的是哪条地址，不验真实网络。

/// 已配对、已登录的会话替身：控制器只读 `isReady` 与几个字段。
class _ReadySession extends SessionController {
  @override
  Future<SessionState> build() async => const SessionState(
    serverUrl: 'http://127.0.0.1:8787',
    deviceId: 'dev_test',
    token: 'token_test',
  );
}

class _Harness {
  _Harness({required this.container, required this.context, required this.ref});

  final ProviderContainer container;
  final BuildContext context;
  final WidgetRef ref;
}

void main() {
  late List<BrowserTarget> opened;

  BrowserChannel channelFor(BrowserTarget target) {
    // 与真实通道一致：internalUri 保留目标路径（预览站地址的 /f/… 段），
    // 只把 host 换成本机桥接端口。
    final path = switch (target) {
      ServerPortTarget(:final path) => path,
      ClientPortTarget(:final path) => path,
      ClientDirectoryTarget() => '/',
      InternetTarget(:final uri) => uri.path,
    };
    return BrowserChannel(
      internalUri: Uri.parse('http://127.0.0.1:9999$path'),
      address: target.address,
      close: () async {},
    );
  }

  setUp(() {
    opened = <BrowserTarget>[];
  });

  Future<_Harness> pump(WidgetTester tester) async {
    Future<BrowserChannel> fakeOpener(
      BrowserTarget target,
      BrowserOpenContext context,
    ) async {
      opened.add(target);
      return channelFor(target);
    }

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(_ReadySession.new),
        browserChannelOpenerProvider.overrideWithValue(fakeOpener),
      ],
    );
    addTearDown(container.dispose);

    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (ctx, widgetRef, _) {
              context = ctx;
              ref = widgetRef;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return _Harness(container: container, context: context, ref: ref);
  }

  testWidgets('同一页面重复打开：只留一个标签，并用新地址重开', (tester) async {
    final harness = await pump(tester);

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/cat.html',
      wide: true,
      display: 'code-001/cat.html',
    );
    await tester.pump();

    final first = harness.container.read(filePaneTabProvider);
    expect(first.browserTabs, hasLength(1));
    final firstId = first.activeId;
    expect(firstId, isNotNull);

    // 第二次：同一文件、换了预览端口与令牌。
    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:6666/f/tok_b/project-1/cat.html',
      wide: true,
      display: 'code-001/cat.html',
    );
    await tester.pump();

    final after = harness.container.read(filePaneTabProvider);
    expect(after.browserTabs, hasLength(1), reason: '同一页面不该堆出第二个标签');
    expect(after.activeId, firstId, reason: '应该跳回原来那个标签');
    expect(opened, hasLength(2), reason: '命中后仍要用新地址重开一次通道');

    final session = harness.container.read(browserSessionProvider(firstId!));
    expect(session.addressOverride, 'code-001/cat.html');
    expect(
      (session.target! as ServerPortTarget).port,
      6666,
      reason: '重开必须用本次的地址，否则令牌过期会 403',
    );
  });

  testWidgets('不同文件各开一个标签', (tester) async {
    final harness = await pump(tester);

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/cat.html',
      wide: true,
      display: 'code-001/cat.html',
    );
    await tester.pump();

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/dog.html',
      wide: true,
      display: 'code-001/dog.html',
    );
    await tester.pump();

    final state = harness.container.read(filePaneTabProvider);
    expect(state.browserTabs, hasLength(2));
    expect(state.activeId, state.browserTabs.last);
  });

  testWidgets('页面标题相同但文件不同：不合并', (tester) async {
    final harness = await pump(tester);

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/cat.html',
      wide: true,
      display: 'code-001/cat.html',
    );
    await tester.pump();

    final firstId = harness.container.read(filePaneTabProvider).activeId!;
    harness.container
        .read(browserSessionProvider(firstId).notifier)
        .syncTitle('小猫');

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/cat2.html',
      wide: true,
      display: 'code-001/cat2.html',
    );
    await tester.pump();

    expect(
      harness.container.read(filePaneTabProvider).browserTabs,
      hasLength(2),
      reason: '判重看的是页面身份，不是标题',
    );
  });

  testWidgets('没有展示地址时按预览路径兜底', (tester) async {
    final harness = await pump(tester);

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:5555/f/tok_a/project-1/cat.html',
      wide: true,
    );
    await tester.pump();

    // 同一个文件，换端口与令牌。
    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:6666/f/tok_b/project-1/cat.html',
      wide: true,
    );
    await tester.pump();

    expect(harness.container.read(filePaneTabProvider).browserTabs, hasLength(1));

    await openPreviewInPanel(
      harness.context,
      harness.ref,
      url: 'http://127.0.0.1:6666/f/tok_b/project-1/dog.html',
      wide: true,
    );
    await tester.pump();

    expect(harness.container.read(filePaneTabProvider).browserTabs, hasLength(2));
  });

  group('页面身份', () {
    test('预览站地址按去掉端口与令牌的路径判', () {
      expect(
        isSamePreviewPage(
          url: 'http://127.0.0.1:6666/f/tok_b/project-1/cat.html',
          display: 'code-001/cat.html',
          tabDisplay: 'code-001/cat.html',
          tabInternalUri: 'http://127.0.0.1:9999/f/tok_a/project-1/cat.html',
        ),
        isTrue,
      );
    });

    test('展示地址撞名但项目不同：不算同一页', () {
      expect(
        isSamePreviewPage(
          url: 'http://127.0.0.1:5555/f/tok/other-project/cat.html',
          display: 'code-001/cat.html',
          tabDisplay: 'code-001/cat.html',
          tabInternalUri: 'http://127.0.0.1:9999/f/tok/project-1/cat.html',
        ),
        isFalse,
        reason: '草稿里的同名文件不能互相顶掉',
      );
    });

    test('不是预览站地址时比展示地址', () {
      expect(
        isSamePreviewPage(
          url: 'http://localhost:3000/about',
          display: 'web-dev',
          tabDisplay: 'web-dev',
        ),
        isTrue,
      );
      expect(
        isSamePreviewPage(
          url: 'http://localhost:3000/about',
          display: null,
          tabDisplay: null,
        ),
        isFalse,
        reason: '认不出身份时宁可新开，也不要跳到别的页面',
      );
    });
  });
}
