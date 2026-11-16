import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/features/recordings/recordings_page.dart';
import 'package:jarvis_app/src/features/settings/settings_dialog.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 空服务端：动作行与账户菜单都不出网，骨架能渲染就够。
Widget _harness() {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openAccountMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(kRailAccountMenuKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('左栏顶部三行动作：新建 → 录音笔记 → 无限画布，同一套行样', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final newRow = tester.getRect(find.byKey(kRailNewConversationKey));
    final recordings = tester.getRect(find.byKey(kRailRecordingsKey));
    final canvas = tester.getRect(find.byKey(kRailCanvasKey));

    expect(newRow.top, greaterThanOrEqualTo(kPaneHeaderHeight));
    expect(
      recordings.top,
      greaterThanOrEqualTo(newRow.bottom),
      reason: '录音笔记排在新建会话下面',
    );
    expect(
      canvas.top,
      greaterThanOrEqualTo(recordings.bottom),
      reason: '无限画布排在录音笔记下面',
    );
    expect(recordings.left, newRow.left, reason: '两行左边缘对齐');
    expect(recordings.width, newRow.width, reason: '两行同宽');
    expect(recordings.height, newRow.height, reason: '两行同高');
    expect(canvas.left, recordings.left, reason: '三行左边缘对齐');
    expect(canvas.width, recordings.width, reason: '三行同宽');
    expect(canvas.height, recordings.height, reason: '三行同高');
    // 32 行高 + 上下各 2 的留白：与导航行的 pill 尺寸一致。
    expect(newRow.height, 36);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有项目时新建行仍可用：直接开一条无项目的对话', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 聊天不必挂在目录上：入口不再置灰，提示也从"先新建项目"换成开直聊。
    expect(find.byTooltip('新开一条无项目的对话'), findsOneWidget);

    // 空白服务端下点它不会真的发出请求（没有客户端），只确认这一行仍能点。
    await tester.tap(find.byKey(kRailNewConversationKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kRailRecordingsKey));
    // 录音页带着常驻的加载指示器，`pumpAndSettle` 会一直等不到静止。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RecordingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部账户入口按内容收窄，不平铺整栏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final account = tester.getRect(find.byKey(kRailAccountMenuKey));
    expect(account.left, closeTo(kPaneContentInset, 1), reason: '贴左栏内容线');
    expect(
      account.width,
      lessThan(kShellRailWidth - kPaneContentInset - kPaneEdgeInset),
      reason: '胶囊宽度由内容决定，不跟着栏宽铺满',
    );
    expect(account.height, 32, reason: '与输入栏的权限胶囊同高');
  });

  testWidgets('账户菜单：设置 → 记忆 → 分割线 → 退出登录，且向上弹出', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final trigger = tester.getRect(find.byKey(kRailAccountMenuKey));
    await _openAccountMenu(tester);

    final settings = tester.getRect(find.byKey(kRailAccountSettingsKey));
    final memory = tester.getRect(find.byKey(kRailAccountMemoryKey));
    final signOut = tester.getRect(find.byKey(kRailAccountSignOutKey));

    expect(
      settings.left,
      greaterThanOrEqualTo(trigger.left),
      reason: '菜单浮层与触发器左对齐，不会向左出头',
    );
    expect(settings.top, lessThan(trigger.top), reason: '底部菜单向上弹');
    expect(memory.top, greaterThan(settings.bottom), reason: '记忆在设置下面');
    expect(signOut.top, greaterThan(memory.bottom), reason: '退出登录排最后');
    expect(
      tester.widgetList(find.byType(AgentMenuDivider)),
      isNotEmpty,
      reason: '退出登录与上面两项之间有一条分割线',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('账户菜单里的设置弹出浮层', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await _openAccountMenu(tester);
    await tester.tap(find.byKey(kRailAccountSettingsKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kSettingsDialogKey), findsOneWidget);
    // 浮层盖在骨架之上：左栏与中栏都还在原位，只是被遮罩压住。
    expect(find.byType(RailNavigator), findsOneWidget);
  });

  testWidgets('退出登录是占位：只提示即将支持', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await _openAccountMenu(tester);
    await tester.tap(find.byKey(kRailAccountSignOutKey));
    await tester.pumpAndSettle();

    expect(find.text('退出登录即将支持'), findsOneWidget);
    // 账号与配对都没动：占位提示不能假装已经登出，也不该顺手打开设置浮层。
    expect(find.byKey(kSettingsDialogKey), findsNothing);
    expect(find.byType(RailNavigator), findsOneWidget);
  });
}
