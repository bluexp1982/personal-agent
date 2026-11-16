import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/features/ssh/ssh_connect_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连接表单是纯 widget（状态、回调全由外部传入），不碰 provider，
/// 所以这里直接摆一个未连接状态就能量布局。
Widget _harness(
  TextEditingController username,
  TextEditingController password,
) {
  return MaterialApp(
    home: Scaffold(
      body: SshConnectForm(
        state: const SshState.initial(),
        username: username,
        password: password,
        obscurePassword: true,
        rememberPassword: true,
        onToggleObscure: () {},
        onToggleRemember: (_) {},
        onConnect: () {},
        onCancel: () {},
        onRetryProbe: () {},
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

void main() {
  testWidgets('宽屏下连接表单限宽并水平居中', (tester) async {
    await _setSurface(tester, const Size(1200, 900));
    final username = TextEditingController();
    final password = TextEditingController();
    addTearDown(username.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_harness(username, password));
    await tester.pumpAndSettle();

    // 卡片最大 560，左右各 20 的外边距；输入框再减去左侧色条 4 与左右 16 的内边距。
    final field = tester.getRect(find.byType(TextField).first);
    expect(field.width, lessThanOrEqualTo(528), reason: '宽屏下表单不该横向拉满整块内容区');
    expect(
      field.center.dx,
      closeTo(600, 6),
      reason: '表单应该水平居中（左侧色条 4dp 会让中心偏 2dp）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏下表单仍然贴满内容区', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    final username = TextEditingController();
    final password = TextEditingController();
    addTearDown(username.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_harness(username, password));
    await tester.pumpAndSettle();

    // 360 - 20*2 外边距 - 4 色条 - 16*2 内边距 = 284，限宽不应在小屏上生效。
    expect(tester.getRect(find.byType(TextField).first).width, closeTo(284, 2));
    expect(tester.takeException(), isNull);
  });
}
