import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/model_providers.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/features/conversations/approval_mode.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/composer_context_ring.dart';
import 'package:jarvis_app/src/features/conversations/composer_menus.dart';
import 'package:jarvis_app/src/features/conversations/composer_reasoning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生效配置的模型 ID 与模型名。
///
/// 两者刻意不同：界面上必须显示人可读的那个，`-1017` 后缀只该出现在发给上游
/// 的 `model` 字段里。触发器与一级行都用同一个文案。
const String _activeModelId = 'deepseek-v4.1-flash-1017';
const String _activeModelName = 'DeepSeek-V4.1-Flash-1017';

/// 一份假的生效配置。
ModelProfileView _activeProfile({
  bool reasoning = true,
  bool available = true,
  String? reason,
  String modelName = _activeModelName,
}) {
  return ModelProfileView(
    id: 'default',
    name: 'DeepSeek',
    builtin: true,
    active: true,
    enabled: true,
    baseUrl: 'https://api.example.com',
    apiPath: '/compatible-mode/v1',
    model: _activeModelId,
    modelName: modelName,
    vision: false,
    reasoning: reasoning,
    available: available,
    reason: reason,
  );
}

ModelListView _modelList({
  bool reasoning = true,
  bool available = true,
  String? reason,
  String modelName = _activeModelName,
}) {
  return ModelListView(
    activeId: 'default',
    persisted: true,
    models: <ModelProfileView>[
      _activeProfile(
        reasoning: reasoning,
        available: available,
        reason: reason,
        modelName: modelName,
      ),
    ],
  );
}

/// 输入面板需要的 provider 作用域。
///
/// 面板会在 `initState` 预取技能清单（否则第一次打 `@` 出不来候选），
/// 所以即便是纯展示测试也必须给一个 `ProviderScope`；这里喂空清单、
/// 喂一份假的生效配置，全程不触网。
Widget _scope(Widget child, {ModelListView? models}) {
  return ProviderScope(
    overrides: [
      atSkillsProvider.overrideWith((ref) async => const <SkillInfo>[]),
      modelProfilesProvider.overrideWith((ref) async => models ?? _modelList()),
    ],
    child: child,
  );
}

/// 只装输入面板：三个入口吃页面传来的值 + provider 里的生效配置。
Widget _harness({
  ModelListView? models,
  String reasoning = ReasoningLevels.fallback,
  ValueChanged<String>? onReasoningChanged,
  int contextTokens = 0,
}) {
  final controller = QuillController.basic();
  addTearDown(controller.dispose);
  return _scope(
    MaterialApp(
      home: Scaffold(
        // 如实还原会话页：面板贴着窗口底部，上面留出被消息列表占满的空间。
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16),
              child: ChatComposer(
                controller: controller,
                sending: false,
                onSend: () {},
                onStop: () {},
                reasoning: reasoning,
                onReasoningChanged: onReasoningChanged,
                contextTokens: contextTokens,
                contextWindow: contextTokens > 0 ? 1000000 : 0,
              ),
            ),
          ],
        ),
      ),
    ),
    models: models,
  );
}

/// 浮层里所有可点的条目。`SubmenuButton` 不是 `MenuItemButton` 的子类，
/// 所以一级那两行不会被算进来——它们本来就是要能点的（用来展开二级）。
Iterable<MenuItemButton> _rows(WidgetTester tester) =>
    tester.widgetList<MenuItemButton>(find.byType(MenuItemButton));

