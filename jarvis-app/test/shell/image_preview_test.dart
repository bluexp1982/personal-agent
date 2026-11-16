import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/features/preview/image_preview_view.dart';
import 'package:jarvis_app/src/features/preview/pan_cursor_area.dart';
import 'package:jarvis_app/src/features/preview/preview_toolbar.dart';

import '../support/test_images.dart';

Widget _harness({required Uint8List bytes, String path = '/tmp/a.png'}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 600,
        child: ImagePreviewView(path: path, bytes: bytes),
      ),
    ),
  );
}

/// 从 `InteractiveViewer` 自己的控制器上读当前缩放：
/// 那是用户真正看到的比例，不是内部状态的副本。
double _scale(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(
    find.byType(InteractiveViewer),
  );
  return viewer.transformationController!.value.getMaxScaleOnAxis();
}

/// 当前生效的拖动光标。
MouseCursor _cursor(WidgetTester tester) =>
    tester.widget<MouseRegion>(find.byKey(kPreviewPanCursorKey)).cursor;

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('双击放大到 2.5 倍，再双击回到适应窗口', (tester) async {
    final bytes = testPngBytes;
    await tester.pumpWidget(_harness(bytes: bytes));
    await tester.pumpAndSettle();

    expect(_scale(tester), closeTo(1, 0.001));

    final center = tester.getCenter(find.byType(InteractiveViewer));
    await _doubleTap(tester, center);
    expect(_scale(tester), closeTo(2.5, 0.001));
    expect(find.text('250%'), findsOneWidget);

    await _doubleTap(tester, center);
    expect(_scale(tester), closeTo(1, 0.001));
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('放大/缩小按钮按固定梯度跳档，不按倍率连乘', (tester) async {
    await tester.pumpWidget(_harness(bytes: testPngBytes));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1, 0.001));

    await tester.tap(find.byKey(kPreviewZoomInKey));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1.25, 0.001));

    await tester.tap(find.byKey(kPreviewZoomInKey));
    await tester.pumpAndSettle();
    expect(
      _scale(tester),
      closeTo(1.5, 0.001),
      reason: '第二档仍应是 150%，而不是 1.25×1.25 的 156%',
    );

    await tester.tap(find.byKey(kPreviewZoomOutKey));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1.25, 0.001));

    await tester.tap(find.byKey(kPreviewZoomOutKey));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1.0, 0.001));
  });

  testWidgets('滚轮以指针为锚点缩放，底栏百分比跟着变', (tester) async {
    final bytes = testPngBytes;
    await tester.pumpWidget(_harness(bytes: bytes));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -160)));
    await tester.pumpAndSettle();

    expect(_scale(tester), greaterThan(1.05));
    expect(
      find.text('${(_scale(tester) * 100).round()}%'),
      findsOneWidget,
      reason: '底栏必须显示真实比例，而不是固定 100%',
    );

    // 「适应窗口」把视图复位，用户不用靠反复滚轮去猜原来的大小。
    await tester.tap(find.byKey(kPreviewFitKey));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1, 0.001));
  });

  testWidgets('放大后才出现抓手，按住时换成抓紧', (tester) async {
    await tester.pumpWidget(_harness(bytes: testPngBytes));
    await tester.pumpAndSettle();

    expect(
      _cursor(tester),
      MouseCursor.defer,
      reason: '适应窗口时内容拖不动，给抓手会让人以为能拖',
    );

    await _doubleTap(tester, tester.getCenter(find.byType(InteractiveViewer)));
    expect(_cursor(tester), SystemMouseCursors.grab);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(InteractiveViewer)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(
      _cursor(tester),
      SystemMouseCursors.grabbing,
      reason: '按住拖动期间必须是"抓紧"，松开才回到"抓手"',
    );

    await gesture.up();
    await tester.pump();
    expect(_cursor(tester), SystemMouseCursors.grab);

    // 双击识别器的倒计时还挂着：不把时间推完，测试结束时会报
    // "A Timer is still pending even after the widget tree was disposed"。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('适应窗口时拖不动，光标与可拖动性保持一致', (tester) async {
    await tester.pumpWidget(_harness(bytes: testPngBytes));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(60, 60));
    await tester.pump();

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final offset = viewer.transformationController!.value.getTranslation();
    expect(
      offset.x,
      closeTo(0, 0.001),
      reason: 'boundaryMargin 不许让 1× 的内容也能拖，否则会出现"图动了光标没变"',
    );
    expect(offset.y, closeTo(0, 0.001));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('真实指针下光标生效：悬停抓手、拖动抓紧', (tester) async {
    await tester.pumpWidget(_harness(bytes: testPngBytes));
    await tester.pumpAndSettle();
    await _doubleTap(tester, tester.getCenter(find.byType(InteractiveViewer)));

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(pointer.hover(center));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grab,
      reason: '悬停在可拖动的图上必须是抓手，不能只是 widget 属性对',
    );

    await tester.sendEventToBinding(pointer.down(center));
    await tester.sendEventToBinding(pointer.move(center + const Offset(8, 0)));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grabbing,
      reason: '拖动过程中系统光标要真的换成抓紧',
    );

    await tester.sendEventToBinding(pointer.up());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('换成另一份文件时视图复位', (tester) async {
    final bytes = testPngBytes;
    await tester.pumpWidget(_harness(bytes: bytes));
    await tester.pumpAndSettle();

    await _doubleTap(tester, tester.getCenter(find.byType(InteractiveViewer)));
    expect(_scale(tester), greaterThan(1.5));

    await tester.pumpWidget(_harness(bytes: bytes, path: '/tmp/b.png'));
    await tester.pumpAndSettle();

    expect(_scale(tester), closeTo(1, 0.001));
  });
}
