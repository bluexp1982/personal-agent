import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/compaction_dialog.dart';

CompactionView _ready({
  String summary = '- 用户在做一个 Rust 项目',
  int updatedAtMs = 1762754580000,
  CompactionFailureView? failure,
}) {
  return CompactionView(
    status: 'ready',
    summary: summary,
    anchorMessageId: 'msg_anchor',
    sourceMessages: 12,
    model: 'deepseek-v4.1-flash',
    updatedAt: updatedAtMs,
    promptTokens: 900,
    completionTokens: 120,
    lastFailure: failure,
  );
}

/// 入口按钮 + `Builder`：弹窗必须由 `showAppDialog` 打开，
/// 这样测到的才是真实的遮罩、居中与关闭路径，而不是直接挂一个子组件。
Widget _harness({
  required CompactionView view,
  Future<CompactionView?> Function()? onRegenerate,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCompactionDialog(
              context,
              view: view,
              onRegenerate: onRegenerate,
            ),
            child: const Text('打开摘要'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开摘要'));
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester, String label) {
  final button = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, label),
  );
  return button.onPressed != null;
}

void main() {
  testWidgets('是居中弹窗而不是底部抽屉，标题行自带关闭钮', (tester) async {
    await tester.pumpWidget(_harness(view: _ready()));
    await _open(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing, reason: '不再用底部抽屉');
    expect(find.text('上下文摘要'), findsOneWidget);
    // 元信息走说明行：条数 · 模型 · 时间 · token。
    expect(find.textContaining('更早 12 条'), findsOneWidget);
    expect(find.textContaining('deepseek-v4.1-flash'), findsOneWidget);
    expect(find.textContaining('1020 tokens'), findsOneWidget);

    // 关闭钮由 AppDialog 提供，落在标题行右端。
    final close = find.byTooltip('关闭');
    expect(close, findsOneWidget);
    expect(
      tester.getCenter(close).dx,
      greaterThan(tester.getCenter(find.text('上下文摘要')).dx),
    );
  });

  testWidgets('有摘要时渲染正文，且不出现失败横幅', (tester) async {
    await tester.pumpWidget(_harness(view: _ready()));
    await _open(tester);

    expect(find.textContaining('Rust 项目'), findsOneWidget);
    expect(find.textContaining('上次整理失败'), findsNothing);
  });

  testWidgets('有失败记录时单独一行，成功摘要照常显示', (tester) async {
    await tester.pumpWidget(
      _harness(
        view: _ready(
          failure: const CompactionFailureView(error: '上游报错：500', at: 0),
        ),
      ),
    );
    await _open(tester);

    expect(find.textContaining('上次整理失败：上游报错：500'), findsOneWidget);
    expect(find.textContaining('Rust 项目'), findsOneWidget);
  });

  testWidgets('点重新整理：弹窗不关、按钮变「整理中…」且禁用', (tester) async {
    final pending = Completer<CompactionView?>();
    await tester.pumpWidget(
      _harness(view: _ready(), onRegenerate: () => pending.future),
    );
    await _open(tester);

    await tester.tap(find.text('重新整理'));
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget, reason: '整理期间弹窗要留在原地');
    expect(find.text('整理中…'), findsOneWidget);
    expect(find.text('重新整理'), findsNothing);
    expect(_enabled(tester, '整理中…'), isFalse, reason: '进行中不能再点');
    // 界面上不该有"关闭压缩"：关了之后服务端不再下发状态，入口会一起消失。
    expect(find.text('关闭压缩'), findsNothing);

    // 收尾：交回一份新摘要，界面换成新内容、按钮恢复。
    pending.complete(
      _ready(summary: '- 第二版摘要：项目改用 SQLite 存状态', updatedAtMs: 1762754640000),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('第二版摘要'), findsOneWidget);
    expect(find.text('整理中…'), findsNothing);
    expect(find.text('重新整理'), findsOneWidget);
    expect(_enabled(tester, '重新整理'), isTrue);
  });

  testWidgets('整理失败：保留旧摘要，只多一条失败原因', (tester) async {
    final pending = Completer<CompactionView?>();
    await tester.pumpWidget(
      _harness(view: _ready(), onRegenerate: () => pending.future),
    );
    await _open(tester);

    await tester.tap(find.text('重新整理'));
    await tester.pump();
    pending.complete(
      _ready(failure: const CompactionFailureView(error: '模型没有返回摘要内容', at: 1)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Rust 项目'), findsOneWidget, reason: '旧摘要不能被清掉');
    expect(find.textContaining('上次整理失败：模型没有返回摘要内容'), findsOneWidget);
  });

  testWidgets('没有摘要时说明清楚，而不是留一片空白', (tester) async {
    await tester.pumpWidget(
      _harness(
        view: const CompactionView(
          status: 'failed',
          lastFailure: CompactionFailureView(error: '模型没有返回摘要内容', at: 0),
        ),
        onRegenerate: () async => null,
      ),
    );
    await _open(tester);

    expect(find.text('这个会话还没有可用的摘要。'), findsOneWidget);
    expect(find.textContaining('上次整理失败：模型没有返回摘要内容'), findsOneWidget);
  });
}
