import 'package:jarvis_app/src/core/app_info.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/app_dialog.dart';
import 'package:jarvis_app/src/features/settings/settings_dialog.dart';
import 'package:jarvis_app/src/features/settings/settings_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 一个只有「打开设置」按钮的宿主：弹窗自己就是被测对象。
///
/// 版本号走覆盖值：`PackageInfo` 是原生插件，widget 测试里没有实现。
Widget _harness() {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(null),
      appBuildInfoProvider.overrideWith(
        (ref) => const AppBuildInfo(version: '9.9.9', buildNumber: '42'),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showSettingsDialog(context, session: _session),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('宽屏弹窗：左栏五项、右栏默认「连接与设备」，左栏在内容左侧', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    expect(find.byKey(kSettingsDialogKey), findsOneWidget);
    for (final section in SettingsSection.values) {
      expect(
        find.byKey(settingsSectionItemKey(section)),
        findsOneWidget,
        reason: '左栏缺了「${section.title}」',
      );
    }

    expect(
      find.byKey(settingsSectionViewKey(SettingsSection.connection)),
      findsOneWidget,
      reason: '默认落在连接与设备',
    );
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('服务端指纹'), findsOneWidget);

    final nav = tester.getRect(
      find.byKey(settingsSectionItemKey(SettingsSection.connection)),
    );
    final content = tester.getRect(
      find.byKey(settingsSectionViewKey(SettingsSection.connection)),
    );
    expect(nav.right, lessThan(content.left), reason: '左边是内栏标题，右边是内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点左栏标题切换右栏内容，未访问过的栏不预先构建', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    // 「能力」栏里有模型 / 技能包两张会请求数据的卡：没点过就不该在树上。
    expect(
      find.byKey(
        settingsSectionViewKey(SettingsSection.capability),
        skipOffstage: false,
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(settingsSectionItemKey(SettingsSection.appearance)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(settingsSectionViewKey(SettingsSection.appearance)),
      findsOneWidget,
    );
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('服务地址'), findsNothing, reason: '换栏后旧内容不再出现在这一屏');

    // 切回连接：旧栏仍保留 State（只是 offstage），内容重新可见。
    await tester.tap(
      find.byKey(settingsSectionItemKey(SettingsSection.connection)),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('主题'), findsNothing);
    expect(
      find.byKey(
        settingsSectionViewKey(SettingsSection.appearance),
        skipOffstage: false,
      ),
      findsOneWidget,
      reason: '访问过的栏留在树上，切回来不重建',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭按钮与 Esc 都能收起浮层', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    await tester.tap(find.byKey(kSettingsDialogCloseKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kSettingsDialogKey), findsNothing);

    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(kSettingsDialogKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭钮的悬停底走栏头那套形状：圆角方形，圆角按 8:24 放大', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    final button = tester.widget<IconButton>(
      find.byKey(kSettingsDialogCloseKey),
    );
    expect(
      tester.getSize(find.byKey(kSettingsDialogCloseKey)),
      const Size(32, 32),
      reason: '20 号图标配 32 见方的底框，与栏头 24 / 14 的比例最接近',
    );

    final shape = button.style!.shape!.resolve(<WidgetState>{});
    expect(
      shape,
      isA<RoundedRectangleBorder>(),
      reason: 'M3 默认的 StadiumBorder 是正圆，与栏头那批图标钮不是一套',
    );
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(kAppDialogIconButtonRadius),
      reason: '栏头是 24 见方 / 8 圆角，这枚 32 见方同比例得到约 10.67',
    );
    // 标题字号走统一档：22 / w700。
    final title = tester.widget<Text>(find.text('设置').last);
    expect(title.style?.fontSize, AppFontSize.display);
    expect(title.style?.fontWeight, AppWeight.bold);

    // 颜色不在这里写：栏头按钮同样交给主题，两处才是真同一个悬停灰。
    expect(button.style!.overlayColor, isNull);
    expect(button.style!.backgroundColor, isNull);

    // 上边距与右边距取同一个算式：(行高 48 - 钮高 32) ÷ 2 = 8。
    final panel = tester.getRect(find.byKey(kSettingsDialogPanelKey));
    final close = tester.getRect(find.byKey(kSettingsDialogCloseKey));
    final topGap = close.top - panel.top;
    final rightGap = panel.right - close.right;
    expect(topGap, rightGap, reason: '上边距必须等于右边距');
    expect(topGap, 8);

    // 底色由 `AppDialog` 固定，五个弹窗同一份。
    final scheme = Theme.of(tester.element(find.byKey(kSettingsDialogPanelKey)))
        .colorScheme;
    expect(
      tester.widget<Dialog>(find.byKey(kSettingsDialogKey)).backgroundColor,
      scheme.surface,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点遮罩也能关闭', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    // 880 宽的浮层在 1200 里左边留 160：左上角落在遮罩上。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(kSettingsDialogKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「录音」栏不再有录音笔记跳转行', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    await tester.tap(
      find.byKey(settingsSectionItemKey(SettingsSection.recording)),
    );
    await tester.pumpAndSettle();

    expect(find.text('允许上传转写'), findsOneWidget);
    expect(find.text('音频去向'), findsOneWidget);
    expect(find.text('本地音频占用'), findsOneWidget);
    expect(find.text('录音笔记'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('客户端版本读安装包：显示版本号与构建号', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await _open(tester);

    await tester.tap(
      find.byKey(settingsSectionItemKey(SettingsSection.maintenance)),
    );
    await tester.pumpAndSettle();

    expect(find.text('客户端版本'), findsOneWidget);
    expect(find.text('9.9.9 (42)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口偏小时浮层跟着收缩，不溢出', (tester) async {
    await _setSurface(tester, const Size(760, 620));
    await tester.pumpWidget(_harness());
    await _open(tester);

    final rect = tester.getRect(find.byKey(kSettingsDialogPanelKey));
    expect(rect.width, 760 - 48);
    expect(rect.height, 620 - 80);
    expect(tester.takeException(), isNull);
  });
}
