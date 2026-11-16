import 'dart:io';

import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/design/app_theme_spec.dart';
import 'package:jarvis_app/src/core/recording/recording_models.dart';
import 'package:jarvis_app/src/core/recording/recording_providers.dart';
import 'package:jarvis_app/src/core/recording/recording_settings.dart';
import 'package:jarvis_app/src/core/recording/recording_store.dart';
import 'package:jarvis_app/src/features/recordings/recording_status_chip.dart';
import 'package:jarvis_app/src/features/recordings/recordings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePreferences extends RecordingPreferencesController {
  @override
  Future<RecordingPreferences> build() async =>
      const RecordingPreferences(uploadEnabled: false, disclosureSeen: true);

  @override
  Future<void> markDisclosureSeen() async {}

  @override
  Future<void> setUploadEnabled(bool enabled) async {}
}

LocalRecording _sample({bool uploaded = false}) => LocalRecording(
  clientId: 'rec_1',
  title: '周会',
  mode: RecordingMode.realtime,
  startedAt: DateTime(2026, 10, 28, 9, 30).millisecondsSinceEpoch,
  durationMs: 65_000,
  completed: true,
  segments: <LocalSegment>[
    LocalSegment(
      seq: 0,
      startMs: 0,
      endMs: 65_000,
      bytes: 2_080_044,
      uploaded: uploaded,
      text: '今天先对齐目标',
      state: uploaded ? SegmentState.ready : SegmentState.stored,
    ),
  ],
);

/// 同一天的多条录音：用来验证宽屏下同一行能并排几条。
LocalRecording _tile(int index) => LocalRecording(
  clientId: 'rec_$index',
  title: '录音 $index',
  mode: RecordingMode.realtime,
  startedAt: DateTime(2026, 10, 28, 9, 30 + index).millisecondsSinceEpoch,
  durationMs: 65_000,
  completed: true,
  segments: const <LocalSegment>[],
);

Widget _app({
  required RecordingsLibrary library,
  required RecordingStore store,
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: [
      recordingStoreProvider.overrideWith((ref) async => store),
      recordingPreferencesProvider.overrideWith(_FakePreferences.new),
      recordingInfoProvider.overrideWith((ref) async => RecordingInfo.unknown),
      recordingsLibraryProvider.overrideWith((ref) async => library),
    ],
    child: MaterialApp(theme: theme, home: const RecordingsPage()),
  );
}

/// 一条已经在服务端转写完成的录音：用来验证「已转写」标签的取色。
ServerRecording _readyServer() => ServerRecording(
  id: 'srv_1',
  clientRecordingId: 'rec_1',
  title: '周会',
  mode: RecordingMode.realtime,
  status: RecordingStatus.ready,
  durationMs: 65_000,
  bytes: 2_080_044,
  segmentCount: 1,
  readyCount: 1,
  preview: '今天先对齐目标',
  createdAt: DateTime(2026, 10, 28, 9, 30).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 28, 9, 35).millisecondsSinceEpoch,
);

