import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Key _panelKey = Key('agent-menu-panel-test');
const Key _copyKey = Key('agent-menu-panel-test-copy');
const Key _pasteKey = Key('agent-menu-panel-test-paste');
const Key _deleteKey = Key('agent-menu-panel-test-delete');

/// 面板没有触发器，直接摆在一屏中间即可：它只描述"长什么样、点了回什么值"。
Widget _harness({
  required ValueChanged<String> onSelected,
  List<AgentMenuItem<String>>? items,
  List<AgentMenuGroup<String>>? groups,
  double maxHeight = AgentMenuStyle.panelMaxHeight,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: AgentMenuPanel<String>(
          key: _panelKey,
          width: AgentMenuStyle.panelMinWidth,
          maxHeight: maxHeight,
          groups:
              groups ??
              <AgentMenuGroup<String>>[
                AgentMenuGroup<String>(items: items ?? _items()),
              ],
          onSelected: onSelected,
        ),
      ),
    ),
  );
}

List<AgentMenuItem<String>> _items({bool disabledDelete = false}) {
  return <AgentMenuItem<String>>[
    const AgentMenuItem<String>(
      key: _copyKey,
      value: 'copy',
      label: '复制',
      icon: Icons.content_copy_rounded,
    ),
    const AgentMenuItem<String>(
      key: _pasteKey,
      value: 'paste',
      label: '粘贴',
      icon: Icons.content_paste_rounded,
      dividerBefore: true,
    ),
    AgentMenuItem<String>(
      key: _deleteKey,
      value: 'delete',
      label: '删除',
      icon: Icons.delete_outline_rounded,
      enabled: !disabledDelete,
    ),
  ];
}

void main() {
  testWidgets('面板与条目宽度沿用 AgentMenu 的口径，选中后回传值', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_harness(onSelected: picked.add));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(_panelKey)).width,
      AgentMenuStyle.panelMinWidth,
      reason: '面板是定宽：不能跟着最长的文案伸缩',
    );
    expect(
      tester.getSize(find.byKey(_copyKey)).width,
      closeTo(AgentMenuStyle.itemMinWidth, 0.5),
      reason: '条目要撑到 itemMinWidth，短文案才不会被挤窄',
    );

    await tester.tap(find.byKey(_pasteKey));
    await tester.pumpAndSettle();

    expect(picked, <String>['paste']);
  });

  testWidgets('禁用项不可点，也不会回调', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _harness(onSelected: picked.add, items: _items(disabledDelete: true)),
    );
    await tester.pumpAndSettle();

    final delete = tester.widget<MenuItemButton>(find.byKey(_deleteKey));
    expect(delete.onPressed, isNull, reason: '禁用态就是 onPressed 为 null');

    await tester.tap(find.byKey(_deleteKey));
    await tester.pumpAndSettle();

    expect(picked, isEmpty);
  });

  testWidgets('分组线与分组标题由 groups 决定，第一项上的标记被忽略', (tester) async {
    await tester.pumpWidget(
      _harness(
        onSelected: (_) {},
        groups: <AgentMenuGroup<String>>[
          AgentMenuGroup<String>(
            title: '第一组',
            items: <AgentMenuItem<String>>[
              const AgentMenuItem<String>(
                value: 'a',
                label: '甲',
                dividerBefore: true,
              ),
            ],
          ),
          AgentMenuGroup<String>(
            title: '第二组',
            dividerBefore: true,
            items: <AgentMenuItem<String>>[
              const AgentMenuItem<String>(value: 'b', label: '乙'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一组'), findsOneWidget);
    expect(find.text('第二组'), findsOneWidget);
    expect(
      find.byType(AgentMenuDivider),
      findsOneWidget,
      reason: '两组之间一条线；第一组之前不画',
    );
  });

  testWidgets('内容超过最大高度时面板被限高并可滚动', (tester) async {
    await tester.pumpWidget(
      _harness(
        onSelected: (_) {},
        maxHeight: 120,
        items: <AgentMenuItem<String>>[
          for (var i = 0; i < 20; i++)
            AgentMenuItem<String>(value: 'item-$i', label: '第 $i 项'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(_panelKey)).height,
      closeTo(120, 0.5),
      reason: '超出最大高度就停在上限，不再往下长',
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    final before = tester.getTopLeft(find.text('第 0 项')).dy;
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('第 0 项')).dy,
      lessThan(before),
      reason: '面板内部要真的能滚，而不是把内容裁掉了事',
    );
  });

  testWidgets('面板表面与 AgentMenu 同源：材质阴影、圆角与描边都来自面板样式', (tester) async {
    await tester.pumpWidget(_harness(onSelected: (_) {}));
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(_panelKey),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;

    expect(material.elevation, 16, reason: '与 MenuAnchor 面板同一档阴影');
    expect(
      (shape.borderRadius as BorderRadius).topLeft.x,
      AgentMenuStyle.panelRadius,
      reason: '12dp 圆角，和其他菜单是同一套轮廓',
    );
    expect(
      shape.side.color,
      Theme.of(tester.element(find.byKey(_panelKey))).colorScheme.outlineVariant
          .withValues(alpha: 0.5),
      reason: '1px 描边同样来自 AgentMenuStyle.panelStyleOf',
    );
  });
}
