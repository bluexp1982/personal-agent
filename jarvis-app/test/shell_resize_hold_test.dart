import 'package:jarvis_app/src/features/shell/shell_resize_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只测拖动条自己的状态机：不接三栏、不接 Riverpod。
///
/// 整页用例要等布局与请求，这里一条 `startGesture` 就能把"越界 → 蓄力 →
/// 收起 → 回拉恢复"走完，失败时也更容易定位是哪一步错了。
Widget _harness({
  required ResizeDragResult Function(double dx) onDrag,
  required VoidCallback onHold,
  required VoidCallback onReopen,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          height: 240,
          child: ShellResizeHandle(
            onDrag: onDrag,
            onHold: onHold,
            onReopen: onReopen,
            // 左栏口径：向右拖是"拉回来"。
            reopenSign: 1,
            fillColor: const Color(0xFFEEEEEE),
            lineSide: ResizeHandleLineSide.trailing,
          ),
        ),
      ),
    ),
  );
}

/// 按下并拖到越界。首帧位移要超过触摸斜率，横向拖动才会被识别。
Future<TestGesture> _dragToLimit(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(ShellResizeHandle)),
  );
  await gesture.moveBy(const Offset(-40, 0));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('越界满半秒才收起，且只收起一次', (tester) async {
    var holds = 0;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => ResizeDragResult.atLimit,
        onHold: () => holds++,
        onReopen: () {},
      ),
    );

    final gesture = await _dragToLimit(tester);
    expect(holds, 0, reason: '刚越界不能立刻收起，否则又回到"手抖就没"');

    await tester.pump(const Duration(milliseconds: 300));
    expect(holds, 0, reason: '差一点到半秒也不收');

    await tester.pump(const Duration(milliseconds: 300));
    expect(holds, 1);

    // 同一手势里继续朝收起方向拖，不该再收一次。
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    expect(holds, 1);

    await gesture.up();
  });

  testWidgets('蓄力未满时松手，不收起', (tester) async {
    var holds = 0;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => ResizeDragResult.atLimit,
        onHold: () => holds++,
        onReopen: () {},
      ),
    );

    final gesture = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));

    expect(holds, 0, reason: '松手即终止本次蓄力');
  });

  testWidgets('拖回下限以内会清零蓄力进度', (tester) async {
    var holds = 0;
    var atLimit = true;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => atLimit ? ResizeDragResult.atLimit : ResizeDragResult.resizing,
        onHold: () => holds++,
        onReopen: () {},
      ),
    );

    final gesture = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 250));

    // 回到合法区间：进度作废，从这里重新计时。
    atLimit = false;
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(holds, 0, reason: '中途拖回来应该取消蓄力');
    await gesture.up();
  });

  testWidgets('收起后反向拖够 16dp 才恢复，且收起期间不再调 onDrag', (tester) async {
    var holds = 0;
    var reopens = 0;
    var drags = 0;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) {
          drags++;
          return ResizeDragResult.atLimit;
        },
        onHold: () => holds++,
        onReopen: () => reopens++,
      ),
    );

    final gesture = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(holds, 1);

    final dragsAtCollapse = drags;
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(drags, dragsAtCollapse, reason: '收起期间位移只用于回拉，不该再改宽度');

    // 不足死区：抖动不算"要拉回来"。
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(reopens, 0);

    // 越过死区：恢复。
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(reopens, 1);

    await gesture.up();
  });

  testWidgets('恢复之后可以再次蓄力收起', (tester) async {
    var holds = 0;
    var reopens = 0;
    var atLimit = true;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => atLimit ? ResizeDragResult.atLimit : ResizeDragResult.resizing,
        onHold: () => holds++,
        onReopen: () => reopens++,
      ),
    );

    final gesture = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(holds, 1);

    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(reopens, 1);

    // 同一次手势里再往回收一次。
    atLimit = true;
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(holds, 2);

    await gesture.up();
  });

  testWidgets('拖动期间整窗保底显示"可调宽"光标，松手才撤', (tester) async {
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => ResizeDragResult.atLimit,
        onHold: () {},
        onReopen: () {},
      ),
    );
    expect(find.byKey(kResizeCursorGuardKey), findsNothing);

    final gesture = await _dragToLimit(tester);
    expect(
      find.byKey(kResizeCursorGuardKey),
      findsOneWidget,
      reason: '一按下就要保住光标，指针随时可能离开 8dp 的窄缝',
    );
    expect(
      tester.widget<MouseRegion>(find.byKey(kResizeCursorGuardKey)).cursor,
      SystemMouseCursors.resizeColumn,
    );

    // 蓄力收起之后仍按着鼠标：光标不能掉回默认箭头，
    // 否则"反拖恢复"那一段看起来像操作已经结束了。
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(kResizeCursorGuardKey), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(find.byKey(kResizeCursorGuardKey), findsNothing);
  });

  testWidgets('每次重新按下都从头计时', (tester) async {
    var holds = 0;
    await tester.pumpWidget(
      _harness(
        onDrag: (_) => ResizeDragResult.atLimit,
        onHold: () => holds++,
        onReopen: () {},
      ),
    );

    // 第一次拖 300ms 后松手：不计入下一次。
    final first = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await first.up();
    await tester.pump();

    final second = await _dragToLimit(tester);
    await tester.pump(const Duration(milliseconds: 250));
    expect(holds, 0, reason: '上一次的 300ms 不能累计到这一次');

    await tester.pump(const Duration(milliseconds: 300));
    expect(holds, 1);
    await second.up();
  });
}
