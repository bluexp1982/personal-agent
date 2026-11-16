import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/features/preview/video_controls.dart';
import 'package:jarvis_app/src/features/preview/video_playback.dart';
import 'package:jarvis_app/src/features/preview/video_preview_view.dart';
import 'package:jarvis_app/src/features/preview/video_scrub_bar.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

import '../support/fake_video_playback.dart';
import '../support/test_images.dart';

Widget _harness(
  FakeVideoPlayback playback, {
  VoidCallback? onToggleFullscreen,
  VoidCallback? onOpenWithSystem,
  Uint8List? poster,
  bool immersive = false,
  double width = 640,
  double height = 420,
}) {
  return ProviderScope(
    overrides: [
      videoPlaybackFactoryProvider.overrideWithValue(() => playback),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: height,
          child: VideoPreviewView(
            path: '/tmp/clip.mp4',
            file: File('/tmp/clip.mp4'),
            poster: poster,
            onToggleFullscreen: onToggleFullscreen,
            onOpenWithSystem: onOpenWithSystem,
            immersive: immersive,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('打开文件后给出时长与播放按钮，点一下开始播', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    expect(playback.opens, 1, reason: '进查看器就该把文件交给播放器');
    expect(find.byKey(const Key('fake-surface')), findsOneWidget);
    expect(find.text('00:00 / 00:30'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.tap(find.byKey(kVideoPlayPauseKey));
    await tester.pumpAndSettle();

    expect(playback.playing, isTrue);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('拖动进度条把位置交给播放器', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(kVideoProgressKey),
      const Offset(120, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(playback.seeks, isNotEmpty, reason: '松手时应 seek');
    expect(playback.seeks.last, greaterThan(Duration.zero));
  });

  testWidgets('倍速菜单把倍速交给播放器', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kVideoSpeedKey));
    await tester.pumpAndSettle();

    // 走全站菜单组件：不再有系统 `PopupMenuButton` 那一套白底浮层。
    expect(find.byType(PopupMenuButton<double>), findsNothing);
    expect(find.byType(MenuItemButton), findsNWidgets(4));

    await tester.tap(find.text('1.5×').last);
    await tester.pumpAndSettle();

    expect(playback.speeds, <double>[1.5]);
  });

  testWidgets('底栏不再有全屏按钮，播停提示带上空格', (tester) async {
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(_harness(playback, onToggleFullscreen: () {}));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.open_in_full_rounded),
      findsNothing,
      reason: '全屏改由文件头、Esc 与双击画面承担，底栏不再放这枚按钮',
    );
    expect(find.byTooltip('播放（空格）'), findsOneWidget);
  });

  testWidgets('音量滑条随面板宽度在 120~160 之间取值', (tester) async {
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(_harness(playback, width: 640));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(kVideoVolumeKey)).width, 160);

    await tester.pumpWidget(_harness(playback, width: 464));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(kVideoVolumeKey)).width,
      120,
      reason: '刚好放得下时收到下限 120，不再继续挤进度条',
    );
  });

  testWidgets('面板窄到放不下音量条时只留静音键', (tester) async {
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(_harness(playback, width: 440));
    await tester.pumpAndSettle();

    expect(find.byKey(kVideoVolumeKey), findsNothing);
    expect(find.byKey(kVideoMuteKey), findsOneWidget);
  });

  testWidgets('打开预览就拿到焦点：不点画面，空格也能播停', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(playback.playing, isTrue);
  });

  testWidgets('空格暂停 / 继续播放', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    // 点画面既播停，也把键盘焦点要过来：此后空格才有落点。
    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isFalse, reason: '播放中按空格应暂停');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue, reason: '暂停中按空格应继续播放');
  });

  testWidgets('播放结束后按空格从头重播', (tester) async {
    final playback = FakeVideoPlayback()..completed = true;
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pumpAndSettle();
    // 上面这一下已经走过一次「从头重播」，清掉计数只验证空格那一遍。
    playback.seeks.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(playback.seeks, <Duration>[Duration.zero]);
    expect(playback.playing, isTrue);
  });

  testWidgets('焦点在输入框时空格照常是空格，不触发播放', (tester) async {
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoPlaybackFactoryProvider.overrideWithValue(() => playback),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                SizedBox(
                  width: 640,
                  height: 320,
                  child: VideoPreviewView(
                    path: '/tmp/clip.mp4',
                    file: File('/tmp/clip.mp4'),
                  ),
                ),
                const TextField(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(
      playback.playing,
      isFalse,
      reason: '右栏常与输入框同屏，全局吃空格会把用户的空格吞掉',
    );
  });

  testWidgets('双击画面切换全屏，且不顺带改播放状态', (tester) async {
    final playback = FakeVideoPlayback();
    var toggles = 0;

    await tester.pumpWidget(
      _harness(playback, onToggleFullscreen: () => toggles += 1),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pumpAndSettle();

    expect(toggles, 1, reason: '双击是进 / 出全屏的那一下');
    expect(playback.playing, isFalse, reason: '双击不该顺带播停');
  });

  testWidgets('挂了双击之后，单击仍只播停一次', (tester) async {
    final playback = FakeVideoPlayback();
    var toggles = 0;

    await tester.pumpWidget(
      _harness(playback, onToggleFullscreen: () => toggles += 1),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fake-surface')));
    // 等过双击判定窗：单击要等这 300ms 才落地。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(playback.playing, isTrue);
    expect(toggles, 0);
  });

  testWidgets('沉浸态收起整条底栏，只留铺满宽度的细进度条', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    for (final key in <Key>[
      kVideoPlayPauseKey,
      kVideoProgressKey,
      kVideoMuteKey,
      kVideoVolumeKey,
      kVideoSpeedKey,
    ]) {
      expect(find.byKey(key), findsNothing, reason: '满屏时整条底栏不该再占画面');
    }

    final bar = find.byKey(kVideoScrubKey);
    expect(bar, findsOneWidget);
    expect(
      tester.getSize(bar),
      const Size(640, kVideoScrubHitHeight),
      reason: '细线铺满宽度，命中区 12 高',
    );
    expect(tester.getRect(bar).bottom, 420, reason: '贴着画面下沿');

    // 底栏没了，空格是仅剩的播停入口之一。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue);
  });

  testWidgets('沉浸态点一下细进度条就定位到那一刻', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    await tester.tapAt(tester.getCenter(find.byKey(kVideoScrubKey)));
    await tester.pumpAndSettle();

    expect(playback.seeks, hasLength(1));
    expect(
      playback.seeks.single.inMilliseconds,
      closeTo(15000, 50),
      reason: '点在中间 = 30 秒的一半',
    );
  });

  testWidgets('沉浸态拖动细进度条，松手才 seek', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kVideoScrubKey)),
    );
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();

    expect(playback.seeks, isEmpty, reason: '拖动期间只动本地值，别与位置回流打架');

    await gesture.up();
    await tester.pumpAndSettle();

    expect(playback.seeks, hasLength(1));
    expect(playback.seeks.single, greaterThan(const Duration(seconds: 15)));
  });

  testWidgets('沉浸态暂停时右端显示当前 / 总时长，字号取最小档', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    final time = find.byKey(kVideoScrubTimeKey);
    expect(time, findsOneWidget);

    final text = tester.widget<Text>(time);
    expect(text.data, '00:00 / 00:30');
    expect(text.style?.fontSize, AppFontSize.xs);

    // 贴着右内边距、压在 12dp 命中带之上：不与线条重叠，也不拦点击。
    final rect = tester.getRect(time);
    expect(rect.right, 640 - kPaneContentInset);
    expect(rect.bottom, lessThanOrEqualTo(420 - kVideoScrubHitHeight));
  });

  testWidgets('沉浸态播放中隐藏时间，悬停 / 暂停时才出现', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue);

    expect(
      find.byKey(kVideoScrubTimeKey),
      findsNothing,
      reason: '播放时只留进度条，角落里不常驻数字',
    );
    expect(find.byKey(kVideoScrubKey), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(kVideoScrubKey)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(kVideoScrubTimeKey),
      findsOneWidget,
      reason: '播放中悬停也要能看到时间',
    );

    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(kVideoScrubTimeKey), findsNothing, reason: '移开就收回去');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isFalse);
    expect(find.byKey(kVideoScrubTimeKey), findsOneWidget, reason: '暂停要能看到进度');
  });

  testWidgets('沉浸态播放中拖动仍显示时间并跟手', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue);
    expect(find.byKey(kVideoScrubTimeKey), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kVideoScrubKey)),
    );
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();

    expect(
      find.byKey(kVideoScrubTimeKey),
      findsOneWidget,
      reason: '拖动是"正在看进度"，数字必须跟手',
    );
    expect(
      tester.widget<Text>(find.byKey(kVideoScrubTimeKey)).data,
      startsWith('00:2'),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    // 松手后仍在播放：时间重新收起。
    expect(find.byKey(kVideoScrubTimeKey), findsNothing);
  });

  testWidgets('沉浸态暂停与悬停同一档亮度，播放中更淡', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    Color trackColor() =>
        (tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: find.byKey(kVideoScrubKey),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color!;
    Color playedColor() => tester
        .widget<ColoredBox>(
          find.descendant(
            of: find.byKey(kVideoScrubKey),
            matching: find.byType(ColoredBox),
          ),
        )
        .color;
    Color timeColor() =>
        tester.widget<Text>(find.byKey(kVideoScrubTimeKey)).style!.color!;

    // 暂停（未悬停）：直接按悬停档显示——暂停就是要看进度。
    expect(trackColor().a, closeTo(0.06, 0.001));
    expect(playedColor().a, closeTo(0.24, 0.001));
    expect(timeColor().a, closeTo(0.24, 0.001));
    expect(timeColor(), playedColor(), reason: '时间是进度条的一部分，与已播段同色');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    // 播放中（未悬停）：压到最淡档。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(playback.playing, isTrue);
    expect(trackColor().a, closeTo(0.03, 0.001));
    expect(playedColor().a, closeTo(0.12, 0.001));

    // 播放中悬停：回到与暂停相同的那一档。
    await mouse.moveTo(tester.getCenter(find.byKey(kVideoScrubKey)));
    await tester.pumpAndSettle();
    expect(trackColor().a, closeTo(0.06, 0.001));
    expect(playedColor().a, closeTo(0.24, 0.001));
    expect(timeColor(), playedColor(), reason: '悬停时时间也不能比进度条亮');

    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(trackColor().a, closeTo(0.03, 0.001), reason: '移开后回到最淡态');
  });

  testWidgets('沉浸态拖动时右端时间跟着走', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kVideoScrubKey)),
    );
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();

    final text = tester.widget<Text>(find.byKey(kVideoScrubTimeKey)).data!;
    expect(text, isNot('00:00 / 00:30'), reason: '拖动期间数字要跟手');
    expect(text, startsWith('00:2'), reason: '拖到约四分之三处 = 22 秒上下');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(playback.seeks, hasLength(1));
  });

  testWidgets('切换沉浸态不重建播放器', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_harness(playback, immersive: true));
    await tester.pumpAndSettle();

    expect(playback.opens, 1, reason: '同一份播放器继续用，不能从头重开');
    expect(playback.disposed, isFalse);
    expect(find.byKey(kVideoScrubKey), findsOneWidget);
  });

  testWidgets('没有全屏回调时双击不响应', (tester) async {
    final playback = FakeVideoPlayback();

    // 满屏路由：宿主没有全屏语义，双击识别器压根不挂，单击零延迟生效。
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const Key('fake-surface')));
    await tester.pumpAndSettle();

    // 两下独立单击：播 → 停。
    expect(playback.playing, isFalse);
  });

  testWidgets('解码失败显示原因，并保留系统打开兜底', (tester) async {
    final playback = FakeVideoPlayback(errorOnOpen: 'Failed to open file');
    var opened = 0;

    await tester.pumpWidget(
      _harness(playback, onOpenWithSystem: () => opened += 1),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to open file'), findsOneWidget);
    await tester.tap(find.text('用系统应用打开'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('有封面时起播前铺封面，开始播放后撤掉', (tester) async {
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(_harness(playback, poster: testPngBytes));
    await tester.pumpAndSettle();

    expect(find.byKey(kVideoPosterKey), findsOneWidget);

    await tester.tap(find.byKey(kVideoPlayPauseKey));
    await tester.pumpAndSettle();

    expect(
      find.byKey(kVideoPosterKey),
      findsNothing,
      reason: '播起来之后封面就该让位给画面，不能一直盖在上面',
    );
  });

  testWidgets('没有封面时保持原来的黑底', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_harness(playback));
    await tester.pumpAndSettle();

    expect(find.byKey(kVideoPosterKey), findsNothing);
  });

  testWidgets('换文件会重建播放器并释放旧的', (tester) async {
    final first = FakeVideoPlayback();
    final second = FakeVideoPlayback();
    final queue = <FakeVideoPlayback>[first, second];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoPlaybackFactoryProvider.overrideWithValue(() => queue.removeAt(0)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 420,
              child: VideoPreviewView(
                path: '/tmp/a.mp4',
                file: File('/tmp/a.mp4'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(first.opens, 1);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoPlaybackFactoryProvider.overrideWithValue(
            () => queue.removeAt(0),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 420,
              child: VideoPreviewView(
                path: '/tmp/b.mp4',
                file: File('/tmp/b.mp4'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 新 Widget 树 → 旧 State 直接 dispose，等价于"关掉再看另一份"。
    expect(first.disposed, isTrue);
    expect(second.opens, 1);
  });
}
