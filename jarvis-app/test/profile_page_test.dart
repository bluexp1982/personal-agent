import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/canvas/canvas_demo_page.dart';
import 'package:jarvis_app/src/features/profile/profile_page.dart';
import 'package:jarvis_app/src/features/settings/settings_page.dart';
import 'package:jarvis_app/src/features/settings/settings_section_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

Widget _harness() {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: const MaterialApp(home: ProfilePage(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('「我的」：账户、记忆 → 无限画布 → 设置 的入口顺序', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsOneWidget);
    expect(find.text('Yao'), findsOneWidget);

    final memory = tester.getRect(find.text('记忆'));
    final canvas = tester.getRect(find.text('无限画布'));
    final settings = tester.getRect(find.text('设置'));

    expect(memory.top, lessThan(canvas.top), reason: '记忆在无限画布上面');
    expect(canvas.top, lessThan(settings.top), reason: '设置排在最后');
    // 一级标签页：没有返回钮。
    expect(find.byType(BackButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「设置」推入一级分类列表，返回回到「我的」', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('连接与设备'), findsOneWidget);
    expect(find.text('维护与关于'), findsOneWidget);
    expect(find.byType(ProfilePage), findsNothing);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置 → 某一栏是二级整页：页头带返回、内容是该栏', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSectionPage), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('连接与设备'), findsNothing, reason: '一级列表已被盖住');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSectionPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「无限画布」推入画布整页', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('无限画布'));
    // 画布里有常驻动效，`pumpAndSettle` 等不到静止；只把页间转场走完。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(CanvasDemoPage), findsOneWidget);
    expect(find.byType(ProfilePage), findsNothing);
    expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
