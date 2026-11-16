import 'package:jarvis_app/src/core/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 「这一次点击落在标题栏空白区，还是落在栏头按钮上」——原生靠这条信息决定
// 要不要把连点当成"双击标题栏缩放"。这里只测 Flutter 侧上报得对不对。

const MethodChannel _windowChannel = MethodChannel('personal_agent/window');

/// 栏头里那枚"按钮"：形状不重要，重要的是它不在拖动区里。
const Key _buttonKey = Key('title-bar-test-button');

class _WindowChannelLog {
  final List<MethodCall> calls = <MethodCall>[];

  /// 最后一次 `titleBarClick` 的 `startedDrag`，没有则为 null。
  bool? get lastStartedDrag {
    for (final call in calls.reversed) {
      if (call.method != 'titleBarClick') {
        continue;
      }
      final arguments = call.arguments as Map<Object?, Object?>;
      return arguments['startedDrag'] as bool?;
    }
    return null;
  }

  bool get startedAnyDrag =>
      calls.any((call) => call.method == 'startDragging');
}

void _mockWindowChannel(_WindowChannelLog log) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_windowChannel, (MethodCall call) async {
    log.calls.add(call);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_windowChannel, null));
}

/// 在指定平台下跑用例。
///
/// 不能用 `addTearDown` 复位 `debugDefaultTargetPlatformOverride`：
/// binding 的兜底断言在 tearDown 之前跑，会判"测试改动了 foundation 调试变量"。
Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 一个根部报告器 + 一条拖动区 + 一枚普通按钮。
///
/// 顺序刻意是"报告器在外、拖动区在内"：Flutter 的指针事件从最深处往外派发，
/// 只有这个顺序下报告器才读得到拖动区刚写下的标记。
Widget _harness() {
  return MaterialApp(
    home: TitleBarClickReporter(
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(
              height: 40,
              child: WindowDragArea(child: SizedBox.expand()),
            ),
            SizedBox(
              height: 40,
              child: TextButton(
                key: _buttonKey,
                onPressed: () {},
                child: const Text('后退'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('空白拖动区：按下先开拖，再报 startedDrag: true', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      await tester.pumpWidget(_harness());
      await tester.tap(find.byType(WindowDragArea));
      await tester.pump();

      expect(log.startedAnyDrag, isTrue, reason: '空白区按下就该进入原生拖动');
      expect(log.lastStartedDrag, isTrue, reason: '这一次点击是标题栏空白，可以双击缩放');
    });
  });

  testWidgets('栏头按钮：不拖窗口，并且把标记从 true 复位成 false', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      await tester.pumpWidget(_harness());

      // 先点空白区把标记置成 true，再点按钮：不复位就会拿上一次的 true 去判双击。
      await tester.tap(find.byType(WindowDragArea));
      await tester.pump();
      expect(log.lastStartedDrag, isTrue);

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();

      expect(log.lastStartedDrag, isFalse, reason: '按钮上的点击不是标题栏空白');
    });
  });

  testWidgets('连按两次栏头按钮，两次都报 startedDrag: false', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      await tester.pumpWidget(_harness());

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();

      final clicks = log.calls
          .where((call) => call.method == 'titleBarClick')
          .toList(growable: false);
      expect(clicks, hasLength(2));
      for (final click in clicks) {
        final arguments = click.arguments as Map<Object?, Object?>;
        expect(
          arguments['startedDrag'],
          isFalse,
          reason: '连点后退不该被算成双击标题栏',
        );
      }
      expect(log.startedAnyDrag, isFalse);
    });
  });

  testWidgets('非 macOS 不上报：那边系统标题栏还在，不需要这套区分', (tester) async {
    await _withPlatform(TargetPlatform.linux, () async {
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      await tester.pumpWidget(_harness());
      // 非 macOS 上这块区域自己不带 Listener（正因如此才什么都报不出去），
      // 空白的 SizedBox 不参与命中，点它可能落空，关掉"未命中"告警。
      await tester.tap(find.byType(WindowDragArea), warnIfMissed: false);
      await tester.pump();

      expect(log.calls, isEmpty);
    });
  });
}
