import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/features/shell/selection_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

const ApiException _conflict = ApiException(
  code: 'conflict',
  message: 'conversation conflict: 会话下还有未结束的任务',
  retryable: false,
  hint: '会话下还有未结束的任务，请先取消或等它结束再删会话',
  statusCode: 409,
);

void main() {
  group('deleteSelected', () {
    test('全部成功时按 ids 返回，无失败原因', () async {
      final seen = <String>[];
      final outcome = await deleteSelected(
        ids: <String>['a', 'b', 'c'],
        deleteOne: (id) async => seen.add(id),
      );

      expect(outcome.deletedCount, 3);
      expect(outcome.hasFailures, isFalse);
      expect(outcome.firstError, isNull);
      expect(seen.toSet(), <String>{'a', 'b', 'c'});
    });

    test('单条失败不影响其余，并保留首个用户可读原因', () async {
      final outcome = await deleteSelected(
        ids: <String>['a', 'b', 'c'],
        deleteOne: (id) async {
          if (id == 'b') {
            throw _conflict;
          }
        },
      );

      expect(outcome.deleted.toSet(), <String>{'a', 'c'});
      expect(outcome.failed, <String>['b']);
      expect(outcome.firstError, _conflict.userMessage);
    });

    test('并发不超过上限', () async {
      var active = 0;
      var peak = 0;

      await deleteSelected(
        ids: List<String>.generate(12, (index) => 'id$index'),
        concurrency: 3,
        deleteOne: (id) async {
          active += 1;
          if (active > peak) {
            peak = active;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active -= 1;
        },
      );

      expect(peak, lessThanOrEqualTo(3));
    });
  });

  test('deleteSummary 覆盖全成 / 部分失败 / 全败', () {
    expect(
      deleteSummary(
        '会话',
        const DeleteOutcome(deleted: <String>['a'], failed: <String>[]),
      ),
      '已删除 1 个会话',
    );

    expect(
      deleteSummary(
        '任务',
        const DeleteOutcome(
          deleted: <String>['a'],
          failed: <String>['b'],
          firstError: '任务还没结束',
        ),
      ),
      '已删除 1 个任务，1 个失败：任务还没结束',
    );

    expect(
      deleteSummary(
        '任务',
        const DeleteOutcome(
          deleted: <String>[],
          failed: <String>['b'],
          firstError: '任务还没结束',
        ),
      ),
      '删除失败：任务还没结束',
    );
  });

  testWidgets('删除条展示数量，未选中时按钮禁用', (tester) async {
    await tester.pumpWidget(
      _wrap(SelectionDeleteBar(selectedCount: 0, busy: false, onDelete: () {})),
    );

    expect(find.text('已选 0 项'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('删除条在有选中且非提交中时可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SelectionDeleteBar(
          selectedCount: 2,
          busy: false,
          onDelete: () => taps++,
        ),
      ),
    );

    await tester.tap(find.text('删除'));
    expect(taps, 1);
  });

  testWidgets('提交中显示进度且按钮禁用', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SelectionDeleteBar(
          selectedCount: 2,
          busy: true,
          onDelete: () => taps++,
        ),
      ),
    );

    expect(find.text('删除中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(taps, 0);
  });

  testWidgets('全选按钮随选中数量切换文案', (tester) async {
    var toggles = 0;
    var done = 0;

    Widget build(int selected) => _wrap(
      SelectionAppBarActions(
        selectedCount: selected,
        selectableCount: 3,
        onToggleAll: () => toggles++,
        onDone: () => done++,
      ),
    );

    await tester.pumpWidget(build(1));
    expect(find.text('全选'), findsOneWidget);

    await tester.tap(find.text('全选'));
    expect(toggles, 1);

    await tester.pumpWidget(build(3));
    expect(find.text('取消全选'), findsOneWidget);

    await tester.tap(find.text('完成'));
    expect(done, 1);
  });

  testWidgets('没有可删项时全选禁用', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SelectionAppBarActions(
          selectedCount: 0,
          selectableCount: 0,
          onToggleAll: () {},
          onDone: () {},
        ),
      ),
    );

    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '全选'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('确认弹窗返回用户选择', (tester) async {
    bool? confirmed;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  confirmed = await confirmDeleteDialog(
                    context,
                    title: '删除 2 个会话？',
                    message: '消息会一并删除，无法恢复。',
                    count: 2,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('删除 2 个会话？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 2 项'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
