import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/compaction_bar.dart';
import 'package:jarvis_app/src/features/conversations/composer_context_ring.dart';

CompactionView _ready({
  String summary = '- 用户在做一个 Rust 项目',
  int sourceMessages = 12,
}) {
  return CompactionView(
    status: 'ready',
    summary: summary,
    anchorMessageId: 'msg_anchor',
    sourceMessages: sourceMessages,
    model: 'deepseek-v4.1-flash',
    updatedAt: DateTime(2026, 11, 10, 14, 3).millisecondsSinceEpoch,
    promptTokens: 900,
    completionTokens: 120,
  );
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('CompactionView 解析', () {
    test('整段缺失或没有 status 都当"没有压缩"', () {
      expect(CompactionView.tryParse(null), isNull);
      expect(CompactionView.tryParse('ready'), isNull);
      expect(CompactionView.tryParse(<String, dynamic>{}), isNull);
    });

    test('完整字段按契约映射，tokens 与失败记录各归各位', () {
      final view = CompactionView.tryParse(<String, dynamic>{
        'status': 'ready',
        'summary': '- 摘要',
        'anchor_message_id': 'msg_7',
        'source_messages': 6,
        'model': 'fake',
        'updated_at': 1762754580000,
        'tokens': <String, dynamic>{
          'prompt_tokens': 120,
          'completion_tokens': 30,
          'tokens_estimated': true,
        },
        'elapsed_ms': 800,
        'last_failure': <String, dynamic>{
          'error': '上游报错：500',
          'at': 1762754000000,
          'model': 'fake',
        },
      });

      expect(view, isNotNull);
      expect(view!.hasSummary, isTrue);
      expect(view.sourceMessages, 6);
      expect(view.anchorMessageId, 'msg_7');
      expect(view.totalTokens, 150);
      expect(view.tokensEstimated, isTrue);
      expect(view.hasFailure, isTrue);
      expect(view.lastFailure!.error, '上游报错：500');
    });

    test('只有失败记录时不算有摘要', () {
      final view = CompactionView.tryParse(<String, dynamic>{
        'status': 'failed',
        'last_failure': <String, dynamic>{'error': '摘要为空', 'at': 1},
      });
      expect(view, isNotNull);
      expect(view!.hasSummary, isFalse);
      expect(view.isPending, isFalse);
      expect(view.hasFailure, isTrue);
    });
  });

  group('横条文案', () {
    test('三种状态各说各的', () {
      expect(compactionBarLabel(_ready()), '更早 12 条对话已整理为摘要');
      expect(
        compactionBarLabel(const CompactionView(status: 'pending')),
        '正在整理更早的对话…',
      );
      expect(
        compactionBarLabel(
          const CompactionView(
            status: 'failed',
            lastFailure: CompactionFailureView(error: '超时', at: 1),
          ),
        ),
        '更早的对话整理失败',
      );
    });
  });

  testWidgets('横条可点击，"查看"是明确的入口', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(CompactionBar(view: _ready(), onOpen: () => opened++)),
    );
    await tester.pumpAndSettle();

    expect(find.text('更早 12 条对话已整理为摘要'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('失败但没有摘要时横条带告警图标', (tester) async {
    await tester.pumpWidget(
      _host(
        CompactionBar(
          view: const CompactionView(
            status: 'failed',
            lastFailure: CompactionFailureView(error: '超时', at: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('更早的对话整理失败'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  group('上下文环提示', () {
    test('有压缩时补一句"更早 N 条已压缩"', () {
      expect(
        formatContextTooltip(
          contextTokens: 168000,
          contextWindow: 1000000,
          compactedMessages: 12,
        ),
        '16.8% · 168.0K / 1000.0K 上下文已使用；更早 12 条已压缩',
      );
    });

    test('没有压缩时提示与原来逐字一致', () {
      expect(
        formatContextTooltip(contextTokens: 168000, contextWindow: 1000000),
        '16.8% · 168.0K / 1000.0K 上下文已使用',
      );
    });

    test('可点开摘要时在末尾再补一句，且排在"已压缩"之后', () {
      expect(
        formatContextTooltip(
          contextTokens: 168000,
          contextWindow: 1000000,
          compactedMessages: 14,
          canOpenSummary: true,
        ),
        '16.8% · 168.0K / 1000.0K 上下文已使用；更早 14 条已压缩；点击查看摘要',
      );
    });
  });
}