/// 把一枚图标渲染成位图，量出真实墨迹包围盒（逻辑像素）。
///
/// 测试环境默认用 FlutterTest 占位字体，图标会渲染成同一个方框；
/// [setUpAll] 里先装载 MaterialIcons，量到的才是字形本身。
Future<Rect?> _inkBoundsOf(
  WidgetTester tester,
  IconData icon, {
  double scale = 1,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox.square(
            dimension: 40,
            child: Center(
              child: Transform.scale(
                scale: scale,
                child: Icon(
                  icon,
                  size: AgentMenuStyle.iconSize,
                  color: const Color(0xFF000000),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  const ratio = 8.0;
  final image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: ratio),
  );
  final bytes = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final data = bytes!;
  final width = image!.width;
  final height = image.height;

  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final alpha = data.getUint8((y * width + x) * 4 + 3);
      if (alpha > 24) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) {
    return null;
  }
  return Rect.fromLTRB(
    minX / ratio,
    minY / ratio,
    (maxX + 1) / ratio,
    (maxY + 1) / ratio,
  );
}

void main() {
  setUpAll(() async {
    // 不装载图标字体的话，三枚图标都会渲染成同一个占位方框，
    // 墨迹测量就失去意义（看起来"完全一样"）。
    final loader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await loader.load();
  });

  testWidgets('「+」菜单能展开：两组四条齐全，条目可选（占位，点完只收菜单）', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerAttachButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('添加'), findsOneWidget);
    expect(find.text('指令'), findsOneWidget);
    // 触发器贴着窗口底部，浮层只能往上长：第一个分组标题要在触发器上沿之上。
    expect(
      tester.getTopLeft(find.text('添加')).dy,
      lessThan(tester.getTopLeft(find.byKey(kComposerAttachButtonKey)).dy),
      reason: '浮层应从触发器上方弹出',
    );
    for (final label in <String>['文件', '计划', '压缩', '下载日志']) {
      expect(find.text(label), findsOneWidget, reason: '$label 应该出现在「+」浮层里');
    }
    // 英文别名与行尾用途说明：看得出「将来这个是干什么的」。
    expect(find.text('file'), findsOneWidget);
    expect(find.text('将当前会话内容导出为 ZIP'), findsOneWidget);

    expect(_rows(tester), isNotEmpty);
    expect(
      _rows(tester).every((row) => row.onPressed != null),
      isTrue,
      reason: '占位期条目也要能点，好确认悬停与点击反馈',
    );

    // 点一条：没有对应能力，只收起菜单，不抛异常。
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsNothing, reason: '选完应该收起浮层');
  });

  testWidgets('「权限」菜单有三项：请求审批 / 帮我审批 / 完全放行，各带一句用途', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();

    expect(find.text('应如何审批'), findsOneWidget);
    // 默认是「请求审批」：既是触发器上的当前值，也是浮层里的一项。
    expect(find.text('请求审批'), findsNWidgets(2));
    expect(find.text('帮我审批'), findsOneWidget);
    expect(find.text('完全放行'), findsOneWidget);
    // 旧的四项与 EXP 徽标必须彻底消失，否则用户会以为还有"完全权限"。
    for (final gone in <String>['仅可查看', '项目内修改', '完全权限', '自动审查', 'EXP']) {
      expect(find.text(gone), findsNothing, reason: '$gone 应该已经删掉');
    }
    expect(
      find.text(ApprovalModes.describe(ApprovalModes.request)),
      findsOneWidget,
    );
    expect(
      find.text(ApprovalModes.describe(ApprovalModes.auto)),
      findsOneWidget,
    );
    expect(
      find.text(ApprovalModes.describe(ApprovalModes.trust)),
      findsOneWidget,
    );
    expect(
      find.byIcon(Icons.check_rounded),
      findsOneWidget,
      reason: '当前审批方式只该有一个勾',
    );

    expect(_rows(tester), isNotEmpty);
    expect(_rows(tester).every((row) => row.onPressed != null), isTrue);
  });

  testWidgets('选中「帮我审批」后触发器跟着变', (tester) async {
    var permission = ComposerDefaults.permission;
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _scope(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ChatComposer(
                controller: controller,
                sending: false,
                onSend: () {},
                onStop: () {},
                permission: permission,
                onPermissionChanged: (value) =>
                    setState(() => permission = value),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('帮我审批'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        ComposerDefaults.permission == ApprovalModes.auto ? '' : '帮我审批',
      ),
      findsOneWidget,
      reason: '选完触发器应显示新值',
    );
    expect(permission, ApprovalModes.auto);
  });

  testWidgets('「模型」一级浮层是「模型 / 推理等级」两行，当前值并列显示', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();

    expect(find.text('模型'), findsOneWidget);
    expect(find.text('推理等级'), findsOneWidget);

    // 面板宽度必须精确等于配置值：`MenuAnchor` 按它算位置与越界夹取，
    // 实际绘制更宽的话，浮层贴到窗口右边时最外侧的描边与投影会被裁掉
    // （就是「模型菜单少一条边、没阴影」的那个问题）。
    final panel = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.elevation > 0,
      ),
    );
    expect(panel.width, closeTo(kComposerModelMenuWidth, 0.5));
    // 面板右边缘要压在胶囊右边缘上，而不是往左飘一个胶囊宽。
    final pill = tester.getRect(find.byKey(kComposerModelMenuKey));
    expect(panel.right, closeTo(pill.right, 0.5));

    // 这两行的字必须与权限菜单里的条目同款：14sp / 常规字重。
    // 裸 `TextStyle` 会继承 `SubmenuButton` 内部 TextButton 的 labelLarge（w500），
    // 之前看起来比权限菜单「粗一档」就是它。
    final label = tester.widget<Text>(find.text('模型'));
    expect(label.style!.fontSize, 14);
    expect(label.style!.fontWeight, FontWeight.w400);
    // 触发器与「模型」那一行各显示一次：两边都读同一份生效配置。
    expect(find.text(_activeModelName), findsNWidgets(2));
    expect(
      find.text(ReasoningLevels.labelOf(ReasoningLevels.fallback)),
      findsOneWidget,
      reason: '推理等级只在菜单里出现，触发器上不挂',
    );
  });

  testWidgets('「模型」二级只列当前生效配置的模型，选中项打勾', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerModelSubmenuKey));
    await tester.pumpAndSettle();

    // 组标题是生效配置的名字，组内只有它的模型。
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(
      find.text('TokenHub'),
      findsNothing,
      reason: '只列当前生效供应商，不该再出现别的配置',
    );
    expect(
      find.text(_activeModelId),
      findsNothing,
      reason: '界面只显示人可读的模型名，不露发给上游的模型 ID',
    );
    expect(
      find.text(_activeModelName),
      findsNWidgets(3),
      reason: '触发器 + 一级行 + 二级条目',
    );
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(_rows(tester).every((row) => row.onPressed != null), isTrue);
  });

  testWidgets('生效配置不可用时条目置灰并给出原因', (tester) async {
    await tester.pumpWidget(
      _harness(
        models: _modelList(available: false, reason: '缺少密钥'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerModelSubmenuKey));
    await tester.pumpAndSettle();

    expect(find.text('缺少密钥'), findsOneWidget);
    expect(
      _rows(tester).every((row) => row.onPressed == null),
      isTrue,
      reason: '不可用的模型不该能点',
    );
  });

  testWidgets('「推理等级」二级是四档，带说明且可切换', (tester) async {
    String? selected;
    await tester.pumpWidget(_harness(onReasoningChanged: (v) => selected = v));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerReasoningSubmenuKey));
    await tester.pumpAndSettle();

    for (final level in ReasoningLevels.all) {
      expect(
        find.text(ReasoningLevels.labelOf(level)),
        findsWidgets,
        reason: '${ReasoningLevels.labelOf(level)} 应该出现在二级列表里',
      );
      expect(find.text(ReasoningLevels.describe(level)), findsOneWidget);
    }
    // 已删掉的中间档不该再出现：实测它与 high 的行为不稳定。
    expect(find.text('Medium'), findsNothing);

    await tester.tap(find.text(ReasoningLevels.labelOf(ReasoningLevels.max)));
    await tester.pumpAndSettle();
    expect(selected, ReasoningLevels.max, reason: '点了要把值回传给页面');
  });

  testWidgets('一份配置都没有时给占位说明，不是空白浮层', (tester) async {
    await tester.pumpWidget(_harness(models: ModelListView.empty));
    await tester.pumpAndSettle();

    expect(find.text('未配置模型'), findsOneWidget);

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerModelSubmenuKey));
    await tester.pumpAndSettle();

    expect(find.text('还没有可用的模型配置'), findsOneWidget);
    expect(find.text('推理等级'), findsNothing, reason: '不知道能力时不该给入口');
  });

  testWidgets('配置不支持推理等级时整行不出现', (tester) async {
    await tester.pumpWidget(_harness(models: _modelList(reasoning: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();

    expect(find.text('推理等级'), findsNothing);
    expect(find.byKey(kComposerReasoningSubmenuKey), findsNothing);
  });

  testWidgets('权限与模型胶囊未展开时完全透明，融入面板底色', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    for (final label in <String>[
      ApprovalModes.labelOf(ComposerDefaults.permission),
      _activeModelName,
    ]) {
      final pill = tester.widget<Container>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      final color = (pill.decoration! as BoxDecoration).color!;
      expect(color.a, 0, reason: '「$label」胶囊未展开时应该没有底色');
    }
  });

  testWidgets('「+」到面板左边与下边的距离相等', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    final plus = tester.getRect(find.byKey(kComposerAttachButtonKey));
    final insetLeft = plus.left - panel.left;
    expect(insetLeft, closeTo(panel.bottom - plus.bottom, 0.5));
    // 8 的内边距 + 1px 描边；旧值左边 15、下边 12。
    expect(insetLeft, closeTo(9, 0.5));
  });

  testWidgets('占位提示仍在，且走第三档文字色', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 编辑器换成富文本后 placeholder 由 quill 画在 `RichText` 里，
    // 不再是 `InputDecoration` 的 hintText，所以按 span 文本找。
    final tertiary = AppPalette.of(
      tester.element(find.byKey(kChatComposerPanelKey)),
    ).text.tertiary;
    final placeholder = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((rich) => rich.text.toPlainText().contains('发送消息；@ 技能派任务'))
        .toList();
    expect(placeholder, isNotEmpty, reason: '占位文案应渲染成富文本');
    expect(placeholder.first.text.style?.color, tertiary);
  });

  testWidgets('上下文环夹在模型胶囊与发送按钮之间', (tester) async {
    await tester.pumpWidget(
      _harness(models: _modelList(), contextTokens: 16800),
    );
    await tester.pumpAndSettle();

    final ring = tester.getRect(find.byType(ContextUsageRing));
    final model = tester.getRect(find.byKey(kComposerModelMenuKey));
    final send = tester.getRect(find.byIcon(Icons.arrow_upward));

    expect(
      ring.left,
      greaterThanOrEqualTo(model.right),
      reason: '环在模型胶囊右侧，不能盖住胶囊',
    );
    expect(ring.right, lessThanOrEqualTo(send.left), reason: '环在发送按钮左侧');
  });

  testWidgets('没有上下文用量时不渲染环，也不留空位', (tester) async {
    await tester.pumpWidget(_harness(models: _modelList()));
    await tester.pumpAndSettle();

    expect(find.byType(ContextUsageRing), findsNothing);

    final model = tester.getRect(find.byKey(kComposerModelMenuKey));
    final send = tester.getRect(find.byIcon(Icons.arrow_upward));
    expect(
      send.left - model.right,
      lessThan(20),
      reason: '环隐藏后不该再留出一枚环（26dp）加间距的空位',
    );
  });

  testWidgets('窄窗口下控件行不溢出：模型名截断而不是报 overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊箭头收起朝下、展开后转半圈朝上', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    Finder chevronOf(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(AnimatedRotation),
    );

    // 收起态：图标本身朝下，旋转为 0。方向表达"点开会展开"，
    // 与面板向上弹出无关——反过来的话就是在暗示"已经展开了"。
    expect(
      find.descendant(
        of: find.byKey(kComposerPermissionMenuKey),
        matching: find.byIcon(Icons.expand_more_rounded),
      ),
      findsOneWidget,
      reason: '收起时箭头朝下',
    );
    expect(tester.widget<AnimatedRotation>(
      chevronOf(kComposerPermissionMenuKey),
    ).turns, 0);

    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedRotation>(
        chevronOf(kComposerPermissionMenuKey),
      ).turns,
      0.5,
      reason: '展开后转半圈朝上',
    );
  });

  testWidgets('胶囊文字用控件档，常驻与展开同色', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    Text labelOf(Key key) => tester.widget<Text>(
      find.descendant(of: find.byKey(key), matching: find.byType(Text)).first,
    );

    final palette = AppPalette.of(
      tester.element(find.byKey(kChatComposerPanelKey)),
    );
    expect(
      labelOf(kComposerPermissionMenuKey).style?.color,
      palette.text.control,
      reason: '常驻态只是提示当前设置，不该和输入内容抢注意力',
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(kComposerAttachButtonKey),
              matching: find.byIcon(Icons.add_rounded),
            ),
          )
          .color,
      palette.text.control,
      reason: '同一行的「+」与胶囊共用一个灰，不许比它重一档',
    );

    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();
    expect(
      labelOf(kComposerPermissionMenuKey).style?.color,
      palette.text.control,
      reason: '展开也不换色：交互反馈只靠悬停底',
    );

    // 两个胶囊必须同档：一边大一边小会让「请求审批」看起来像主按钮。
    for (final key in <Key>[
      kComposerPermissionMenuKey,
      kComposerModelMenuKey,
    ]) {
      expect(
        labelOf(key).style?.fontSize,
        AppFontSize.sm,
        reason: '权限与模型胶囊统一走小字档（11.5）',
      );
    }
  });

  testWidgets('权限三枚图标占位一致、声明尺寸一致，只做光学补偿', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();

    const scales = kComposerPermissionIconScale;
    for (final entry in scales.entries) {
      final box = find.byKey(ValueKey<String>('permission-icon-${entry.key}'));
      expect(box, findsOneWidget, reason: '${entry.key} 行要有行首占位框');
      expect(
        tester.getSize(box),
        const Size(18, 18),
        reason: '三行图标占位框必须一样大',
      );

      final icon = tester.widget<Icon>(
        find.descendant(of: box, matching: find.byType(Icon)),
      );
      expect(
        icon.size,
        AgentMenuStyle.iconSize,
        reason: '物理声明尺寸统一为 16，视觉差靠 scale 补',
      );

      // 读矩阵的 X 轴缩放，不用 `getMaxScaleOnAxis()`：后者把 Z 轴的 1.0
      // 也算进去，缩小（< 1）时会恒得 1.0。
      final transforms = tester
          .widgetList<Transform>(
            find.descendant(of: box, matching: find.byType(Transform)),
          )
          .map((item) => item.transform.storage[0])
          .toList();
      expect(
        transforms.any((value) => (value - entry.value).abs() < 0.001),
        isTrue,
        reason: '${entry.key} 的光学补偿系数',
      );
    }
  });

  testWidgets('三枚图标的墨迹高度一致（以闪电为基准）', (tester) async {
    final heights = <String, double>{};
    for (final entry in <String, IconData>{
      ApprovalModes.request: Icons.pan_tool_outlined,
      ApprovalModes.auto: Icons.verified_user_outlined,
      ApprovalModes.trust: Icons.bolt_outlined,
    }.entries) {
      final rect = await _inkBoundsOf(
        tester,
        entry.value,
        scale: kComposerPermissionIconScale[entry.key] ?? 1,
      );
      expect(rect, isNotNull, reason: '${entry.key} 应当渲染出可见墨迹');
      heights[entry.key] = rect!.height;
    }

    final list = heights.values.toList();
    final minHeight = list.reduce((a, b) => a < b ? a : b);
    final maxHeight = list.reduce((a, b) => a > b ? a : b);
    expect(
      maxHeight - minHeight,
      lessThanOrEqualTo(1),
      reason: '三枚图标要缩放成同一视觉高度，实测：$heights',
    );
  });

  testWidgets('一级「模型」行：主标题与当前值留间距，当前值小一档', (tester) async {
    await tester.pumpWidget(_harness(models: _modelList()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();

    final row = find.byKey(kComposerModelSubmenuKey);
    final label = find.descendant(of: row, matching: find.text('模型'));
    final value = find.descendant(
      of: row,
      matching: find.text(_activeModelName),
    );

    expect(value, findsOneWidget, reason: '当前值显示模型名');
    expect(
      tester.getRect(value).left - tester.getRect(label).right,
      greaterThanOrEqualTo(11.5),
      reason: '主标题与当前值之间要留出 12dp，不能贴在一起',
    );

    final valueText = tester.widget<Text>(value);
    expect(
      valueText.style?.fontSize,
      AppFontSize.sm,
      reason: '当前值是次文案，比主标题（14）小一档',
    );
    expect(valueText.overflow, TextOverflow.ellipsis);

    // 折角与当前值都要靠右：主标题不能占 flex 空间把右侧挤到行中部。
    final chevron = find.descendant(
      of: row,
      matching: find.byIcon(Icons.chevron_right_rounded),
    );
    expect(chevron, findsOneWidget);
    final rowRect = tester.getRect(row);
    final chevronRect = tester.getRect(chevron);
    expect(
      rowRect.right - chevronRect.right,
      closeTo(AgentMenuStyle.submenuChevronInset, 1.5),
      reason: '行右侧内边距为 0，折角再左移 4dp',
    );
    expect(
      tester.widget<Icon>(chevron).color,
      AppPalette.of(tester.element(row)).text.primary,
      reason: '折角用主标题的正文色，不再用淡灰',
    );
    expect(
      chevronRect.left - tester.getRect(value).right,
      closeTo(8, 1.5),
      reason: 'trailing 槽位的 12dp 减去折角左移 4dp，收到 8dp',
    );
    expect(
      rowRect.width,
      closeTo(kComposerModelMenuWidth - AgentMenuStyle.panelPadding * 2, 1),
      reason: '折角占位调整后，一级面板内容宽不应被撑大',
    );
  });

  testWidgets('模型名过长时触发器在 220 内省略', (tester) async {
    await tester.pumpWidget(
      _harness(
        models: _modelList(
          modelName: '深度求索 ${'deepseek-v4.1-flash-1017' * 2}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(kComposerModelMenuKey)).width,
      lessThanOrEqualTo(kComposerModelPillMaxWidth + 0.5),
      reason: '触发器有宽度上限，不随模型名一路变长',
    );

    final label = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(kComposerModelMenuKey),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(label.overflow, TextOverflow.ellipsis);
    expect(label.maxLines, 1);
  });

  testWidgets('勾选标记全站同色', (tester) async {
    await tester.pumpWidget(_harness(models: _modelList()));
    await tester.pumpAndSettle();

    final anchor = tester.element(find.byKey(kComposerModelMenuKey));
    final expected = AgentMenuStyle.selectedMarkColorOf(anchor);

    // 权限菜单：两行富文本行，默认「请求审批」选中。
    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_rounded)).color,
      expected,
      reason: '富文本行的勾选色走组件统一口径',
    );
    await tester.tap(find.byKey(kComposerPermissionMenuKey));
    await tester.pumpAndSettle();

    // 模型二级：选项行，唯一一条即当前模型。
    await tester.tap(find.byKey(kComposerModelMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kComposerModelSubmenuKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_rounded)).color,
      expected,
      reason: '选项行的勾选色与富文本行同一档',
    );
  });

  testWidgets('权限胶囊触发器图标与菜单项同尺寸同补偿', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final pill = find.byKey(kComposerPermissionMenuKey);
    final icon = find.descendant(of: pill, matching: find.byType(Icon)).first;

    expect(
      tester.widget<Icon>(icon).size,
      AgentMenuStyle.iconSize,
      reason: '触发器图标的声明尺寸与菜单项一致（16）',
    );
    expect(
      tester.getSize(
        find.ancestor(of: icon, matching: find.byType(SizedBox)).first,
      ),
      const Size.square(AgentMenuStyle.triggerIconBox),
      reason: '占位框 18，与菜单项共用同一块画布',
    );

    final transform = tester.widget<Transform>(
      find.ancestor(of: icon, matching: find.byType(Transform)).first,
    );
    expect(
      transform.transform.storage[0],
      closeTo(kComposerPermissionIconScale[ApprovalModes.request]!, 0.001),
      reason: '默认「请求审批」使用与菜单项相同的补偿系数',
    );
  });
}
