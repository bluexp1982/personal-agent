import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/tasks/task_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 任务详情内嵌时的栏头动作，规格必须和左栏 / 中栏 / 右栏栏头一致：
// 命中区 24、图标 14。曾经只用 `shellIconButtonShape()` 补了圆角、
// 没动尺寸，于是这一枚顶着 Material 默认的 48 命中区，在 40 高的栏头行里
// 比旁边的按钮大一圈，上下还会溢出。

/// 接口一律失败：本用例只关心栏头按钮的尺寸，不关心任务内容。
/// 失败路径同样会把栏头渲染出来（动作按钮在 `task == null` 分支之外）。
http.Client _failingClient() => MockClient(
  (http.Request request) async =>
      http.Response('{"error":"boom"}', 500),
);

Widget _harness() {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: _failingClient(),
        ),
      ),
    ],
    child: const MaterialApp(
      home: TaskDetailPage(taskId: 'task-1', embedded: true),
    ),
  );
}

void main() {
  testWidgets('内嵌任务详情的刷新按钮走栏头规格', (tester) async {
    await tester.pumpWidget(_harness());
    // 不用 pumpAndSettle：这一页有 1.5s 的轮询定时器，永远 settle 不下来。
    await tester.pump();

    final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
    expect(refresh, findsOneWidget);

    final button = tester.widget<IconButton>(refresh);
    expect(
      button.style?.minimumSize?.resolve(<WidgetState>{}),
      const Size.square(kPaneHeaderButtonSize),
      reason: '命中区要和栏头其它图标一致，不能是 Material 默认的 48',
    );
    expect(button.iconSize, kPaneHeaderIconSize, reason: '图标也要收到栏头那一档');
    expect(
      tester.getSize(refresh),
      const Size.square(kPaneHeaderButtonSize),
      reason: '实际占位同样是 24，不能撑破 40 高的栏头行',
    );

    // 卸掉整棵树：把 1.5s 轮询定时器一起收走，否则测试结束会报"还有定时器在跑"。
    await tester.pumpWidget(const SizedBox());
  });
}
