import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/artifact_exporter.dart';
import 'package:jarvis_app/src/core/media_save.dart';
import 'package:jarvis_app/src/core/media_cache.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/artifact_card.dart';
import 'package:jarvis_app/src/features/conversations/artifact_thumbnail.dart';
import 'package:jarvis_app/src/features/conversations/media_artifact_card.dart';

/// 现画一张真 PNG：缩略图要按真实比例撑开，1×1 的极小图量不出盒子。
Future<Uint8List> _makePng(int size) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

late Uint8List _png;

const MediaAsset _image = MediaAsset(
  id: 'img_1',
  kind: 'image',
  mime: 'image/png',
  bytes: 2883584,
  model: 'qwen-image-3.0',
  prompt: '一只橘猫',
  width: 1328,
  height: 1328,
);

const MediaAsset _wideImage = MediaAsset(
  id: 'img_2',
  kind: 'image',
  mime: 'image/png',
  bytes: 786432,
  model: 'qwen-image-3.0',
  prompt: '一片海',
  width: 1024,
  height: 768,
);

const MediaAsset _video = MediaAsset(
  id: 'vid_1',
  kind: 'video',
  mime: 'video/mp4',
  bytes: 5586591,
  model: 'wan3.0-video-prime',
  prompt: '海边日落',
  durationMs: 5000,
  resolution: '480P',
);

class _RecordingExporter implements ArtifactExporter {
  int saved = 0;
  final List<String> names = <String>[];

  @override
  Future<ExportResult> export({
    required String suggestedName,
    required List<int> bytes,
    required String mime,
    Rect? shareOrigin,
  }) async {
    saved += 1;
    names.add(suggestedName);
    return const ExportResult(ExportOutcome.saved, path: '/tmp/out.png');
  }
}

Widget _wrap(
  Widget child, {
  _RecordingExporter? exporter,
  ApiClient? client,
  Uint8List? poster,
}) {
  return ProviderScope(
    overrides: [
      // 默认不发网络请求：字节由用例注入。要验"自己取字节"的用例传 [client]。
      apiClientProvider.overrideWithValue(client),
      if (exporter != null) artifactExporterProvider.overrideWithValue(exporter),
      if (poster != null)
        mediaPosterProvider.overrideWith((ref, mediaId) => poster),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 420, child: child)),
      ),
    ),
  );
}

/// 让卡片自己按 id 去服务端取图：延迟 20ms 返回，好让用例先量到骨架那一帧。
ApiClient _mediaClient(Uint8List png) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.contains('/api/media/')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response.bytes(
        png,
        200,
        headers: <String, String>{'content-type': 'image/png'},
      );
    }
    return http.Response('{}', 404);
  });

  return ApiClient(
    baseUrl: 'http://127.0.0.1:8787',
    token: 'token-1',
    httpClient: client,
  );
}

/// 保存到项目成功：记下请求里的文件名，回一个项目内相对路径。
ApiClient _saveClient({List<String>? names}) {
  final client = MockClient((http.Request request) async {
    if (request.method == 'POST' && request.url.path.endsWith('/save')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      names?.add(body['name'] as String? ?? '');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'path': 'artifacts/${body['name']}',
          'bytes': 5,
        }),
        201,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404);
  });

  return ApiClient(
    baseUrl: 'http://127.0.0.1:8787',
    token: 'token-1',
    httpClient: client,
  );
}

/// 保存到项目撞名：服务端回 409 + 可执行提示。
ApiClient _conflictClient() {
  final client = MockClient((http.Request request) async {
    if (request.method == 'POST' && request.url.path.endsWith('/save')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'code': 'conflict',
          'message': 'target file exists',
          'retryable': false,
          'hint': '项目里已经有 artifacts/x.mp4，换个文件名再保存',
        }),
        409,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404);
  });

  return ApiClient(
    baseUrl: 'http://127.0.0.1:8787',
    token: 'token-1',
    httpClient: client,
  );
}

