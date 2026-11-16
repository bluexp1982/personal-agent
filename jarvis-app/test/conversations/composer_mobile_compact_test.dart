import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer_area.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/composer_context_ring.dart';
import 'package:jarvis_app/src/features/conversations/composer_menus.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:jarvis_app/src/features/conversations/new_session_stage.dart';

/// 手机窄屏的输入栏形态：
///
/// - 无焦点、无草稿时收成一行（「+」/ 输入框 / 发送），权限与模型胶囊让位；
/// - 聚焦或已有草稿时恢复完整输入栏；
/// - 窄屏不挂运行统计行，空会话直接贴底（不走居中舞台）；
/// - 点消息区 / 空白处收键盘，面板随焦点一起收回一行。
///
/// 平台用 `debugDefaultTargetPlatformOverride` 切到 iOS：折叠只对移动端生效，
/// macOS 宿主上跑测试时默认是桌面，不切平台根本走不到这条分支。
///
/// 面板高度的常量写的是"内容 + 内边距"，实际矩形还要加 `Border.all(1)` 的上下
/// 各 1dp，所以断言用 `closeTo(..., 2)`——`chat_window_test` 也是这个口径。
const Size _phone = Size(390, 844);

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

Map<String, dynamic> _conversation() => <String, dynamic>{
  'id': 'conv-1',
  'project_id': 'w1',
  'title': '新会话',
  'mode': 'text',
  'archived': false,
  'created_at': 0,
  'updated_at': 0,
};

Map<String, dynamic> _message(int index) => <String, dynamic>{
  'id': 'msg-$index',
  'role': index.isEven ? 'user' : 'assistant',
  'content': '第 $index 条消息',
  'created_at': 1790000000000 + index * 1000,
  // 有历史都当成"已经聊过一轮"：上下文环靠这份 usage 才出现。
  if (index.isOdd)
    'usage': <String, dynamic>{
      'prompt_tokens': 17000,
      'completion_tokens': 500,
      'tokens_estimated': false,
      'context_tokens': 16800,
    },
};

/// 会话页 harness。[withHistory] 为 true 时返回两条历史，好让贴底分支
/// （带运行统计行的那一条）被走到；空会话走的是另一条。
Widget _pageHarness({required bool withHistory}) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      return _json(<String, dynamic>{
        'items': <dynamic>[
          if (withHistory) ...[_message(0), _message(1)],
        ],
      });
    }
    return _json(_conversation());
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
      atSkillsProvider.overrideWith((ref) async => const <SkillInfo>[]),
    ],
    child: const MaterialApp(
      home: ChatPage(conversationId: 'conv-1', title: '新会话'),
    ),
  );
}

