import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../call/call_page.dart';
import '../profile/profile_page.dart';
import '../projects/projects_page.dart';
import '../recordings/recordings_page.dart';
import 'messages_page.dart';
import 'narrow_tab_bar.dart';
import 'narrow_tab_icons.dart';

/// 底部导航胶囊的高度。
///
/// 按参考 App（千问）实测：原始截图 184px @3x = 61.3、缩略图 78px = 61.0，
/// 取 **61**。构成 = 选中底 55 + 上下各 3 的内缩（内容在其间居中，见
/// `narrow_tab_bar.dart` 的 `kBottomNavItemHeight`）。
const double kBottomNavHeight = 61;

/// 胶囊左右到窗口边缘的距离。
///
/// 按参考 App 截图实测（1170px @3x）：左上 57px / 右上 61px → 取 20。
/// 悬浮条不贴边，底下滚过的内容才看得出是"一层"。
const double kBottomNavSideInset = 20;

/// 胶囊底部到屏幕下边的距离。
///
/// 按参考 App 截图实测：下沿到屏幕底 65px → 22；比左右多 2pt 是参考 App
/// 自己的口径（不是笔误），照抄即可。
/// 不叠加 `MediaQuery.padding.bottom`——iPhone 的 Home 指示条在距底
/// 8~13pt，胶囊下沿 22pt 时本来就不与它重叠，再加一次 safeBottom 会把
/// 胶囊顶高约 34pt，出现"底部比左右宽一大截"的观感。
const double kBottomNavBottomGap = 22;

/// 导航从窗口底部占掉的高度（不含系统安全区）。
///
/// 浮层（录音状态条）抬到它上面；列表留白由 [kBottomNavListInset] 另算，
/// 不要混用。
const double kBottomNavClearance = kBottomNavHeight + kBottomNavBottomGap;

/// 标签页滚动内容末尾要补的留白。
///
/// 导航本身的高度 + 20 的呼吸：最后一行停在胶囊上方而不是被它压住，
/// 也不会因为留白过大而出现"列表到底了却还有半屏空白"。
const double kBottomNavListInset = kBottomNavClearance + 20;

/// 底部导航胶囊的 Key（测试用来定位"这一屏有没有导航"）。
const Key kBottomNavKey = Key('narrow-bottom-nav');

/// 单个标签的 Key。同一个标签在一屏里只有一个实例。
Key narrowTabKey(NarrowTab tab) => Key('narrow-tab-${tab.name}');

/// 单个标签「选中底」（那块浅色背景）的 Key。
///
/// 不复用 [narrowTabKey]：那个 Key 挂在整项（含水波纹与点击区，高度是胶囊
/// 内高），而尺寸回归要断言的是可见底块本身——高 55、四周内缩 3、全圆角。
///
/// 选中底是**一块流动的胶囊**：同一时刻只有当前项那个 Key 在树上，
/// 切换时它自己平移过去。别按"每项各有一块"来写断言。
Key narrowTabBgKey(NarrowTab tab) => Key('narrow-tab-bg-${tab.name}');

/// 窄屏的一级标签。
///
/// 顺序即导航顺序，也即 [IndexedStack] 的索引顺序——两处共用同一个枚举，
/// 不要在这里插值或另排一份列表。
enum NarrowTab {
  agent('智能体'),
  recordings('记录'),
  // 原型里的「实时通话」。功能未接入，页内目前是静态占位。
  call('通话'),
  messages('消息'),
  profile('我的');

  const NarrowTab(this.label);

  /// 胶囊里的文案。图标由 [narrowGlyphOf] 映射，两者写在同一个枚举里，
  /// 加标签时只改这一处。
  final String label;
}

/// 标签 → 自绘图形的映射。
///
/// 放在枚举旁边而不是胶囊组件里：加一个标签时，文案、顺序、图标三件事
/// 应该在同一屏里改完，散到两个文件里迟早会漏一处。
NarrowGlyph narrowGlyphOf(NarrowTab tab) {
  return switch (tab) {
    NarrowTab.agent => NarrowGlyph.agent,
    NarrowTab.recordings => NarrowGlyph.recordings,
    NarrowTab.call => NarrowGlyph.call,
    NarrowTab.messages => NarrowGlyph.messages,
    NarrowTab.profile => NarrowGlyph.profile,
  };
}