void main() {
  setUpAll(() async {
    _png = await _makePng(160);
  });

  group('缩略图', () {
    testWidgets('1:1 图：字节到达前后卡片尺寸逐像素不变', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MediaArtifactCard(asset: _image),
          client: _mediaClient(_png),
        ),
      );
      // 客户端延迟 20ms 才回：此刻量到的就是骨架。
      await tester.pump();
      expect(find.byType(Image), findsNothing, reason: '首帧还没拿到字节');
      final placeholder = tester.getSize(find.byType(MediaArtifactCard));
      final placeholderBox = tester.getSize(find.byType(ArtifactImageThumbnail));

      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(
        tester.getSize(find.byType(MediaArtifactCard)),
        placeholder,
        reason: '字节到达只换内容，卡片高度一变列表就会被顶起来',
      );
      expect(
        tester.getSize(find.byType(ArtifactImageThumbnail)),
        placeholderBox,
      );
      expect(placeholderBox.height, closeTo(kMediaImageMaxHeight, 0.01));
    });

    testWidgets('4:3 横图：按比例收进限高，不铺满列宽', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MediaArtifactCard(asset: _wideImage),
          client: _mediaClient(_png),
        ),
      );
      await tester.pump();
      final placeholder = tester.getSize(find.byType(MediaArtifactCard));
      final placeholderBox = tester.getSize(find.byType(ArtifactImageThumbnail));

      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(MediaArtifactCard)), placeholder);
      expect(
        tester.getSize(find.byType(ArtifactImageThumbnail)),
        placeholderBox,
      );
      expect(placeholderBox.height, closeTo(kMediaImageMaxHeight, 0.01));
      expect(
        placeholderBox.width / placeholderBox.height,
        closeTo(1024 / 768, 0.01),
      );
    });

    testWidgets('没有服务连接时缩略图给出可点重试的说明', (tester) async {
      await tester.pumpWidget(_wrap(const MediaArtifactCard(asset: _image)));
      await tester.pumpAndSettle();

      expect(find.textContaining('服务未连接'), findsOneWidget);
      expect(find.textContaining('点击重试'), findsOneWidget);
    });

    testWidgets('没有封面时给带播放标记的占位块', (tester) async {
      await tester.pumpWidget(_wrap(const MediaArtifactCard(asset: _video)));
      await tester.pumpAndSettle();

      expect(find.byType(ArtifactVideoThumbnail), findsOneWidget);
      expect(
        find.byType(Image),
        findsNothing,
        reason: '旧视频拿不到封面：不该为此下载整段视频',
      );
    });

    testWidgets('有封面时把第一帧画进缩略图', (tester) async {
      await tester.pumpWidget(
        _wrap(const MediaArtifactCard(asset: _video), poster: _png),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ArtifactVideoThumbnail), findsOneWidget);
      final cover = tester.widget<Image>(
        find.descendant(
          of: find.byType(ArtifactVideoThumbnail),
          matching: find.byType(Image),
        ),
      );
      expect(
        cover.fit,
        BoxFit.cover,
        reason: '封面要铺满 16:9 盒子，留白会让它看起来像破图',
      );
    });
  });

  group('卡片信息与动作', () {
    testWidgets('图片卡：标题、建议文件名、规格与两个动作', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MediaArtifactCard(
            asset: _image,
            initialBytes: _png,
            conversationTitle: '季度复盘',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('生成的图片'), findsOneWidget);
      expect(find.textContaining('季度复盘_generate_image_'), findsOneWidget);
      expect(find.textContaining('1328×1328'), findsOneWidget);
      expect(find.byKey(kMediaOpenKey), findsOneWidget);
      expect(find.byKey(kMediaSaveKey), findsOneWidget);
    });

    testWidgets('视频卡：型号、规格、提示词与占位图', (tester) async {
      await tester.pumpWidget(_wrap(const MediaArtifactCard(asset: _video)));
      await tester.pumpAndSettle();

      expect(find.text('生成的视频'), findsOneWidget);
      expect(find.textContaining('wan3.0-video-prime'), findsOneWidget);
      // 档位在占位图右下角与详情行各出现一次。
      expect(find.textContaining('480P'), findsWidgets);
      expect(find.textContaining('海边日落'), findsOneWidget);
    });

    testWidgets('保存靠左、打开靠右，打开图标三类产物共用一枚', (tester) async {
      await tester.pumpWidget(
        _wrap(const MediaArtifactCard(asset: _video, initialBytes: null)),
      );
      await tester.pumpAndSettle();

      final save = tester.getTopLeft(find.byKey(kMediaSaveKey));
      final open = tester.getTopLeft(find.byKey(kMediaOpenKey));
      expect(
        save.dx,
        lessThan(open.dx),
        reason: '右下角动作区的顺序是「保存、打开」，打开作为主操作收尾',
      );

      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(kMediaOpenKey),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, kArtifactOpenIcon);
    });

    testWidgets('点「打开」把资产交给外部，不自己 push 路由', (tester) async {
      final opened = <MediaAsset>[];

      await tester.pumpWidget(
        _wrap(
          MediaArtifactCard(
            asset: _video,
            initialBytes: _png,
            onOpen: opened.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaOpenKey));
      await tester.pumpAndSettle();

      expect(opened, <MediaAsset>[_video]);
      expect(
        find.byType(Scaffold),
        findsOneWidget,
        reason: '打开由会话页接到右栏，卡片不该再推一条全屏路由',
      );
    });

    testWidgets('没有打开回调时按钮置灰', (tester) async {
      await tester.pumpWidget(
        _wrap(MediaArtifactCard(asset: _video, initialBytes: _png)),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(kMediaOpenKey),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('保存', () {
    testWidgets('保存菜单给出项目与本机两个目标', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MediaArtifactCard(
            asset: _video,
            initialBytes: null,
            canSaveToProject: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();

      expect(find.text('保存到项目'), findsOneWidget);
      expect(find.text('保存到本地'), findsOneWidget);
    });

    testWidgets('菜单走全站通用组件，不是 Material 的 PopupMenu', (tester) async {
      await tester.pumpWidget(_wrap(const MediaArtifactCard(asset: _video)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();

      expect(
        find.byType(MenuItemButton),
        findsWidgets,
        reason: '通用菜单的行是 MenuItemButton（MenuAnchor 体系）',
      );
      expect(
        find.byType(PopupMenuItem<MediaSaveTarget>),
        findsNothing,
        reason: '保存菜单不该再弹一块 Material 默认样式的浮层',
      );
    });

    testWidgets('不归属项目时「保存到项目」置灰', (tester) async {
      await tester.pumpWidget(_wrap(const MediaArtifactCard(asset: _video)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();

      final item = tester.widget<MenuItemButton>(
        find.byKey(kMediaSaveProjectKey),
      );
      expect(
        item.onPressed,
        isNull,
        reason: '没有项目可落时不该给一个必然失败的选项',
      );
    });

    testWidgets('保存到本地：预填自动名，确认后交给导出器', (tester) async {
      final exporter = _RecordingExporter();

      await tester.pumpWidget(
        _wrap(
          const MediaArtifactCard(
            asset: _video,
            conversationTitle: '季度复盘',
          ),
          exporter: exporter,
          client: _mediaClient(_png),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller?.text,
        allOf(startsWith('季度复盘_generate_video_'), endsWith('.mp4')),
      );

      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(exporter.saved, 1);
      expect(exporter.names.single, startsWith('季度复盘_generate_video_'));
    });

    testWidgets('保存到项目：把确认后的名字发给服务端并在提示里给相对路径', (
      tester,
    ) async {
      final names = <String>[];

      await tester.pumpWidget(
        _wrap(
          MediaArtifactCard(
            asset: _video,
            initialBytes: _png,
            conversationTitle: '季度复盘',
            canSaveToProject: true,
          ),
          client: _saveClient(names: names),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到项目'));
      await tester.pumpAndSettle();

      // 手动改名：确认传下去的是用户写的那一份，不是自动名。
      await tester.enterText(find.byType(TextField), '海边日落.mp4');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(names, <String>['海边日落.mp4']);
      expect(
        find.textContaining('artifacts/海边日落.mp4'),
        findsOneWidget,
        reason: '提示里要给项目内相对路径，用户才知道存到哪儿了',
      );
    });

    testWidgets('重名等失败留在命名框里，不静默关闭', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MediaArtifactCard(
            asset: _video,
            initialBytes: _png,
            conversationTitle: '季度复盘',
            canSaveToProject: true,
          ),
          client: _conflictClient(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kMediaSaveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('换个文件名'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget, reason: '框应还开着');
    });
  });
}