/// 打开页面并等历史请求落地。
///
/// 不用 `pumpAndSettle`：加载态有一个常转的进度环，settle 会一直等下去。
Future<void> _openPage(
  WidgetTester tester, {
  required Size size,
  bool withHistory = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_pageHarness(withHistory: withHistory));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

double _panelHeight(WidgetTester tester) =>
    tester.getRect(find.byKey(kChatComposerPanelKey)).height;

Widget _composerHarness(QuillController controller, {required bool compact}) {
  return ProviderScope(
    overrides: [
      atSkillsProvider.overrideWith((ref) async => const <SkillInfo>[]),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ChatComposer(
              controller: controller,
              sending: false,
              onSend: () {},
              onStop: () {},
              compactWhenIdle: compact,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ChatComposer 折叠态', () {
    testWidgets('空闲时只剩「+」/ 输入框 / 发送，三者同一行', (tester) async {
      final controller = QuillController.basic();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_composerHarness(controller, compact: true));

      expect(_panelHeight(tester), closeTo(kChatComposerCompactHeight, 2));
      expect(find.byKey(kComposerAttachButtonKey), findsOneWidget);
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(
        find.byKey(kComposerPermissionMenuKey),
        findsNothing,
        reason: '折叠态没有第二行，两枚胶囊会让位',
      );
      expect(find.byKey(kComposerModelMenuKey), findsNothing);

      // 同一行：「+」在左、发送在右，输入框居中撑满。
      final attach = tester.getRect(find.byKey(kComposerAttachButtonKey));
      final send = tester.getRect(find.byTooltip('发送'));
      expect(attach.right, lessThan(send.left));
      expect(
        tester.getCenter(find.byKey(kComposerAttachButtonKey)).dy,
        closeTo(tester.getCenter(find.byTooltip('发送')).dy, 1),
        reason: '三个控件要在同一条水平线上',
      );
    });

    testWidgets('聚焦后展开成完整输入栏', (tester) async {
      final controller = QuillController.basic();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_composerHarness(controller, compact: true));
      await tester.tap(find.byType(QuillEditor));
      await tester.pump();

      expect(_panelHeight(tester), closeTo(kChatComposerMinHeight, 2));
      expect(find.byKey(kComposerPermissionMenuKey), findsOneWidget);
      expect(find.byKey(kComposerModelMenuKey), findsOneWidget);
    });

    testWidgets('有草稿时失焦仍展开，删空并失焦后收回一行', (tester) async {
      final controller = QuillController.basic();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_composerHarness(controller, compact: true));
      await tester.tap(find.byType(QuillEditor));
      await tester.pump();

      setComposerText(controller, '写点东西');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(
        _panelHeight(tester),
        closeTo(kChatComposerMinHeight, 2),
        reason: '有草稿时收键盘不该把内容藏进一行里',
      );

      clearComposer(controller);
      await tester.pump();
      expect(
        _panelHeight(tester),
        closeTo(kChatComposerCompactHeight, 2),
        reason: '草稿删空且没有焦点，就该收回一行',
      );
    });

    testWidgets('不传 compactWhenIdle 时保持完整输入栏', (tester) async {
      final controller = QuillController.basic();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_composerHarness(controller, compact: false));

      expect(_panelHeight(tester), closeTo(kChatComposerMinHeight, 2));
      expect(find.byKey(kComposerPermissionMenuKey), findsOneWidget);
    });
  });

  group('会话页窄屏', () {
    testWidgets('空会话：不走居中舞台、贴底且只有一行、不挂上下文环', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await _openPage(tester, size: _phone);

      expect(
        find.byType(NewSessionStage),
        findsNothing,
        reason: '手机窄屏的空会话直接把输入栏放到底部',
      );
      expect(
        find.byType(ContextUsageRing),
        findsNothing,
        reason: '折叠态没有模型胶囊，也就没有上下文环的位置',
      );
      expect(_panelHeight(tester), closeTo(kChatComposerCompactHeight, 2));
      expect(
        tester.getRect(find.byKey(kChatComposerPanelKey)).bottom,
        greaterThan(_phone.height - 40),
        reason: '输入栏要贴着屏幕底部',
      );

      // 品牌行落在「栏头以下、输入栏以上」这块的中线上。
      final brand = tester.getCenter(find.text(NewSessionBrand.label));
      final appBar = tester.getRect(find.byType(AppBar));
      final area = tester.getRect(find.byType(ChatComposerArea));
      expect(
        brand.dy,
        closeTo((appBar.bottom + area.top) / 2, 1),
        reason: '标语要在内容区正中',
      );

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('有内容后不再显示标语', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await _openPage(tester, size: _phone, withHistory: true);

      expect(find.text(NewSessionBrand.label), findsNothing);
      expect(find.byType(NewSessionStage), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('点空白收键盘后缩回一行', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await _openPage(tester, size: _phone);

      await tester.tap(find.byType(QuillEditor));
      await tester.pump();
      expect(_panelHeight(tester), closeTo(kChatComposerMinHeight, 2));

      // 点消息区（空列表那片空白）：收起系统键盘，面板跟着缩回一行。
      await tester.tapAt(const Offset(195, 200));
      await tester.pump();
      expect(_panelHeight(tester), closeTo(kChatComposerCompactHeight, 2));

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('有消息的会话：窄屏输入栏保持完整并带上下文环', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // 桌面窄窗：输入栏不折叠（折叠只给移动端），上下文环跟着模型胶囊一起在。
      await _openPage(tester, size: const Size(390, 844), withHistory: true);
      expect(find.byType(ContextUsageRing), findsOneWidget);
      expect(_panelHeight(tester), closeTo(kChatComposerMinHeight, 2));

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('宽屏同样是完整输入栏 + 上下文环', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await _openPage(tester, size: const Size(1200, 900), withHistory: true);
      expect(find.byType(ContextUsageRing), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
