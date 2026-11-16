import 'package:jarvis_app/src/features/pairing/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return ProviderScope(child: MaterialApp(home: child));
}

void main() {
  testWidgets('配对页展示地址、设备名与配对码输入', (tester) async {
    await tester.pumpWidget(
      _wrap(const PairingPage(initialServerUrl: 'http://127.0.0.1:8787')),
    );
    await tester.pumpAndSettle();

    expect(find.text('连接你的机器'), findsOneWidget);
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('配对码'), findsOneWidget);
    expect(find.text('开始配对'), findsOneWidget);
    // 默认值来自传入的服务地址（占位提示与输入值同文案，因此至少出现一次）
    expect(find.text('http://127.0.0.1:8787'), findsWidgets);
  });

  testWidgets('配对码不足 12 位时拒绝提交', (tester) async {
    await tester.pumpWidget(
      _wrap(const PairingPage(initialServerUrl: 'http://127.0.0.1:8787')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '配对码'), 'ABC');
    await tester.tap(find.text('开始配对'));
    await tester.pumpAndSettle();

    expect(find.text('配对码是 12 位字母数字（连字符可省略）'), findsOneWidget);
  });

  testWidgets('带分组连字符的配对码通过校验', (tester) async {
    await tester.pumpWidget(
      _wrap(const PairingPage(initialServerUrl: 'http://127.0.0.1:8787')),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, '配对码'),
    );

    // 与服务端终端输出一致的形式，不应被判成"位数不对"
    expect(field.validator?.call('77JJ-VQ3F-2YZK'), isNull);
    expect(field.validator?.call('77jj-vq3f-2yzk'), isNull);
    expect(field.validator?.call('77JJVQ3F2YZK'), isNull);
    // 多一位、少一位仍然拒绝
    expect(field.validator?.call('77JJ-VQ3F-2YZK-XX'), isNotNull);
    expect(field.validator?.call('ABC'), isNotNull);
  });

  testWidgets('粘贴终端里的分组配对码可直接使用', (tester) async {
    await tester.pumpWidget(
      _wrap(const PairingPage(initialServerUrl: 'http://127.0.0.1:8787')),
    );
    await tester.pumpAndSettle();

    final codeField = find.widgetWithText(TextFormField, '配对码');

    // 带连字符粘贴：原样保留
    await tester.enterText(codeField, 'FGDS-DE77-XUAQ');
    await tester.pump();
    expect(find.text('FGDS-DE77-XUAQ'), findsOneWidget);

    // 小写、不带分隔符粘贴：自动大写并按 4 位分组
    await tester.enterText(codeField, 'fgdsde77xuaq');
    await tester.pump();
    expect(find.text('FGDS-DE77-XUAQ'), findsOneWidget);

    // 多粘贴一位会被截掉，不会变成 13 位
    await tester.enterText(codeField, 'FGDS-DE77-XUAQ-XX');
    await tester.pump();
    expect(find.text('FGDS-DE77-XUAQ'), findsOneWidget);
  });
}
