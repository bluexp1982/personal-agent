import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/features/shell/rail_view_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 单独摆一枚按钮：这里只验浮层本身（分组、勾选、宽度），
/// 侧栏里的位置与顺序由 `home_shell_test.dart` 覆盖。
Widget _harness() {
  return const MaterialApp(
    home: Scaffold(body: Center(child: RailViewOptionsButton())),
  );
}

Finder _row(String id) => find.byKey(Key('rail-view-item-$id'));

Finder _checkIn(String id) =>
    find.descendant(of: _row(id), matching: find.byIcon(Icons.check_rounded));

void main() {
  testWidgets('视图选项浮层：三组八项，每组默认勾一个', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();

    for (final title in <String>['分组方式', '排序方式', '筛选会话']) {
      expect(find.text(title), findsOneWidget);
    }
    for (final label in <String>[
      '按项目',
      '按项目树',
      '单列表',
      '手动排序',
      '最近更新',
      '隐藏已归档',
      '全部对话（显示已归档）',
      '仅显示已归档',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    expect(_checkIn('project'), findsOneWidget);
    expect(_checkIn('recent'), findsOneWidget);
    expect(_checkIn('hide-archived'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));

    expect(tester.takeException(), isNull);
  });

  testWidgets('条目宽度按面板宽度兜底，长文案不撑破浮层', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();

    // 面板左右各 6dp 内边距：条目（含自己的 8dp 内边距）正好吃满 232 − 12。
    final width = kRailViewMenuWidth - 12;
    for (final id in <String>['project', 'recent', 'archived-only']) {
      expect(
        tester.getSize(_row(id)).width,
        width,
        reason: '「$id」一行必须按面板宽度兜底（外层 IntrinsicWidth 会绕过 minimumSize）',
      );
    }
    expect(
      tester.getSize(_row('project')).height,
      AgentMenuStyle.optionRowHeight,
      reason: '条目高 34，与输入栏的勾选行同一套行令牌',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击只切换勾选，关掉再打开仍记得', (tester) async {
    await tester.pumpWidget(_harness());

    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();
    await tester.tap(_row('single-list'));
    await tester.pumpAndSettle();
    expect(_row('single-list'), findsNothing, reason: '选中后菜单收起');

    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();
    expect(_checkIn('single-list'), findsOneWidget);
    expect(_checkIn('project'), findsNothing);
    // 另外两组不受影响。
    expect(_checkIn('recent'), findsOneWidget);
    expect(_checkIn('hide-archived'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));

    // 每组之间只互斥组内选项：换排序不影响分组与筛选。
    await tester.tap(_row('manual'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();
    expect(_checkIn('manual'), findsOneWidget);
    expect(_checkIn('recent'), findsNothing);
    expect(_checkIn('single-list'), findsOneWidget);
    expect(_checkIn('hide-archived'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('浮层从触发器左侧展开：面板左边缘压在触发器左边缘上', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final trigger = tester.getRect(find.byKey(kRailViewOptionsKey));
    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();

    // 面板自身有 6dp 内边距，条目比面板边缘内缩这么多。
    expect(
      tester.getRect(_row('project')).left,
      closeTo(trigger.left + AgentMenuStyle.panelPadding, 2),
      reason: '与输入栏「+」菜单一致：面板左边缘对齐触发器左边缘，'
          '而不是整块长在触发器右侧',
    );
  });
}
