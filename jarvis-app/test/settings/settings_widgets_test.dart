import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/features/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置页四层字阶的守护测试。
///
/// 这一页曾经同时存在两套口径：`ListTile` 默认的 16 / 14（服务地址、设备名…）
/// 与模型 / 技能卡片手写的 14 / 11.5；标签又是 11.5 与 10.5 各一代。
/// 这里把「谁用哪一档」钉死，避免下次加一个设置项时又随手挑一个字号。
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(body: child),
  );
}

TextStyle? _styleOf(WidgetTester tester, String text) {
  return tester.widget<Text>(find.text(text)).style;
}

void main() {
  testWidgets('卡片头：标题 16 / w600，说明 11.5', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SettingsCardHeader(
          icon: Icons.palette_outlined,
          title: '主题',
          subtitle: SettingsDescription('跟随系统时随操作系统外观切换'),
        ),
      ),
    );

    final title = _styleOf(tester, '主题')!;
    expect(title.fontSize, AppFontSize.lg);
    expect(title.fontWeight, AppWeight.semiBold);

    final description = _styleOf(tester, '跟随系统时随操作系统外观切换')!;
    expect(description.fontSize, AppFontSize.sm);
    expect(description.height, AppLineHeight.normal);
  });

  testWidgets('条目行：标题 14 / w500，说明 11.5，值换成二级灰', (tester) async {
    await tester.pumpWidget(
      _harness(
        Column(
          children: <Widget>[
            SettingsRow(
              icon: Icons.psychology_outlined,
              title: '记忆',
              description: '画像、事件与授权',
              onTap: () {},
            ),
            SettingsRow(
              icon: Icons.dns_outlined,
              title: '服务地址',
              value: 'http://127.0.0.1:8788',
            ),
          ],
        ),
      ),
    );

    final title = _styleOf(tester, '记忆')!;
    expect(title.fontSize, AppFontSize.base);
    expect(title.fontWeight, AppWeight.medium);

    final description = _styleOf(tester, '画像、事件与授权')!;
    expect(description.fontSize, AppFontSize.sm);

    final palette = AppPalette.of(
      tester.element(find.text('服务地址')),
    );
    final value = _styleOf(tester, 'http://127.0.0.1:8788')!;
    expect(value.fontSize, AppFontSize.sm);
    expect(value.color, palette.text.secondary);

    // 可点的行自带右箭头：三处各写一枚的结果是大小与颜色都不一致。
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('标签：10.5 / w600，底与描边由状态色派生', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SettingsTag(label: '已保存', color: Color(0xFF166534)),
      ),
    );

    final palette = AppPalette.of(tester.element(find.text('已保存')));
    final style = _styleOf(tester, '已保存')!;
    expect(style.fontSize, AppFontSize.xs);
    expect(style.fontWeight, AppWeight.semiBold);
    expect(style.color, const Color(0xFF166534));

    final box = tester.widget<Container>(find.byType(Container).first);
    final decoration = box.decoration! as BoxDecoration;
    expect(
      decoration.color,
      palette.status.surfaceOf(const Color(0xFF166534)),
    );
    expect(
      (decoration.border! as Border).top.color,
      palette.status.borderOf(const Color(0xFF166534)),
    );
  });

  testWidgets('开关行是普通 SwitchListTile：不落 Cupertino 分支', (tester) async {
    await tester.pumpWidget(
      _harness(
        SettingsSwitchRow(
          icon: Icons.bolt_outlined,
          title: '打开终端时自动登录',
          description: '凭据已保存，打开终端时直接连接',
          value: true,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(_styleOf(tester, '打开终端时自动登录')!.fontSize, AppFontSize.base);
  });
}
