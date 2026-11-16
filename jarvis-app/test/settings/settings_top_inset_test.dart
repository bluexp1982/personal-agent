import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/app_page_scaffold.dart';
import 'package:jarvis_app/src/core/ui/mobile_top_bar.dart';
import 'package:jarvis_app/src/core/ui/top_bar_fade.dart';
import 'package:jarvis_app/src/features/settings/settings_page.dart';
import 'package:jarvis_app/src/features/settings/settings_section_page.dart';
import 'package:jarvis_app/src/features/settings/settings_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 状态栏高度取 44：iPhone 灵动岛机型的量级，足以让"漏算"与"算对了"区分开。
const double _statusBar = 44;

Widget _harness(Widget home) {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: MaterialApp(home: home),
  );
}

Future<void> _setSurface(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 把状态栏安全区加进 `MediaQuery`（`MediaQuery.padding` 由 view 派生）。
void _setStatusBar(WidgetTester tester) {
  tester.view.padding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.resetPadding);
}

void main() {
  testWidgets('一级列表：顶部留白 = 16 + 页头 54 + 状态栏，首项不压在页头下', (tester) async {
    await _setSurface(tester);
    _setStatusBar(tester);

    await tester.pumpWidget(
      _harness(
        const SettingsPage(session: _session, topInset: kMobileTopBarMinHeight),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      (list.padding! as EdgeInsets).top,
      16 + kMobileTopBarMinHeight + _statusBar,
      reason: 'push 上来的整页不在骨架 SafeArea 里，状态栏那一段要自己让出来',
    );

    // body 从窗口顶边开始（`extendBodyBehindAppBar`），页头下沿在 状态栏 + 54。
    final headerBottom = _statusBar + kMobileTopBarMinHeight;
    final groupTitle = find.descendant(
      of: find.byType(ListView),
      matching: find.text('设置'),
    );
    expect(tester.getRect(groupTitle).top, greaterThanOrEqualTo(headerBottom));
    expect(
      tester.getRect(find.byType(Card).first).top,
      greaterThanOrEqualTo(headerBottom),
      reason: '首张卡片不能钻进页头底下',
    );

    // 虚化带跟着页头走：压在状态栏上就既糊不到内容、又挡不住页头下沿的点击。
    final fade = tester.getRect(find.byKey(kTopFadeKey));
    expect(fade.top, _statusBar);
    expect(fade.height, kTopFadeHeight);
  });

  testWidgets('二级整页：顶部留白 = 16 + 页头 54 + 状态栏', (tester) async {
    await _setSurface(tester);
    _setStatusBar(tester);

    await tester.pumpWidget(
      _harness(
        const SettingsSectionPage(
          session: _session,
          section: SettingsSection.appearance,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final view = tester.widget<SettingsSectionView>(
      find.byType(SettingsSectionView),
    );
    expect(
      view.padding.top,
      16 + kMobileTopBarMinHeight + _statusBar,
      reason: '只让出 54 时，卡片首行会直接躺在「外观」标题上',
    );
    expect(
      tester.getRect(find.byType(SettingsSectionView)).top,
      0,
      reason: '前提：body 顶边就是窗口顶边，所以状态栏必须算进内容留白',
    );
    expect(tester.getRect(find.byKey(kTopFadeKey)).top, _statusBar);
  });

  testWidgets('没有状态栏时（桌面 / 外壳内复用）不多留一段', (tester) async {
    await _setSurface(tester);

    await tester.pumpWidget(
      _harness(
        const SettingsPage(session: _session, topInset: kMobileTopBarMinHeight),
      ),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect((list.padding! as EdgeInsets).top, 16 + kMobileTopBarMinHeight);
    expect(
      tester.getRect(find.byKey(kTopFadeKey)).top,
      0,
      reason: '贴着内容区顶边，与外壳内一级标签页一致',
    );
  });

  testWidgets('外壳内（PageBackdropScope）：虚化带仍贴内容区顶边', (tester) async {
    await _setSurface(tester);
    _setStatusBar(tester);

    await tester.pumpWidget(
      _harness(
        PageBackdropScope(
          // 模拟骨架：`SafeArea` 已经吃掉状态栏，页面看到的 padding.top 为 0。
          child: MediaQuery(
            data: const MediaQueryData(size: Size(360, 800)),
            child: const SettingsPage(
              session: _session,
              topInset: kMobileTopBarMinHeight,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(kTopFadeKey)).top,
      0,
      reason: '骨架内 body 已在 SafeArea 之后，带子不能再被状态栏推下去',
    );
  });
}
