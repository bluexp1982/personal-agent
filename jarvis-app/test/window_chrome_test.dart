import 'package:jarvis_app/src/core/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用给定的平台跑一段测试，结束后立刻还原 `defaultTargetPlatform`。
///
/// 不能只靠 `addTearDown`：测试框架在**测试体结束**时就会校验
/// `debugDefaultTargetPlatformOverride` 是否已还原，tearDown 跑得太晚。
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

/// 把 [HiddenWindowTitleBarInset] 包一层给定的 `MediaQuery`，返回里面的 padding。
Future<EdgeInsets> _insetPadding(
  WidgetTester tester, {
  EdgeInsets initial = EdgeInsets.zero,
}) async {
  late EdgeInsets padding;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(padding: initial),
      child: HiddenWindowTitleBarInset(
        child: Builder(
          builder: (context) {
            padding = MediaQuery.of(context).padding;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return padding;
}

void main() {
  testWidgets('macOS 隐藏标题栏时补出红绿灯高度', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      expect(
        (await _insetPadding(tester)).top,
        kMacWindowButtonsHeight,
        reason: '没有系统安全区时也要把红绿灯那块让出来',
      );
    });
  });

  testWidgets('其他平台保持原样，不加顶部留白', (tester) async {
    // 测试默认平台是 android：窗口仍有系统标题栏，内容不需要额外让位。
    expect((await _insetPadding(tester)).top, 0);
  });

  testWidgets('引擎已上报更大的安全区时取较大值，不叠加', (tester) async {
    await _withPlatform(TargetPlatform.macOS, () async {
      expect(
        (await _insetPadding(
          tester,
          // 比 44 的标题栏再高一些：引擎已经算进去时不能叠加成两倍。
          initial: const EdgeInsets.only(top: 56),
        )).top,
        56,
      );
    });
  });
}
