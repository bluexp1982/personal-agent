import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer_area.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/composer_context_ring.dart';
import 'package:jarvis_app/src/features/conversations/new_session_stage.dart';
import 'package:jarvis_app/src/features/shell/pane_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Map<String, String> _headers = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

/// 假服务端：只回会话详情与历史，够首屏把 `_loading` 落下来。
///
/// [presentation] 直接指定形态；不给时按 [embedded] 退回原来的 page / docked。
Widget _harness({
  int messageCount = 0,
  bool embedded = false,
  ChatPresentation? presentation,
}) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      final items = List<Map<String, dynamic>>.generate(
        messageCount,
        (index) => <String, dynamic>{
          'id': 'm$index',
          'role': index.isEven ? 'user' : 'assistant',
          'content': '第 $index 条',
          'created_at': index,
          // 上下文环只在有真实用量时出现：没有这份 usage，
          // "有消息"与"空会话"在界面上就没有区别了。
          if (index.isOdd)
            'usage': <String, dynamic>{
              'prompt_tokens': 17000,
              'completion_tokens': 500,
              'tokens_estimated': false,
              'context_tokens': 16800,
            },
        },
      );
      return http.Response(
        jsonEncode(<String, dynamic>{'items': items}),
        200,
        headers: _headers,
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{
        'id': 'c1',
        'project_id': 'w1',
        'title': '新会话',
        'mode': 'text',
        'archived': false,
        'created_at': 0,
        'updated_at': 0,
      }),
      200,
      headers: _headers,
    );
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
    ],
    child: MaterialApp(
      home: ChatPage(
        conversationId: 'c1',
        title: '新会话',
        presentation:
            presentation ??
            (embedded ? ChatPresentation.docked : ChatPresentation.page),
      ),
    ),
  );
}

