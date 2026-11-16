import 'package:jarvis_app/src/features/conversations/approval_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个按钮：点一下走二次确认，把结果记下来。
Widget _harness(ValueChanged<bool> onResult) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onResult(await confirmFullAccess(context));
          },
          child: const Text('切换'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('完全放行必须二次确认，取消则不生效', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness((value) => result = value));

    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();

    expect(find.text('完全放行这个会话？'), findsOneWidget);
    expect(find.textContaining('合并回原分支前还会再问你一次'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('二次确认里点「完全放行」才返回 true', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness((value) => result = value));

    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('完全放行'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });
}
