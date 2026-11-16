import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Key _anchorKey = Key('agent-menu-test-anchor');
const Key _copyKey = Key('agent-menu-test-copy');
const Key _pasteKey = Key('agent-menu-test-paste');
const Key _deleteKey = Key('agent-menu-test-delete');

/// 触发器故意自己接管左键/右键：组件只负责"菜单长什么样、怎么弹"，
/// 什么时候弹由调用方决定，测起来也正是这个边界。
///
/// `triggerHandlesTap: false` 与真实调用点（各处「⋯」）一致：
/// 组件不再在外面包手势，避免一次点击既开又关。
Widget _harness({
  required ValueChanged<String> onSelected,
  List<AgentMenuItem<String>>? items,
  List<AgentMenuGroup<String>>? groups,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Padding(
        // 故意把锚点从窗口左上角挪开：`open(position:)` 收的是**相对锚点**的
        // 局部坐标，锚点贴着 (0,0) 时全局与局部恰好重合，坐标系搞反也测不出来。
        padding: const EdgeInsets.fromLTRB(100, 60, 0, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            height: 160,
            child: AgentMenu<String>(
              width: AgentMenuStyle.panelMinWidth,
              alignmentOffset: Offset.zero,
              groups:
                  groups ??
                  <AgentMenuGroup<String>>[
                    AgentMenuGroup<String>(items: items ?? _items()),
                  ],
              onSelected: onSelected,
              consumeOutsideTap: true,
              triggerHandlesTap: false,
              builder: (context, controller, open, hovering) => GestureDetector(
                key: _anchorKey,
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                onSecondaryTapDown: (details) =>
                    controller.open(position: details.localPosition),
                child: const SizedBox.expand(),
              ),
            ),
          ),
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
  testWidgets('点触发器打开菜单，选中后收起并回传值', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_harness(onSelected: picked.add));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing, reason: '关着的时候不该有浮层');

    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(
      tester.widget<MenuItemButton>(find.byKey(_copyKey)).requestFocusOnHover,
      isFalse,
      reason: '悬停不该抢焦点：逐项迁移焦点是菜单卡顿的主因之一',
    );

    await tester.tap(find.byKey(_pasteKey));
    await tester.pumpAndSettle();

    expect(picked, <String>['paste']);
    expect(find.text('粘贴'), findsNothing, reason: '选完应当自动收起');
  });

  testWidgets('禁用项不响应点击，菜单也不收起', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _harness(onSelected: picked.add, items: _items(disabledDelete: true)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    final item = tester.widget<MenuItemButton>(find.byKey(_deleteKey));
    expect(item.onPressed, isNull, reason: '禁用态就是 onPressed 为 null');

    await tester.tap(find.byKey(_deleteKey));
    await tester.pumpAndSettle();

    expect(picked, isEmpty);
    expect(find.text('删除'), findsOneWidget, reason: '点禁用项不该把菜单关掉');
  });

  testWidgets('dividerBefore 在分组处画一条线，第一项上的标记被忽略', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_harness(onSelected: picked.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    expect(
      find.byType(AgentMenuDivider),
      findsOneWidget,
      reason: '只有「粘贴」前有分组线',
    );

    // 第一项即使标了 dividerBefore 也不画：菜单顶部不需要悬空的线。
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _harness(
        onSelected: picked.add,
        items: <AgentMenuItem<String>>[
          const AgentMenuItem<String>(
            key: _copyKey,
            value: 'copy',
            label: '复制',
            dividerBefore: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    expect(find.byType(AgentMenuDivider), findsNothing);
  });

  testWidgets('分组标题与组间分组线都由 groups 决定', (tester) async {
    await tester.pumpWidget(
      _harness(
        onSelected: (_) {},
        groups: const <AgentMenuGroup<String>>[
          AgentMenuGroup<String>(
            title: '第一组',
            items: <AgentMenuItem<String>>[
              AgentMenuItem<String>(value: 'a', label: '甲'),
            ],
          ),
          AgentMenuGroup<String>(
            title: '第二组',
            dividerBefore: true,
            items: <AgentMenuItem<String>>[
              AgentMenuItem<String>(value: 'b', label: '乙'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    expect(find.text('第一组'), findsOneWidget);
    expect(find.text('第二组'), findsOneWidget);
    expect(
      find.byType(AgentMenuDivider),
      findsOneWidget,
      reason: '两组之间一条线；第一组之前不画',
    );
  });

  testWidgets('菜单面板不小于最小宽度：短文案也不会把面板挤窄', (tester) async {
    await tester.pumpWidget(_harness(onSelected: (_) {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    // `MenuStyle.minimumSize` 会被 `IntrinsicWidth` 绕过，真正兜底的是条目自己。
    expect(
      tester.getSize(find.byKey(_copyKey)).width,
      closeTo(AgentMenuStyle.itemMinWidth, 0.5),
      reason: '条目要撑到 itemMinWidth，面板才不会被短文案挤窄',
    );
  });

  testWidgets('items 为空时不构建任何菜单项', (tester) async {
    await tester.pumpWidget(
      _harness(onSelected: (_) {}, items: const <AgentMenuItem<String>>[]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('右键在落点弹出：菜单跟着鼠标走，而不是固定在一个地方', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_harness(onSelected: picked.add));
    await tester.pumpAndSettle();

    // 锚点在窗口 (100,60) 处，所以这个落点的局部坐标是 (80,60)。
    // 若错把全局坐标当局部坐标传，菜单会整体右移/下移一格。
    const spot = Offset(180, 120);
    await tester.tapAt(
      spot,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    final label = tester.getTopLeft(find.text('复制'));
    expect(label.dx, greaterThan(spot.dx), reason: '菜单应出现在落点右下');
    expect(label.dx, lessThan(spot.dx + 80), reason: '不该被锚点再推一格');
    expect(label.dy, lessThan(spot.dy + 60), reason: '纵向同样要贴着落点');
  });

  testWidgets('二级子菜单行向右展开，选中项走它自己的回调', (tester) async {
    const submenuKey = Key('agent-menu-test-submenu');
    final picked = <String>[];

    await tester.pumpWidget(
      _harness(
        onSelected: (_) {},
        items: <AgentMenuItem<String>>[
          AgentMenuItem<String>(
            key: submenuKey,
            label: '模型',
            submenuValue: 'DeepSeek',
            submenuWidth: 200,
            submenu: <AgentMenuGroup<String>>[
              AgentMenuGroup<String>(
                items: <AgentMenuItem<String>>[
                  AgentMenuItem<String>(
                    value: 'deepseek',
                    label: 'DeepSeek',
                    onSelected: picked.add,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    // 一级行显示当前值，此时只有这一处「DeepSeek」。
    expect(find.text('DeepSeek'), findsOneWidget);
    await tester.tap(find.byKey(submenuKey));
    await tester.pumpAndSettle();

    // 展开后：一级行 + 二级条目各一处。
    expect(find.text('DeepSeek'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(MenuItemButton, 'DeepSeek'));
    await tester.pumpAndSettle();

    expect(picked, <String>['deepseek'], reason: '二级项可以覆盖组件级回调');
  });

  testWidgets('自定义行首控件出现在行首，二行副标题随之渲染', (tester) async {
    const leadingKey = Key('agent-menu-test-leading');

    await tester.pumpWidget(
      _harness(
        onSelected: (_) {},
        items: <AgentMenuItem<String>>[
          AgentMenuItem<String>(
            value: 'mode',
            label: 'CODE',
            subtitle: '构建、调试和发布',
            leading: const SizedBox(key: leadingKey, width: 20, height: 20),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_anchorKey));
    await tester.pumpAndSettle();

    expect(find.byKey(leadingKey), findsOneWidget);
    expect(find.text('CODE'), findsOneWidget);
    expect(find.text('构建、调试和发布'), findsOneWidget);
  });

  testWidgets('开合状态下发给触发器：折角与高亮跟着变', (tester) async {
    const triggerKey = Key('agent-menu-test-state-trigger');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AgentMenu<String>(
              width: AgentMenuStyle.panelMinWidth,
              groups: const <AgentMenuGroup<String>>[
                AgentMenuGroup<String>(
                  items: <AgentMenuItem<String>>[
                    AgentMenuItem<String>(value: 'a', label: '甲'),
                  ],
                ),
              ],
              onSelected: (_) {},
              // 默认由组件接管点击：点一下就开，再点一下收起。
              builder: (context, controller, open, hovering) => SizedBox(
                key: triggerKey,
                width: 80,
                height: 30,
                child: Center(child: Text(open ? 'open' : 'closed')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('closed'), findsOneWidget);

    await tester.tap(find.byKey(triggerKey));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget, reason: '展开后触发器应当拿到 open=true');
    expect(find.text('甲'), findsOneWidget);

    await tester.tap(find.byKey(triggerKey));
    await tester.pumpAndSettle();
    expect(find.text('closed'), findsOneWidget, reason: '再点一下收起');
    expect(find.text('甲'), findsNothing);
  });

  test('宽度换算：内容宽 = 面板宽 − 28，子菜单行再抵掉 20', () {
    // 面板内边距 6×2 + 条目左右内边距 8×2 = 28。
    expect(AgentMenuStyle.contentWidthOf(340), 312);
    expect(AgentMenuStyle.contentWidthOf(300), 272);
    // 折角槽位 12 + 16 = 28，子菜单行右内边距比普通行少 8，净抵掉 20。
    expect(AgentMenuStyle.submenuRowWidthOf(300), 252);
    expect(AgentMenuStyle.itemMinWidth, 208);
  });

  testWidgets('条目悬停是浅灰块，默认态透明', (tester) async {
    await tester.pumpWidget(_harness(onSelected: (_) {}));
    await tester.pumpAndSettle();

    final context = tester.element(find.byKey(_anchorKey));
    final scheme = Theme.of(context).colorScheme;
    final style = AgentMenuStyle.rowStyleOf(context);

    expect(
      style.backgroundColor!.resolve(const <WidgetState>{}),
      scheme.onSurface.withValues(alpha: 0),
      reason: '默认态是同色 0 透明度，插值时不会先经过透明黑',
    );
    expect(
      style.backgroundColor!.resolve(const <WidgetState>{WidgetState.hovered}),
      scheme.surfaceContainerHighest.withValues(alpha: 0.9),
      reason: '全站统一为浅灰悬停块，字色不变',
    );
    expect(
      style.overlayColor!.resolve(const <WidgetState>{WidgetState.hovered}),
      Colors.transparent,
      reason: '默认 overlay 关掉，避免叠出第二层灰',
    );
    expect(
      style.animationDuration,
      Duration.zero,
      reason: '状态色当帧到位，不再有 200ms 的跟随动画',
    );

    final shape =
        style.shape!.resolve(const <WidgetState>{})! as RoundedRectangleBorder;
    expect(
      (shape.borderRadius as BorderRadius).topLeft.x,
      AgentMenuStyle.itemRadius,
    );
  });
}