/// 等首屏两个请求落地。
///
/// 不用 `pumpAndSettle`：有历史时列表到底还有一段 180ms 的滚动动画，
/// 这里直接把它跑完，用例结束时不留进行中的动画。
Future<void> _open(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 舞台的三条硬指标：输入栏水平居中、垂直落在**整窗**中线上，品牌行在它上方 24。
void _expectCenteredStage(WidgetTester tester, {required String reason}) {
  final brand = tester.getRect(find.text('探索未来'));
  final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
  final scaffold = tester.getRect(find.byType(Scaffold));

  expect(panel.center.dy, closeTo(scaffold.center.dy, 4), reason: reason);
  expect(panel.center.dx, closeTo(scaffold.center.dx, 1), reason: '输入栏要水平居中');
  // 品牌行与输入栏之间只剩一条固定间距：空态不再显示「当前模型」行。
  expect(
    brand.bottom,
    closeTo(panel.top - NewSessionStage.brandGap, 2),
    reason: '品牌行 → 输入栏的间距固定',
  );
}

void main() {
  testWidgets('空会话：输入栏本身落在整窗中央，品牌行在它上方', (tester) async {
    await _open(tester, _harness());

    expect(find.text('探索未来'), findsOneWidget);
    expect(
      find.textContaining('当前模型'),
      findsNothing,
      reason: '品牌行下面不再显示模型文案，模型名只出现在输入栏胶囊里',
    );
    expect(
      find.byType(ContextUsageRing),
      findsNothing,
      reason: '新会话还没有上下文用量：环连位置都不占',
    );
    expect(
      find.text('问点什么吧。这里只回答，不会自动替你办事。'),
      findsNothing,
      reason: '整页空会话换成品牌行 + 居中输入栏，不再叠一句提示',
    );

    // 居中的是输入栏本身：面板中点落在整窗中线上，品牌行叠在它上方 24。
    // 「品牌行 + 间距 + 输入栏」整块居中会让输入栏落到中线以下，这里不放宽到那个程度。
    _expectCenteredStage(tester, reason: '整页空会话的输入栏要水平垂直居中');

    // 空输入时面板就是两行的高度：一行太像单行表单，写一句话就顶到内部滚动。
    expect(
      tester.getRect(find.byKey(kChatComposerPanelKey)).height,
      closeTo(kChatComposerMinHeight, 2),
      reason: '输入栏默认两行高',
    );
  });

  testWidgets('有消息：输入栏贴底，品牌行不出现', (tester) async {
    await _open(tester, _harness(messageCount: 2));

    expect(find.text('探索未来'), findsNothing);
    expect(
      find.byType(ContextUsageRing),
      findsOneWidget,
      reason: '上下文环跟着输入栏一起出现',
    );

    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    final scaffold = tester.getRect(find.byType(Scaffold));
    expect(
      scaffold.bottom - panel.bottom,
      lessThan(60),
      reason: '有内容时输入栏应该贴着窗口底部',
    );
  });

  testWidgets('内嵌空会话同样居中：品牌行在上，无旧提示', (tester) async {
    await _open(tester, _harness(embedded: true));

    expect(find.text('探索未来'), findsOneWidget);
    expect(find.text('问点什么吧。这里只回答，不会自动替你办事。'), findsNothing);

    _expectCenteredStage(
      tester,
      reason: '桌面宽屏只走内嵌形态，这里不生效等于新样式看不到',
    );
  });

  testWidgets('内嵌有消息：仍贴底', (tester) async {
    await _open(tester, _harness(messageCount: 2, embedded: true));

    expect(find.text('探索未来'), findsNothing);
    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    expect(
      tester.getRect(find.byType(Scaffold)).bottom - panel.bottom,
      lessThan(60),
      reason: '有内容时输入栏应该贴着窗口底部',
    );
  });

  testWidgets('内嵌：中栏与左右两栏同一层半透明栏底', (tester) async {
    await _open(tester, _harness(embedded: true));

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(
      scaffold.backgroundColor?.a,
      closeTo(kPaneSurfaceAlpha, 0.001),
      reason: '实色中栏会把骨架的模式渐变全挡住，看着比左右两栏白一档',
    );
  });

  testWidgets('整页形态：自铺整窗渐变，Scaffold 保持透明', (tester) async {
    await _open(tester, _harness());

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(
      scaffold.backgroundColor,
      Colors.transparent,
      reason: '窄屏是压在骨架之上的整页路由，实底会把整窗渐变盖住',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is LinearGradient,
      ),
      findsOneWidget,
      reason: '整页形态自己要垫一层不透明渐变，转场时才不会透出下层列表',
    );
  });

  testWidgets('浮窗空会话：没有开场舞台，输入栏直接贴底', (tester) async {
    // 按真实小窗尺寸渲染：默认 800 宽会让 `kChatColumnMaxWidth` 生效，
    // 面板被居中限宽，看不到 12 的左右边距。
    await tester.binding.setSurfaceSize(const Size(420, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _open(tester, _harness(presentation: ChatPresentation.floating));

    expect(find.text('探索未来'), findsNothing, reason: '小窗只保留贴底输入栏');
    expect(find.textContaining('当前模型'), findsNothing, reason: '模型文案已从品牌区下线');

    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    final scaffold = tester.getRect(find.byType(Scaffold));

    expect(
      scaffold.bottom - panel.bottom,
      closeTo(ChatComposerArea.floatingPadding.bottom, 1),
      reason: '空会话的输入栏也要贴着窗口底部，不能居中',
    );
    expect(
      panel.left - scaffold.left,
      closeTo(ChatComposerArea.floatingPadding.left, 1),
      reason: '左右与下同宽：面板到窗口三边等距',
    );
    expect(
      scaffold.right - panel.right,
      closeTo(ChatComposerArea.floatingPadding.right, 1),
    );
  });

  testWidgets('浮窗有消息：输入栏贴底，消息列表的左右边距同步收到 12', (tester) async {
    await _open(
      tester,
      _harness(messageCount: 2, presentation: ChatPresentation.floating),
    );

    expect(find.text('探索未来'), findsNothing);

    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    final scaffold = tester.getRect(find.byType(Scaffold));
    expect(
      scaffold.bottom - panel.bottom,
      closeTo(ChatComposerArea.floatingPadding.bottom, 1),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    final padding = list.padding! as EdgeInsets;
    expect(
      padding.left,
      ChatComposerArea.floatingPadding.left,
      reason: '气泡与输入栏同一条竖线，差 4dp 能看出两条边',
    );
    expect(padding.right, ChatComposerArea.floatingPadding.right);
  });
}
