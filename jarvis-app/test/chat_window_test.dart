import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/conversations_page.dart';
import 'package:jarvis_app/src/features/shell/chat_window_state.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

List<Project> _projects() => const <Project>[
  Project(
    id: 'w1',
    name: 'hello-demo',
    mode: ProjectModes.work,
    path: '/tmp/hello-demo',
    conversationCount: 1,
    taskCount: 0,
  ),
];

List<ConversationSummary> _conversations() => const <ConversationSummary>[
  ConversationSummary(id: 'conv-1', title: '聊聊周末', updatedAt: 0, projectId: 'w1'),
];

/// 记录"历史接口被调了几次"。
///
/// 这是本次改造最重要的一条断言：停靠 ⇄ 浮窗如果重建了会话页，就会重新拉
/// 一次历史，消息、滚动位置与正在流式的回答全部重来一遍。
class _ApiCounter {
  int history = 0;
}

Widget _harness(_ApiCounter counter) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      counter.history += 1;
      return _json(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'm1',
            'role': 'user',
            'content': '第一条消息',
            'created_at': 1790000000000,
          },
          <String, dynamic>{
            'id': 'm2',
            'role': 'assistant',
            'content': '第二条消息',
            'created_at': 1790000001000,
          },
        ],
      });
    }
    return _json(<String, dynamic>{
      'id': 'conv-1',
      'project_id': 'w1',
      'title': '聊聊周末',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
    });
  });

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
      projectsProvider.overrideWith((ref) => _projects()),
      conversationsProvider.overrideWith((ref, id) => _conversations()),
    ],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 打开一个已有历史的会话（宽屏下点击侧栏那一行）。
Future<void> _openChat(WidgetTester tester, _ApiCounter counter) async {
  await tester.pumpWidget(_harness(counter));
  await tester.pumpAndSettle();
  await tester.tap(find.text('聊聊周末'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 侧栏会话列表的两次读数：先占位标题，被 invalidate 之后才是自动标题。
///
/// 这不是刻意的怪癖——真实场景正是如此：打开会话时列表里还是「新会话」，
/// 服务端在首条提问后才把标题写进去。
class _AutoTitleFeed {
  int reads = 0;

  List<ConversationSummary> read(String projectId) {
    reads += 1;
    return <ConversationSummary>[
      ConversationSummary(
        id: 'conv-1',
        title: reads == 1 ? '新会话' : '现在几点了',
        updatedAt: 0,
        projectId: projectId,
      ),
    ];
  }
}

/// 详情接口回的是服务端自动生成后的标题。
Widget _autoTitleHarness(_AutoTitleFeed feed) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      return _json(<String, dynamic>{'items': <dynamic>[]});
    }
    return _json(<String, dynamic>{
      'id': 'conv-1',
      'project_id': 'w1',
      'title': '现在几点了',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
    });
  });

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
      projectsProvider.overrideWith((ref) => _projects()),
      conversationsProvider.overrideWith((ref, id) => feed.read(id)),
    ],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

/// 聊天窗口当前的矩形。动画结束之后再取，避免读到中间帧。
Rect _windowRect(WidgetTester tester) =>
    tester.getRect(find.byKey(kChatWindowKey));

