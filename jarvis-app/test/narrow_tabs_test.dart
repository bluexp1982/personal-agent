import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/liquid_glass_nav.dart';
import 'package:jarvis_app/src/core/ui/mobile_top_bar.dart';
import 'package:jarvis_app/src/core/ui/top_bar_fade.dart';
import 'package:jarvis_app/src/features/call/call_page.dart';
import 'package:jarvis_app/src/features/profile/profile_page.dart';
import 'package:jarvis_app/src/features/projects/project_detail_page.dart';
import 'package:jarvis_app/src/features/recordings/recordings_page.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/messages_page.dart';
import 'package:jarvis_app/src/features/shell/narrow_tab_bar.dart';
import 'package:jarvis_app/src/features/shell/narrow_tab_glass.dart';
import 'package:jarvis_app/src/features/shell/narrow_tab_icons.dart';
import 'package:jarvis_app/src/features/shell/narrow_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

Widget _harness({
  List<Project>? projects,
  bool reduceMotion = false,
  bool dark = false,
}) {
  return ProviderScope(
    overrides: [
      // 不接真实服务：四个标签页都不该因为拿不到数据而报错。
      apiClientProvider.overrideWithValue(null),
      if (projects != null) projectsProvider.overrideWith((ref) => projects),
    ],
    child: MaterialApp(
      theme: dark ? ThemeData(brightness: Brightness.dark) : null,
      // 用 builder 改 MediaQuery 而不是另建一棵树：尺寸、padding 全部保留，
      // 只把系统的「减弱动态效果」打开。
      builder: reduceMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: const HomeShell(session: _session),
    ),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 录音列表里有一个常驻的加载指示器，`pumpAndSettle` 永远等不到静止。
Future<void> _pumpPages(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

List<Project> _projects() => const <Project>[
  Project(
    id: 'w1',
    name: 'hello-demo',
    mode: ProjectModes.work,
    path: '/tmp/hello-demo',
    conversationCount: 1,
    taskCount: 1,
  ),
];

void main() {
  // 生产默认走液态玻璃，但这里绝大多数用例断的是"旧路径"的装饰细节
  // （底色 alpha、自绘高光、container 装饰），所以统一先钉回旧路径；
  // 液态玻璃那条用例自己打开开关。
  setUp(() => liquidGlassNavEnabled = false);
  tearDown(() => liquidGlassNavEnabled = kLiquidGlassNavDefault);

  testWidgets('窄屏有五个一级标签，顺序是 Agent / 记录 / 通话 / 消息 / 我的', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byKey(kBottomNavKey), findsOneWidget);
    // 枚举顺序就是导航顺序：通话排在记录之后（原型里的位置）。
    expect(
      NarrowTab.values.map((tab) => tab.label).toList(),
      <String>['智能体', '记录', '通话', '消息', '我的'],
    );
    for (final tab in NarrowTab.values) {
      expect(
        find.byKey(narrowTabKey(tab)),
        findsOneWidget,
        reason: '缺了「${tab.label}」这个标签',
      );
    }
    // 默认 Agent：品牌页头 + 项目列表空态。
    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切标签只换内容页：不推路由，导航留在原地', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);
    expect(find.byType(RecordingsPage), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(find.byType(BackButton), findsNothing, reason: '标签切换不是 push');
    // 品牌页头只属于 Agent。
    expect(find.text('Jarvis'), findsNothing);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.call)));
    await _pumpPages(tester);
    expect(find.byType(CallPage), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(find.byType(BackButton), findsNothing, reason: '标签切换不是 push');
    // 通话页是占位：静态文案与四枚控制键都在。
    expect(find.text('实时通话'), findsOneWidget);
    expect(find.byTooltip('挂断'), findsOneWidget);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.messages)));
    await _pumpPages(tester);
    expect(find.byKey(kMessagesEmptyKey), findsOneWidget);
    expect(find.text('跨项目会话聚合'), findsOneWidget);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await _pumpPages(tester);
    expect(find.byType(ProfilePage), findsOneWidget);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.agent)));
    await _pumpPages(tester);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(find.text('Jarvis'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切走再切回，标签页的输入与滚动状态原样保留', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);

    await tester.tap(find.byTooltip('搜索'));
    await _pumpPages(tester);
    await tester.enterText(find.byType(TextField), '会议纪要');
    await _pumpPages(tester);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.messages)));
    await _pumpPages(tester);
    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);

    expect(
      find.text('会议纪要'),
      findsOneWidget,
      reason: 'IndexedStack 保留子树 State，搜索词不该被清掉',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('进项目详情：整页盖住导航，回不到别的标签', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness(projects: _projects()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('hello-demo'));
    await _pumpPages(tester);

    expect(find.byType(ProjectDetailPage), findsOneWidget);
    // 下层路由仍在树上（Navigator 会保留它），但被整页盖住、点不到也看不到：
    // 命中测试就是"用户能不能点到它"的口径。
    expect(
      find.byKey(kBottomNavKey).hitTestable(),
      findsNothing,
      reason: '详情页按原型没有底部导航',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏完全不渲染导航；拉宽再拉窄，当前标签还在', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(find.byKey(kBottomNavKey), findsOneWidget);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.messages)));
    await _pumpPages(tester);

    // 拉宽到三栏：导航消失，左栏回来。
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(kBottomNavKey), findsNothing);

    // 再拉窄：标签存在 provider 里，回来还是「消息」。
    tester.view.physicalSize = const Size(360, 800);
    await _pumpPages(tester);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(find.byKey(kMessagesEmptyKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊按参考规格悬浮：左右 20、距底 22、高 61', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byKey(kBottomNavKey));
    expect(rect.height, kBottomNavHeight);
    expect(rect.left, kBottomNavSideInset);
    expect(rect.right, 360 - kBottomNavSideInset);
    expect(rect.bottom, 800 - kBottomNavBottomGap);
    // 写死一次参考实测值：60 是上一轮的错值，别再被改回去。
    expect(kBottomNavHeight, 61);
    expect(kBottomNavSideInset, 20);
    expect(kBottomNavBottomGap, 22);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中底按参考规格：高 55、四周内缩 3、全圆角', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final capsule = tester.getRect(find.byKey(kBottomNavKey));
    final bg = tester.getRect(find.byKey(narrowTabBgKey(NarrowTab.agent)));

    // 高 55 = 胶囊 61 减去上下各 3；不再由内容撑开。
    expect(bg.height, kBottomNavItemHeight);
    expect(bg.height, 55);
    expect(bg.top - capsule.top, kBottomNavItemInset);
    expect(capsule.bottom - bg.bottom, kBottomNavItemInset);
    expect(bg.left - capsule.left, kBottomNavItemInset);

    // 宽 = 项宽 − 2×项间缝（不写死，屏宽变化时自动跟随）。
    // 胶囊没有描边，内容区就是「宽 − 左右内边距」。
    final contentWidth = capsule.width - 2 * kBottomNavContentInset;
    final itemWidth = contentWidth / NarrowTab.values.length;
    expect(bg.width, closeTo(itemWidth - 2 * kBottomNavItemGap, 0.01));

    // 圆角是选中底半高：胶囊形，且与胶囊同心（30.5 − 3 = 27.5）。
    expect(kBottomNavItemRadius, kBottomNavItemHeight / 2);
    expect(kBottomNavItemRadius, 27.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊不画描边，只留一层轻投影', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 参考 App 的胶囊边缘没有深色线圈：底色 + 阴影表达边界。
    final container = tester.widget<Container>(find.byKey(kBottomNavKey));
    final surface = container.decoration! as BoxDecoration;
    expect(surface.border, isNull, reason: '描边会让胶囊看起来像"有边框的卡片"');

    final shadowBox = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.byKey(kBottomNavKey),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final shadowDeco = shadowBox.decoration as BoxDecoration;
    expect(shadowDeco.boxShadow, hasLength(1), reason: '贴边那层细阴影已去掉');
    final shadow = shadowDeco.boxShadow!.single;
    expect(shadow.blurRadius, 20);
    expect(shadow.offset, const Offset(0, 4));
    expect(shadow.color.a, closeTo(0.08, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('胶囊底色够透：浅色 0.55 / 深色 0.60', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    BoxDecoration capsuleDecoration() =>
        tester.widget<Container>(find.byKey(kBottomNavKey)).decoration!
            as BoxDecoration;

    expect(
      capsuleDecoration().color!.a,
      closeTo(0.55, 0.001),
      reason: '底色太实会把透镜放大盖掉，只剩一层均匀的膜',
    );

    await tester.pumpWidget(_harness(dark: true));
    await tester.pumpAndSettle();
    expect(capsuleDecoration().color!.a, closeTo(0.60, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('图标 24、与文字的画布间距 2', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final icon = tester.widget<NarrowTabIcon>(find.byType(NarrowTabIcon).first);
    expect(icon.size, kNarrowTabIconSize);
    expect(kNarrowTabIconSize, 24);
    expect(kBottomNavItemContentGap, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有底部安全区时胶囊不再额外上移', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    // iPhone 的 Home 指示条区域：34pt。胶囊下沿仍应停在距底 22，
    // 而不是被安全区再顶高一截（那正是"底部比左右宽"的来源）。
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byKey(kBottomNavKey));
    expect(rect.bottom, 800 - kBottomNavBottomGap);
    expect(800 - rect.bottom, kBottomNavBottomGap, reason: '安全区不该改变底部间距');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「新建项目」在 Agent 页头右上角，切走就不在', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 主操作已从右下角的悬浮按钮上移到页头，与面板入口并排。
    final entry = find.byTooltip('新建项目');
    expect(entry, findsOneWidget);
    expect(
      find.byType(FloatingActionButton),
      findsNothing,
      reason: '不再有右下角的悬浮按钮',
    );

    final rect = tester.getRect(entry);
    expect(rect.height, kMobileTopBarButtonSize);
    expect(rect.top, lessThan(60), reason: '落在 54 高的页头里');
    expect(
      rect.right,
      lessThanOrEqualTo(360 - kMobileTopBarEndInset),
      reason: '贴右，但不压过页头内边距',
    );

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);
    expect(
      find.byTooltip('新建项目'),
      findsNothing,
      reason: '别的标签没有"新建项目"这回事',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agent 页头：新建项目与面板入口并成一枚胶囊', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final group = find.byType(MobileTopBarButtonGroup);
    expect(group, findsOneWidget, reason: '两枚动作不该各带一层背板');
    expect(tester.getSize(group), const Size(77, 38));

    final create = tester.getRect(find.byTooltip('新建项目'));
    final panel = tester.getRect(find.byTooltip('打开面板'));
    expect(create.width, 38);
    expect(panel.left - create.right, 1, reason: '格与格之间只有 1dp 分隔线');

    // 两枚都在同一枚胶囊里：组的外接矩形正好把它们包住。
    final capsule = tester.getRect(group);
    expect(capsule.left, create.left);
    expect(capsule.right, panel.right);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中底与胶囊同心：半径 = 胶囊半高 - 内边距', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final block = tester.widget<DecoratedBox>(
      find.byKey(narrowTabBgKey(NarrowTab.agent)),
    );
    final decoration = block.decoration as BoxDecoration;
    final radius = (decoration.borderRadius! as BorderRadius).topLeft.x;

    expect(radius, kBottomNavItemRadius);
    expect(
      radius,
      lessThan(kBottomNavHeight / 2),
      reason: '内层比外层少一圈留边，弧线才平行',
    );
    expect(
      radius,
      greaterThan(14),
      reason: '旧的固定 14 在 60 高的胶囊里偏方',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部虚化带铺到屏幕底、盖满宽度，且不拦点击', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final fade = find.byKey(kBottomNavFadeKey);
    expect(fade, findsOneWidget);

    final rect = tester.getRect(fade);
    expect(rect.left, 0);
    expect(rect.right, 360);
    expect(rect.bottom, 800);
    // 与列表留白同一口径：最后一行停下时正好在虚化带上沿之外。
    expect(rect.height, kBottomNavFadeHeight);

    // 只做视觉：命中的是导航本身，不是它下面那层。
    expect(fade.hitTestable(), findsNothing);

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await _pumpPages(tester);
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('虚化带比胶囊更糊、淡底色更浓', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final fade = find.byKey(kBottomNavFadeKey);
    final backdrop = tester.widget<BackdropFilter>(
      find.descendant(of: fade, matching: find.byType(BackdropFilter)),
    );
    // `ImageFilter.blur` 的实现类没有公开的 sigma getter，只能取运行时字段。
    final blur = backdrop.filter as dynamic;
    expect(blur.sigmaX, 22, reason: '虚化带要比胶囊（18）更糊');
    expect(blur.sigmaY, 22);

    final fill = tester.widget<DecoratedBox>(
      find.descendant(of: fade, matching: find.byType(DecoratedBox)),
    );
    final gradient = (fill.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(
      gradient.colors.first.a,
      closeTo(0.8, 0.001),
      reason: '底端淡底色：更浓，但留两成通透',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('有底部安全区时记录页列表仍铺到屏幕底，与我的页一致', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    // iPhone 的 Home 指示条区域：34pt。虚化带因此涨到 137 高，
    // 但列表视口必须仍铺到物理底边——否则虚化带最下那 34pt 没有内容可糊，
    // 看起来就像被截掉一条（记录页曾经的毛病）。
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);
    expect(
      tester
          .getRect(find.byKey(const PageStorageKey<String>('recordings-list')))
          .bottom,
      800,
      reason: '视口底边不该被 SafeArea 抬到安全区线（766）',
    );

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await _pumpPages(tester);
    final profileList = find.descendant(
      of: find.byType(ProfilePage),
      matching: find.byType(ListView),
    );
    expect(profileList, findsOneWidget);
    expect(tester.getRect(profileList).bottom, 800, reason: '两页同一口径');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切标签时选中底在项间流动，中途不跳变', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final capsule = tester.getRect(find.byKey(kBottomNavKey));
    final itemWidth =
        (capsule.width - 2 * kBottomNavContentInset) / NarrowTab.values.length;
    final agentLeft = capsule.left + kBottomNavItemInset;

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.call)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // 流动到一半：既不在起点，也还没到终点。
    final mid = tester.getRect(find.byKey(narrowTabBgKey(NarrowTab.call)));
    expect(mid.left, greaterThan(agentLeft + itemWidth * 0.5));
    expect(mid.left, lessThan(capsule.left + kBottomNavItemInset + 2 * itemWidth));

    await tester.pump(const Duration(milliseconds: 400));
    final settled = tester.getRect(find.byKey(narrowTabBgKey(NarrowTab.call)));
    expect(
      settled.left,
      closeTo(capsule.left + kBottomNavItemInset + 2 * itemWidth, 0.01),
      reason: '终点是「通话」那一格：胶囊内边距 1 + 项间缝 2',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('减弱动态效果时选中底直接跳变，不做回弹', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness(reduceMotion: true));
    await tester.pumpAndSettle();

    final capsule = tester.getRect(find.byKey(kBottomNavKey));
    final itemWidth =
        (capsule.width - 2 * kBottomNavContentInset) / NarrowTab.values.length;

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await tester.pump();

    expect(
      tester.getRect(find.byKey(narrowTabBgKey(NarrowTab.profile))).left,
      closeTo(capsule.left + kBottomNavItemInset + 4 * itemWidth, 0.01),
      reason: '单帧就该在目标位；有回弹动画时会停在半路',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏页头背后有顶部虚化带，高度贴合页头', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);

    final fade = find.byKey(kTopFadeKey);
    expect(fade, findsOneWidget);

    final rect = tester.getRect(fade);
    expect(rect.top, 0);
    expect(rect.height, kTopFadeHeight, reason: '页头 54 + 往下淡出的延伸段');
    // 页头那一段吸收点击：body 延伸之后，藏在页头底下的卡片不该被点到。
    expect(
      find.descendant(of: fade, matching: find.byType(AbsorbPointer)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录页内容铺到页头之后：列表顶边 0、首项让出页头', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);

    final scaffold = tester.widget<Scaffold>(
      find
          .descendant(
            of: find.byType(RecordingsPage),
            matching: find.byType(Scaffold),
          )
          .first,
    );
    expect(
      scaffold.extendBodyBehindAppBar,
      isTrue,
      reason: 'body 不延伸到页头后面，顶部虚化带就没有内容可糊',
    );

    final list = find.byKey(const PageStorageKey<String>('recordings-list'));
    expect(tester.getRect(list).top, 0, reason: '视口要铺到屏幕顶');
    expect(
      (tester.widget<ListView>(list).padding! as EdgeInsets).top,
      greaterThanOrEqualTo(kMobileTopBarMinHeight),
      reason: '首项仍要停在页头下方，不能被压住',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('「我的」页同样铺到页头之后，顶部带跟着切标签还在', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await _pumpPages(tester);

    final list = find
        .descendant(
          of: find.byType(ProfilePage),
          matching: find.byType(ListView),
        )
        .first;
    expect(tester.getRect(list).top, 0);
    expect(
      (tester.widget<ListView>(list).padding! as EdgeInsets).top,
      greaterThanOrEqualTo(kMobileTopBarMinHeight),
    );
    expect(find.byKey(kTopFadeKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('液态玻璃开关', () {
    tearDown(() => liquidGlassNavEnabled = kLiquidGlassNavDefault);

    testWidgets('打开后背板换成 GlassContainer，几何与选中底不变', (tester) async {
      liquidGlassNavEnabled = true;
      await _setSurface(tester, const Size(360, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // 页头按钮现在也走玻璃，计数不能全屏找：只认包着导航胶囊的那一层。
      // `kBottomNavKey` 在玻璃背板的 child 上，所以玻璃是它的祖先。
      expect(
        find.ancestor(
          of: find.byKey(kBottomNavKey),
          matching: find.byType(GlassContainer),
        ),
        findsOneWidget,
        reason: '开关打开时胶囊背板应交给液态玻璃',
      );

      final capsule = tester.getRect(find.byKey(kBottomNavKey));
      expect(capsule.height, kBottomNavHeight);
      expect(capsule.width, 360 - 2 * kBottomNavSideInset);

      // 选中底仍是 55 高、四周内缩 3：玻璃只换材质，不动几何。
      final bg = tester.getRect(find.byKey(narrowTabBgKey(NarrowTab.agent)));
      expect(bg.height, kBottomNavItemHeight);
      expect(bg.top - capsule.top, closeTo(kBottomNavItemInset, 0.01));
      expect(bg.left - capsule.left, closeTo(kBottomNavItemInset, 0.01));

      // 边缘由 shader 画，不再叠一层自绘高光。
      expect(find.byKey(kBottomNavGlassKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('胶囊边缘有玻璃高光层，且不拦点击', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final glass = find.byKey(kBottomNavGlassKey);
    expect(glass, findsOneWidget);
    expect(tester.widget<CustomPaint>(glass).painter, isA<NarrowTabGlassEdge>());
    expect(glass.hitTestable(), findsNothing, reason: '纯视觉，点击要落到标签上');
    expect(tester.takeException(), isNull);
  });
}