/// 当前窄屏标签。
///
/// 存进 Riverpod 而不是 `NarrowTabs` 的 State：窗口拉宽再拉窄时
/// `NarrowTabs` 会被卸载重建（宽窄是两套骨架），标签不该跟着回到 Agent。
final NotifierProvider<NarrowTabController, NarrowTab> narrowTabProvider =
    NotifierProvider<NarrowTabController, NarrowTab>(NarrowTabController.new);

class NarrowTabController extends Notifier<NarrowTab> {
  @override
  NarrowTab build() => NarrowTab.agent;

  /// 切到某个标签。点当前标签不重复写状态，避免无谓重建。
  void select(NarrowTab tab) {
    if (state != tab) {
      state = tab;
    }
  }
}

/// 窄屏标签容器：五个一级页常驻 + 底部悬浮导航。
///
/// 「通话」目前是静态占位页（见 `CallPage`）：标签位置按原型排在「记录」之后，
/// 但页内不启动麦克风、不计时。
///
/// 为什么不用嵌套 `Navigator`：详情页（项目详情、会话、录音详情、面板）都
/// push 到根 Navigator，整页一盖，导航自然不可见——这正是原型里
/// "详情页没有底部导航"的语义，不需要再加一层路由观察器。
///
/// 为什么用 `IndexedStack`：切标签要保留各页滚动位置、搜索词与未完成的输入。
/// 隐藏页仍在树上，代价是五页常驻布局；用 [_built] 做首访懒加载，
/// 免得用户没点过「记录」，那里的轮询定时器就先跑起来。
class NarrowTabs extends ConsumerStatefulWidget {
  const NarrowTabs({super.key, required this.session});

  /// 设置页要的服务端会话信息（设备名、服务地址、指纹）。
  final SessionState session;

  @override
  ConsumerState<NarrowTabs> createState() => _NarrowTabsState();
}

class _NarrowTabsState extends ConsumerState<NarrowTabs> {
  /// 已经访问过的标签。只增不减：离开再回来要拿回同一棵子树的状态。
  final Set<NarrowTab> _built = <NarrowTab>{};

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(narrowTabProvider);
    // 在 build 里记账而不是 setState：它只影响"这次要不要构造这一页"，
    // 不改任何对外状态，多一帧延迟反而会闪一次空页。
    _built.add(current);

    // 骨架（`HomeShell`）已经铺了这一屏的整窗渐变：四个标签页只把
    // Scaffold 置透明，不各自铺一层（见 `AppPageScaffold`）。
    return PageBackdropScope(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IndexedStack(
              index: current.index,
              children: <Widget>[
                for (final tab in NarrowTab.values)
                  if (_built.contains(tab))
                    _pageOf(tab)
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
          // 虚化带夹在内容与导航之间：滚到胶囊下方与两侧的内容先糊掉、再淡出。
          // 顺序不能反——放到导航之上会把胶囊自己也糊了。
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NarrowTabFade(),
          ),
          // 导航压在内容之上：列表从它下面滚过，胶囊才像"浮着的一层玻璃"。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NarrowTabBar(
              current: current,
              onSelect: (tab) =>
                  ref.read(narrowTabProvider.notifier).select(tab),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageOf(NarrowTab tab) {
    // 页头高 54：这四页的 body 铺到页头之后（`frostTop`），首项要让出这一段，
    // 页头背后那层虚化带才有内容可糊。外壳的 `SafeArea` 已经吃掉状态栏，
    // 所以这里只补工具条高度。
    const topInset = kMobileTopBarMinHeight;

    return switch (tab) {
      // 「新建项目」在页头右上角（见 `HomeShell` 的 `_Header`），不在这页里；
      // 它的页头由外壳画，内容不在页头之后，所以不传 topInset。
      NarrowTab.agent => const ProjectsPage(bottomInset: kBottomNavListInset),
      NarrowTab.recordings => const RecordingsPage(
        bottomInset: kBottomNavListInset,
        topInset: topInset,
      ),
      NarrowTab.call => const CallPage(
        bottomInset: kBottomNavListInset,
        topInset: topInset,
      ),
      // 空态整体上移导航那一截、下移页头那一截，视觉重心才落在可见区中间。
      NarrowTab.messages => const MessagesPage(
        bottomInset: kBottomNavListInset,
        topInset: topInset,
      ),
      // 设置已经降到「我的」的下一级（见 `ProfilePage`）：这一层只放账户与
      // 工具入口，底部导航停在这里，进设置 / 记忆 / 画布都是整页推入。
      NarrowTab.profile => ProfilePage(
        session: widget.session,
        bottomInset: kBottomNavListInset,
        topInset: topInset,
      ),
    };
  }
}