/// 缩小为浮窗。
///
/// 浮窗按钮只在右栏打开时出现：右栏收起时中栏就是唯一的内容区，浮起来等于
/// 把它也丢掉。所以这里先确保右栏是开着的，再点栏头那枚按钮。
Future<void> _float(WidgetTester tester) async {
  if (find.byKey(kFilePaneToggleKey).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.tap(find.byKey(kChatFloatKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('停靠时聊天窗口正好铺满中栏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);

    final rect = _windowRect(tester);
    // 左栏 280 + 拖动条 8；右栏默认收起。
    expect(rect.left, kShellRailWidth + kRailHandleWidth);
    expect(rect.right, 1200);
    expect(rect.top, 0);
    expect(rect.height, 800);
    expect(find.text('第一条消息'), findsOneWidget);
    expect(counter.history, 1);
  });

  testWidgets('服务端自动生成的标题会刷掉侧栏里的「新会话」', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final feed = _AutoTitleFeed();
    await tester.pumpWidget(_autoTitleHarness(feed));
    await tester.pumpAndSettle();
    // 两处「新会话」：左栏顶部那颗新建按钮，与项目下这条会话的占位标题。
    // 会话行排在按钮之后，取 last 才不会点成"再开一个会话"。
    expect(find.text('新会话'), findsNWidgets(2), reason: '列表先给的是占位标题');

    await tester.tap(find.text('新会话').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(feed.reads, greaterThan(1), reason: '标题变了必须 invalidate 侧栏列表');
    expect(
      find.text('新会话'),
      findsOneWidget,
      reason: '会话行换成自动标题后只剩顶部那颗新建按钮，不能让用户继续点旧的',
    );
    expect(find.text('现在几点了'), findsWidgets);
  });

  testWidgets('缩小为浮窗后中栏让位，消息与请求次数都不变', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);

    await _float(tester);

    final rect = _windowRect(tester);
    expect(rect.width, kChatFloatWidth, reason: '浮窗用默认宽度，不再铺满中栏');
    expect(rect.height, kChatFloatHeight);
    // 默认落在右下角。
    expect(rect.right, 1200 - kChatFloatMargin);
    expect(rect.bottom, 800 - kChatFloatMargin);

    // 浮窗显示时中栏整列让位：会话已经浮在上面，中栏再留一份就是两个聊天。
    expect(
      find.byKey(const ValueKey<String>('project-w1')),
      findsNothing,
      reason: '中栏在浮窗期间不渲染',
    );

    // 关键：没有重新拉历史，消息还在。
    expect(counter.history, 1, reason: '缩放不该重建会话页');
    expect(find.text('第一条消息'), findsOneWidget);
  });

  testWidgets('拖动浮窗栏头会移动窗口，并且不会跑出视口', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    final before = _windowRect(tester);
    await tester.drag(
      find.byKey(kChatFloatHeaderDragKey),
      const Offset(-160, -120),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final after = _windowRect(tester);
    expect(after.left, closeTo(before.left - 160, 0.5));
    expect(after.top, closeTo(before.top - 120, 0.5));
    expect(after.size, before.size, reason: '拖动只改位置，不改尺寸');

    // 落点在手势结束时写回状态层，下次启动就是按它还原的。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );
    final state = container.read(chatWindowProvider);
    expect(state.origin, after.topLeft);
    expect(state.size, after.size);

    // 拖到左上角之外：位置被夹住，不会把窗口拖出视口。
    await tester.drag(
      find.byKey(kChatFloatHeaderDragKey),
      const Offset(-4000, -4000),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final clamped = _windowRect(tester);
    expect(clamped.left, greaterThanOrEqualTo(0));
    expect(clamped.top, greaterThanOrEqualTo(kPaneHeaderHeight));
  });

  testWidgets('点停靠回到中栏矩形，会话仍然是同一个', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);

    await _float(tester);
    expect(_windowRect(tester).width, kChatFloatWidth);

    await tester.tap(find.byKey(kChatDockKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rect = _windowRect(tester);
    // 浮窗期间右栏是开着的（浮窗按钮只在右栏打开时才有），停靠后中栏 =
    // 视口 - 左栏 - 右栏 - 两条拖动条。
    expect(
      rect.width,
      1200 -
          kShellRailWidth -
          kRailHandleWidth -
          kFilePaneWidth -
          kFilePaneHandleWidth,
    );
    expect(counter.history, 1, reason: '停靠也不该重建会话页');
    expect(find.text('第二条消息'), findsOneWidget);
  });

  testWidgets('关闭小窗只收浮窗，中栏仍是项目', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    await tester.tap(find.byKey(kChatFloatCloseKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(kChatWindowKey), findsNothing);
    expect(find.byKey(const ValueKey<String>('project-w1')), findsOneWidget);
  });

  testWidgets('右下角拖动可以改浮窗尺寸', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    final before = _windowRect(tester);
    await tester.drag(find.byKey(kChatFloatResizeKey), const Offset(80, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final after = _windowRect(tester);
    expect(after.width, closeTo(before.width + 80, 1));
    expect(after.height, closeTo(before.height + 60, 1));
    // 变宽变高之后仍必须完整落在视口里：默认落点贴着右下角，所以这一下
    // 会被 clamp 推回来，right / bottom 顶到视口边缘。
    expect(after.right, lessThanOrEqualTo(1200));
    expect(after.bottom, lessThanOrEqualTo(800));
    expect(after.left, greaterThanOrEqualTo(0));
  });

  testWidgets('悬停在可拉伸的边角上换成缩放光标', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    MouseCursor? cursorOf(Key key) => tester
        .widget<MouseRegion>(
          find.descendant(of: find.byKey(key), matching: find.byType(MouseRegion)),
        )
        .cursor;

    // 与桌面窗口边缘同一套形状：拖下边是上下箭头，拖左边是左右箭头。
    //
    // 右下角也是左右箭头：macOS 引擎没有斜向缩放光标（`FlutterMouseCursorPlugin`
    // 只映射 resizeColumn/row/up/down/left/right/upDown/leftRight），
    // 用 `resizeDownRight` 会被换成普通箭头，看起来像"悬停没反应"。
    expect(cursorOf(kChatFloatResizeBottomKey), SystemMouseCursors.resizeUpDown);
    expect(cursorOf(kChatFloatResizeLeftKey), SystemMouseCursors.resizeLeftRight);
    expect(cursorOf(kChatFloatResizeKey), SystemMouseCursors.resizeLeftRight);
  });

  testWidgets('圆角处的角点也能命中缩放热区', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    final rect = _windowRect(tester);

    // 距边 2dp 的点落在圆角弧线外侧：只要热区还在 `ClipRRect` 里面，
    // `RenderClipRRect.hitTest` 就会直接拒绝它——这正是"角上没光标"的原因。
    for (final entry in <String, Offset>{
      '左下角': Offset(rect.left + 2, rect.bottom - 2),
      '右下角': Offset(rect.right - 2, rect.bottom - 2),
      '下边': Offset(rect.center.dx, rect.bottom - 2),
      '左边': Offset(rect.left + 2, rect.center.dy),
    }.entries) {
      final hit = tester.hitTestOnBinding(entry.value);
      expect(
        hit.path.any((node) => node.target is RenderMouseRegion),
        isTrue,
        reason: '${entry.key} 应该命中缩放热区',
      );
    }
  });

  testWidgets('右侧栏全屏时聊天窗口让位，点工具条的「聊天浮窗」才叫出来', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 全屏 = 这一栏独占：聊天窗口只是藏起来（State 还在），不压在上面。
    expect(
      find.byKey(kChatWindowKey),
      findsNothing,
      reason: '全屏时不该自己把聊天浮窗摆出来',
    );

    // 「退出全屏」左边多了一枚「聊天浮窗」。
    expect(find.byKey(kChatFloatPeekKey), findsOneWidget);
    await tester.tap(find.byKey(kChatFloatPeekKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(kChatWindowKey), findsOneWidget);
    expect(_windowRect(tester).width, kChatFloatWidth);

    // 全屏里叫出来的浮窗同样能拖、能缩放：松手后不能弹回默认落点。
    // （曾经的 bug：拖完松手被 `resolveFloatRect` 的默认值覆盖回去。）
    final beforeDrag = _windowRect(tester);
    await tester.drag(
      find.byKey(kChatFloatHeaderDragKey),
      const Offset(-120, -80),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final afterDrag = _windowRect(tester);
    expect(afterDrag.left, closeTo(beforeDrag.left - 120, 0.5));
    expect(afterDrag.top, closeTo(beforeDrag.top - 80, 0.5));

    await tester.drag(find.byKey(kChatFloatResizeKey), const Offset(-60, -40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final afterResize = _windowRect(tester);
    expect(afterResize.width, closeTo(afterDrag.width - 60, 1));
    expect(afterResize.height, closeTo(afterDrag.height - 40, 1));

    // 再点一次收回去。
    await tester.tap(find.byKey(kChatFloatPeekKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(kChatWindowKey), findsNothing);

    // 退出全屏：聊天回到中栏原样，且没有重新拉历史。
    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 退出全屏后面板还开着，中栏 = 视口 - 左栏 - 右栏 - 两条拖动条。
    expect(
      _windowRect(tester).width,
      1200 -
          kShellRailWidth -
          kRailHandleWidth -
          kFilePaneWidth -
          kFilePaneHandleWidth,
      reason: '退出全屏后回到停靠形态',
    );
    expect(counter.history, 1, reason: '全屏来回不该重建会话页');
  });

  testWidgets('浮窗形态的「…」菜单里不再出现「缩小为浮窗」', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());

    // 停靠态有这一项。
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('缩小为浮窗'), findsOneWidget);

    // 关掉菜单再缩小。
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pump();
    await _float(tester);

    await tester.tap(find.byTooltip('会话操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('缩小为浮窗'),
      findsNothing,
      reason: '已经是浮窗了，再给一次「缩小」只会让人困惑',
    );
  });

  testWidgets('窄屏把浮窗铺满整窗，拉宽后又回到小窗尺寸', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);
    await _float(tester);

    await _setSurface(tester, const Size(640, 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final narrow = _windowRect(tester);
    expect(narrow.width, 640);
    expect(narrow.height, 900);
    expect(counter.history, 1, reason: '跨断点也不该重建会话页');
    // 窄屏没有浮窗形态：铺满时页头是整页那一套（返回 + 标题 + 更多），
    // 「停靠回中栏」「关闭小窗」这类只在小窗里有意义的按钮不再出现。
    expect(find.byKey(kChatDockKey), findsNothing);
    expect(find.byKey(kChatFloatCloseKey), findsNothing);
    expect(find.byTooltip('返回'), findsOneWidget);
    // 整页形态必须自己有一层不透明底色：透明 Scaffold 会让下层的
    // 项目列表与底部导航透上来，看着像两个页面叠在一起。
    expect(
      find.descendant(
        of: find.byKey(kChatWindowKey),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient is LinearGradient,
        ),
      ),
      findsWidgets,
      reason: '窄屏铺满时要自铺整窗渐变，不能透出下层标签页',
    );

    await _setSurface(tester, const Size(1200, 800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final wide = _windowRect(tester);
    expect(wide.width, kChatFloatWidth);
    expect(counter.history, 1);
  });

  testWidgets('窄屏整页形态点返回：收起会话，拉宽也不再回到小窗', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());
    await _float(tester);

    await _setSurface(tester, const Size(640, 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 浮窗层不在路由栈里，返回箭头由外壳接：收起会话并回到项目。
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(kChatWindowKey), findsNothing);

    await _setSurface(tester, const Size(1200, 800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(kChatWindowKey),
      findsNothing,
      reason: '返回是收起会话，不是缩成小窗',
    );
  });

  testWidgets('右栏收起时不提供「缩小为浮窗」，打开右栏才有', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());

    // 右栏收起：中栏就是唯一的内容区，缩成浮窗等于把整块窗口清空。
    expect(find.byKey(kChatFloatKey), findsNothing);

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(kChatFloatKey), findsOneWidget);
  });

  testWidgets('浮窗里输入栏收成一行；停靠后恢复', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await _openChat(tester, _ApiCounter());

    // 停靠态：两行高的输入栏。
    expect(
      tester.getRect(find.byKey(kChatComposerPanelKey)).height,
      closeTo(kChatComposerMinHeight, 2),
    );

    await _float(tester);

    // 浮窗是小窗：输入栏收成一行，把高度让给消息区。
    expect(
      tester.getRect(find.byKey(kChatComposerPanelKey)).height,
      lessThan(kChatComposerMinHeight - 8),
      reason: '一行高要明显低于两行的默认高度',
    );

    await tester.tap(find.byKey(kChatDockKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.getRect(find.byKey(kChatComposerPanelKey)).height,
      closeTo(kChatComposerMinHeight, 2),
      reason: '停靠回来输入栏恢复两行',
    );
  });

  testWidgets('浮窗期间收起右栏：浮窗强制停靠回中栏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    final counter = _ApiCounter();
    await _openChat(tester, counter);
    await _float(tester);

    expect(find.byKey(kChatWindowKey), findsOneWidget);

    // 面板工具条里的「隐藏右侧栏」。
    await tester.tap(find.byKey(kFilePaneHideKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 右栏没了，浮窗就没有理由留着：会话停靠回中栏，宽度恢复成整条。
    expect(
      _windowRect(tester).width,
      1200 - kShellRailWidth - kRailHandleWidth,
      reason: '浮窗要停靠回中栏，而不是留在小窗形态',
    );
    expect(find.text('第一条消息'), findsOneWidget);
    expect(counter.history, 1, reason: '停靠回来不该重建会话页');
  });
}
