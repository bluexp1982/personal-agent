import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/preview_source.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/file_artifact_card.dart';
import 'package:jarvis_app/src/features/conversations/media_artifact_card.dart';
import 'package:jarvis_app/src/features/preview/image_preview_view.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/panel_page.dart';

import '../support/test_images.dart';

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

/// 一条同时带图片产物与生成文件的消息：两条打开路径各验一次。
Map<String, dynamic> _message() => <String, dynamic>{
  'id': 'msg-1',
  'role': 'assistant',
  'content': '好了',
  'created_at': 1790000000000,
  'media': <dynamic>[
    <String, dynamic>{
      'id': 'img_1',
      'kind': 'image',
      'mime': 'image/png',
      'bytes': 2048,
      'model': 'qwen-image-3.0',
      'width': 8,
      'height': 8,
      'created_at': 1790000000000,
    },
  ],
  'file_writes': <dynamic>[
    <String, dynamic>{
      'request_id': 'fw_1',
      'path': 'notes.md',
      'scope': 'project',
      'status': 'written',
      'bytes': 128,
    },
  ],
};

/// 记录被请求过的路径：验证"没有走 /file-preview（网页通道）"。
class _Calls {
  final List<String> paths = <String>[];
}

Widget _harness(
  _Calls calls, {
  ChatPresentation presentation = ChatPresentation.docked,
  Size size = const Size(1200, 900),
}) {
  final client = MockClient((http.Request request) async {
    final path = request.url.path;
    calls.paths.add(path);

    if (path.endsWith('/messages')) {
      return _json(<String, dynamic>{
        'items': <dynamic>[_message()],
      });
    }
    if (path.contains('/api/media/')) {
      return http.Response.bytes(
        testPngBytes,
        200,
        headers: <String, String>{'content-type': 'image/png'},
      );
    }
    // 会话详情 / 文件树等其余请求：给一个最小可用的形状。
    return _json(<String, dynamic>{
      'id': 'conv-1',
      'project_id': 'p1',
      'title': '季度复盘',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
      'items': <dynamic>[],
    });
  });

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: ChatPage(
          conversationId: 'conv-1',
          title: '季度复盘',
          projectId: 'p1',
          canSaveMediaToProject: true,
          presentation: presentation,
        ),
      ),
    ),
  );
}

FilePaneTabState _tabsAt(WidgetTester tester, Finder anchor) {
  final container = ProviderScope.containerOf(tester.element(anchor));
  return container.read(filePaneTabProvider);
}

FilePaneTabState _tabs(WidgetTester tester) =>
    _tabsAt(tester, find.byType(ChatPage));

void main() {
  testWidgets('图片产物：打开只新增右栏预览标签，不 push 全屏路由', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_harness(calls));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(kMediaOpenKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kMediaOpenKey));
    await tester.pumpAndSettle();

    final state = _tabs(tester);
    expect(
      state.previews.map((preview) => preview.path),
      contains(PreviewSource.mediaTabId('img_1')),
    );
    final source = state.previewSourceOf(PreviewSource.mediaTabId('img_1'));
    expect(source?.conversationTitle, '季度复盘');
    expect(
      find.byType(ImagePreviewView),
      findsNothing,
      reason: '预览只在右栏里发生，不再压一条全屏路由',
    );
    expect(
      calls.paths.where((path) => path.contains('file-preview')),
      isEmpty,
      reason: '图片不是网页，不该走浏览器通道',
    );
  });

  testWidgets('生成文件：项目内非网页文件进预览标签，并带上会话的项目 id', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_harness(calls));
    await tester.pumpAndSettle();

    // 产物卡在长会话里会被顶到视口外，先滚到可见再点。
    await tester.ensureVisible(find.byKey(kFileOpenKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kFileOpenKey));
    await tester.pumpAndSettle();

    final state = _tabs(tester);
    expect(
      state.previews.map((preview) => preview.path),
      contains('notes.md'),
    );
    expect(
      state.previewSourceOf('notes.md')?.projectId,
      'p1',
      reason: '右栏不能靠当前 shell 目标猜项目：会话可能是从窄屏整页进来的',
    );
    expect(
      calls.paths.where((path) => path.contains('file-preview')),
      isEmpty,
      reason: 'markdown 不是网页，不该换预览站地址',
    );
  });

  testWidgets('窄屏：打开产物把整页面板推上来（同一套标签）', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _harness(
        calls,
        presentation: ChatPresentation.page,
        size: const Size(420, 900),
      ),
    );
    await tester.pumpAndSettle();

    // 窄屏下列表把产物卡挤到了视口外：先滚到可见再点，不然 tap 会落空。
    await tester.ensureVisible(find.byKey(kFileOpenKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kFileOpenKey));
    await tester.pumpAndSettle();

    expect(find.byType(PanelPage), findsOneWidget);
    // 会话页被新路由挡住后是 offstage：从面板侧读同一个容器。
    expect(
      _tabsAt(tester, find.byType(PanelPage)).previews.map((p) => p.path),
      contains('notes.md'),
    );
  });
}