void main() {
  late Directory root;
  late RecordingStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recordings-page-test');
    store = RecordingStore(root: root);
    await store.init();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets('没有录音时显示空态与两种模式入口', (tester) async {
    await tester.pumpWidget(
      _app(
        library: const RecordingsLibrary(local: [], server: []),
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有录音'), findsOneWidget);
    expect(find.text('实时记录'), findsOneWidget);
    // 模式卡与空态按钮都叫「录完再转」，出现两次是刻意的。
    expect(find.text('录完再转'), findsWidgets);
    expect(find.text('仅本地录音'), findsOneWidget);
  });

  testWidgets('本地待上传的录音出现在列表并标注状态', (tester) async {
    await tester.pumpWidget(
      _app(
        library: RecordingsLibrary(
          local: <LocalRecording>[_sample()],
          server: const [],
        ),
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('周会'), findsOneWidget);
    expect(find.text('今天先对齐目标'), findsOneWidget);
    // 上传开关关着：本地录音的准确状态是「仅本地」，不是「待上传」。
    expect(find.text('仅本地'), findsOneWidget);
    expect(find.text('还没有录音'), findsNothing);

    // 卡片有常驻浅底：与会话 / 任务列表的 Card 同一层，而不是透明贴底。
    final scheme = Theme.of(tester.element(find.text('周会'))).colorScheme;
    final card = find.ancestor(
      of: find.text('周会'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material &&
            widget.color == scheme.surfaceContainerLow,
      ),
    );
    expect(card, findsOneWidget);
  });

  testWidgets('模式入口始终一行，按钮按内容取宽而不是平铺整行', (tester) async {
    await tester.pumpWidget(
      _app(
        library: const RecordingsLibrary(local: [], server: []),
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    // 空态按钮也叫「录完再转」，只有模式入口那颗带 Tooltip（说明文字在里面）。
    final realtime = find.ancestor(
      of: find.text('实时转写'),
      matching: find.byType(Tooltip),
    );
    final batch = find.ancestor(
      of: find.text('录完再转'),
      matching: find.byType(Tooltip),
    );
    expect(realtime, findsOneWidget);
    expect(batch, findsOneWidget);

    final first = tester.getRect(realtime);
    final second = tester.getRect(batch);
    // 同一行、左右排开。
    expect(first.top, second.top);
    expect(second.left, greaterThan(first.right));
    // 正常按钮宽度：800 宽页面里远小于整行，也不是均分的一半。
    expect(first.width, lessThan(200));
  });

  testWidgets('宽窗口下同一天的录音并排列，窄窗口仍是单列', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        library: RecordingsLibrary(
          local: <LocalRecording>[_tile(0), _tile(1), _tile(2), _tile(3)],
          server: const [],
        ),
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    // 按时间倒序：3 / 2 / 1 在第一行，0 掉到第二行。
    final first = tester.getTopLeft(find.text('录音 3'));
    final second = tester.getTopLeft(find.text('录音 2'));
    final last = tester.getTopLeft(find.text('录音 0'));
    expect(second.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));
    expect(last.dy, greaterThan(first.dy));
  });

  testWidgets('390 宽的窄屏下录音仍是一列', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        library: RecordingsLibrary(
          local: <LocalRecording>[_tile(0), _tile(1)],
          server: const [],
        ),
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('录音 1'));
    final second = tester.getTopLeft(find.text('录音 0'));
    expect(second.dx, first.dx);
    expect(second.dy, greaterThan(first.dy));
  });

  group('强调元素跟随主题', () {
    test('状态映射：正常 / 进行中走 accent，异常保留黄与红', () {
      final palette = AppPalette.forBrightness(Brightness.light);

      expect(
        recordingStatusColor(RecordingStatus.ready, palette),
        palette.accent.projectStart,
        reason: '「已转写」不该固定成绿，跟随主题强调色',
      );
      expect(
        recordingStatusColor(RecordingStatus.transcribing, palette),
        palette.accent.projectStart,
        reason: '「转写中」同理，不再借 status.info',
      );
      expect(
        recordingStatusColor(RecordingStatus.recorded, palette),
        palette.status.warning,
      );
      expect(
        recordingStatusColor(RecordingStatus.partial, palette),
        palette.status.warning,
      );
      expect(
        recordingStatusColor(RecordingStatus.recording, palette),
        palette.status.danger,
      );
      expect(
        recordingStatusColor(RecordingStatus.failed, palette),
        palette.status.danger,
      );
    });

    testWidgets('模式入口与「已转写」标签取强调色，换 accent 后跟着变', (tester) async {
      Widget build(ThemeData? theme) => _app(
        library: RecordingsLibrary(
          local: const <LocalRecording>[],
          server: <ServerRecording>[_readyServer()],
        ),
        store: store,
        theme: theme,
      );

      await tester.pumpWidget(build(null));
      await tester.pumpAndSettle();

      final palette = AppPalette.of(tester.element(find.text('已转写')));
      for (final icon in <IconData>[
        Icons.multitrack_audio,
        Icons.library_music_outlined,
      ]) {
        expect(
          tester.widget<Icon>(find.byIcon(icon).first).color,
          palette.accent.projectStart,
          reason: '模式入口是装饰色，不能借 status.info / success',
        );
      }
      final chip = tester.widget<RecordingStatusChip>(
        find.byType(RecordingStatusChip),
      );
      expect(chip.label, '已转写');
      expect(chip.color, palette.accent.projectStart);

      // 主题包把强调色换成终端绿：同一批元素必须跟着变（这就是本轮修的问题）。
      const green = Color(0xFF6EEC47);
      await tester.pumpWidget(
        build(
          buildAppTheme(
            Brightness.light,
            colors: AppThemeColors(<String, Color>{
              'accent.project_start': green,
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.byIcon(Icons.multitrack_audio).first).color,
        green,
      );
      expect(
        tester.widget<RecordingStatusChip>(find.byType(RecordingStatusChip)).color,
        green,
      );
    });

    testWidgets('「仅本地」标签仍是中性灰，不被强调色吞掉', (tester) async {
      await tester.pumpWidget(
        _app(
          library: RecordingsLibrary(
            local: <LocalRecording>[_sample()],
            server: const [],
          ),
          store: store,
        ),
      );
      await tester.pumpAndSettle();

      final palette = AppPalette.of(tester.element(find.text('仅本地')));
      expect(
        tester.widget<RecordingStatusChip>(find.byType(RecordingStatusChip)).color,
        palette.status.neutral,
      );
    });
  });
}
