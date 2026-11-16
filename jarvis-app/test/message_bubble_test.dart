import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/file_artifact_card.dart';
import 'package:jarvis_app/src/features/conversations/media_artifact_card.dart';
import 'package:jarvis_app/src/features/conversations/message_bubble.dart';
import 'package:jarvis_app/src/features/conversations/message_copy_button.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  // 产物卡是 Consumer（要读视频封面 provider），外层必须有 ProviderScope。
  return ProviderScope(
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// 拦下剪贴板调用：测试环境没有平台通道，不 mock 只能拿到空结果。
void _mockClipboard(WidgetTester tester, List<String> sink) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        sink.add((call.arguments as Map<dynamic, dynamic>)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

void main() {
  testWidgets('流式时显示执行过程摘要，不再只给一个省略号', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'm_steps',
            role: 'assistant',
            content: '',
            streaming: true,
            steps: <ChatStep>[
              ChatStep(
                id: 'call_1',
                tool: 'read_file',
                label: '正在读取 calculator2.html',
                running: true,
              ),
            ],
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('正在读取 calculator2.html · 已执行 1 步'), findsOneWidget);
    // 有执行过程时不该再叠一个省略号占位：两处占位看起来更像卡住。
    expect(find.text('…'), findsNothing);
  });

  testWidgets('没有工具调用的回答不显示执行过程', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'm_done',
            role: 'assistant',
            content: '两个主题按钮都加好了。',
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('两个主题按钮都加好了。'), findsOneWidget);
    expect(find.textContaining('执行了'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('AI 回答走 Markdown 渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'm1',
            role: 'assistant',
            content: '**重点**：先跑 `flutter test`。',
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('重点', findRichText: true), findsWidgets);
  });

  testWidgets('用户消息保持纯文本，星号原样保留', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'm2',
            role: 'user',
            content: '**这不是加粗**',
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('**这不是加粗**'), findsOneWidget);
  });

  testWidgets('空回答显示占位符，不喂给解析器', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'm3',
            role: 'assistant',
            content: '',
            streaming: true,
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('用户消息气泡下挂时间与复制按钮', (tester) async {
    final copied = <String>[];
    _mockClipboard(tester, copied);

    final created = DateTime(2026, 9, 25, 16, 34).millisecondsSinceEpoch;
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: ChatMessage(
            id: 'u1',
            role: 'user',
            content: '帮我写一个时钟',
            createdAt: created,
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('9月25日 16:34'), findsOneWidget);
    final copyButton = find.byTooltip('复制');
    expect(copyButton, findsOneWidget);

    // 复制键与栏头那批图标按钮同规格：命中区 24、图标 14。
    expect(
      tester.getSize(
        find.ancestor(of: copyButton, matching: find.byType(IconButton)),
      ),
      const Size.square(kPaneHeaderButtonSize),
    );
    expect(
      tester.getSize(
        find.descendant(of: copyButton, matching: find.byType(CopyGlyph)),
      ),
      const Size.square(kPaneHeaderIconSize),
    );

    await tester.tap(copyButton);
    await tester.pump();

    expect(copied, <String>['帮我写一个时钟']);
    expect(find.text('已复制'), findsOneWidget);

    // 让"对勾复位"与提示条的定时器都跑完，否则测试结束时会挂着 Timer。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('用户气泡底色是参考图取值，明暗两套都生效', (tester) async {
    Color? bubbleColor() {
      final decorations = tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text('看这里'),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>();
      return decorations.firstWhere((item) => item.color != null).color;
    }

    Future<void> pumpWith(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: MessageBubble(
              message: const ChatMessage(
                id: 'u9',
                role: 'user',
                content: '看这里',
                createdAt: 1,
              ),
              dispatchStates: const <String, String>{},
              onDispatch: (_) {},
            ),
          ),
        ),
      );
      // MaterialApp 换主题会走 200ms 的过渡：不等它跑完，读到的是旧亮度。
      await tester.pumpAndSettle();
    }

    await pumpWith(ThemeData.light());
    expect(bubbleColor(), const Color(0xFFEDF3FE));

    await pumpWith(ThemeData.dark());
    expect(bubbleColor(), const Color(0xFF1E2432));
  });

  testWidgets('AI 回答首行给状态与用时，末行给复制、用量与时间', (tester) async {
    final copied = <String>[];
    _mockClipboard(tester, copied);

    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: '修好了。',
            createdAt: DateTime(2026, 9, 25, 16, 34).millisecondsSinceEpoch,
            elapsedMs: 118000,
            usage: const TokenUsage(promptTokens: 1200, completionTokens: 320),
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('已完成，用时 1 分 58 秒'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('1.5k tokens'), findsOneWidget);
    expect(find.text('9月25日 16:34'), findsOneWidget);

    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copied, <String>['修好了。']);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('没有耗时与用量的历史消息只显示状态与时间', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: ChatMessage(
            id: 'a2',
            role: 'assistant',
            content: '旧回答。',
            createdAt: DateTime(2026, 9, 25, 16, 34).millisecondsSinceEpoch,
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('流式中的回答显示"生成中…"，失败的显示"生成失败"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'a3',
            role: 'assistant',
            content: '正在写',
            streaming: true,
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );
    expect(find.text('生成中…'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'a3',
            role: 'assistant',
            content: '写到一半断了',
            failed: true,
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('被用户停止的回答显示"已停止"，不当成失败', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'a4',
            role: 'assistant',
            content: '写到一半被喊停',
            finishReason: 'stopped',
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('生成失败'), findsNothing);
    // 半截回答仍然可以复制：它是有内容的，只是没写完。
    expect(find.byTooltip('复制'), findsOneWidget);
  });

  testWidgets('系统提示居中显示，不套气泡、不带复制按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: const ChatMessage(
            id: 'n1',
            role: 'system',
            content: '已记住：我讨厌香菜',
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.text('已记住：我讨厌香菜'), findsOneWidget);
    // 它不是助手回答：不走 Markdown，也没有"已完成/复制"那一套。
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.byTooltip('复制'), findsNothing);
    expect(find.byType(MessageCopyButton), findsNothing);
    expect(find.textContaining('已完成'), findsNothing);
  });

  test('用时精确到秒，分钟与秒都给出', () {
    expect(formatElapsed(32000), '32 秒');
    expect(formatElapsed(118000), '1 分 58 秒');
    expect(formatElapsed(120000), '2 分');
  });

  test('用量压缩成大数字短形式，估算值带约数前缀', () {
    expect(
      formatTokenUsage(
        const TokenUsage(promptTokens: 800, completionTokens: 56),
      ),
      '856 tokens',
    );
    expect(
      formatTokenUsage(
        const TokenUsage(promptTokens: 1200, completionTokens: 320),
      ),
      '1.5k tokens',
    );
    expect(
      formatTokenUsage(
        const TokenUsage(
          promptTokens: 1200,
          completionTokens: 320,
          estimated: true,
        ),
      ),
      '≈1.5k tokens',
    );
  });

  testWidgets('来源标签展示域名并支持点击复制', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<dynamic, dynamic>)['text'] as String,
          );
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: ChatMessage(
            id: 'm4',
            role: 'assistant',
            content: '结论如上。',
            sources: <MessageSource>[
              MessageSource(url: 'https://example.com/a', fetchedAt: 0),
            ],
          ),
          dispatchStates: const <String, String>{},
          onDispatch: (_) {},
        ),
      ),
    );

    expect(find.textContaining('example.com'), findsOneWidget);
    await tester.tap(find.textContaining('example.com'));
    await tester.pumpAndSettle();

    expect(copied, <String>['https://example.com/a']);
    expect(find.text('链接已复制'), findsOneWidget);
  });

  group('产物卡片排版', () {
    // 默认测试画布 800 宽：够两列，槽宽 = (800 - 10) / 2。
    const double twoUpSlot = 395;

    const FileWriteView written = FileWriteView(
      requestId: 'fw_a',
      path: 'cat.html',
      scope: 'project',
      status: 'written',
      bytes: 512,
    );

    ChatMessage messageWith({
      List<FileWriteView> fileWrites = const <FileWriteView>[],
      List<MediaAsset> media = const <MediaAsset>[],
    }) {
      return ChatMessage(
        id: 'm_cards',
        role: 'assistant',
        content: '做好了。',
        fileWrites: fileWrites,
        media: media,
      );
    }

    /// 窄屏用：把气泡塞进一个固定宽度的盒子里。
    Widget narrow(Widget child, double width) {
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: SizedBox(width: width, child: child)),
          ),
        ),
      );
    }

    testWidgets('宽时两张卡并排，各占半宽', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: messageWith(
              fileWrites: const <FileWriteView>[
                written,
                FileWriteView(
                  requestId: 'fw_b',
                  path: 'dog.html',
                  scope: 'project',
                  status: 'written',
                  bytes: 1024,
                ),
              ],
            ),
            dispatchStates: const <String, String>{},
            onDispatch: (_) {},
          ),
        ),
      );

      final cards = find.byType(FileWriteArtifactCard);
      expect(cards, findsNWidgets(2));
      expect(tester.getSize(cards.at(0)).width, closeTo(twoUpSlot, 0.5));
      expect(tester.getSize(cards.at(1)).width, closeTo(twoUpSlot, 0.5));
      expect(
        tester.getTopLeft(cards.at(0)).dy,
        closeTo(tester.getTopLeft(cards.at(1)).dy, 0.5),
        reason: '两张卡应该在同一行',
      );
      expect(
        tester.getTopLeft(cards.at(1)).dx,
        closeTo(tester.getTopLeft(cards.at(0)).dx + twoUpSlot + 10, 0.5),
      );
    });

    testWidgets('只有一张卡也只占半宽，不拉满整行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: messageWith(fileWrites: const <FileWriteView>[written]),
            dispatchStates: const <String, String>{},
            onDispatch: (_) {},
          ),
        ),
      );

      final card = find.byType(FileWriteArtifactCard);
      expect(card, findsOneWidget);
      expect(tester.getSize(card).width, closeTo(twoUpSlot, 0.5));
      expect(tester.getTopLeft(card).dx, 0);
    });

    testWidgets('窄屏退回整行，卡片不被压成半宽', (tester) async {
      await tester.pumpWidget(
        narrow(
          MessageBubble(
            message: messageWith(fileWrites: const <FileWriteView>[written]),
            dispatchStates: const <String, String>{},
            onDispatch: (_) {},
          ),
          360,
        ),
      );

      expect(tester.getSize(find.byType(FileWriteArtifactCard)).width, closeTo(360, 0.5));
    });

    testWidgets('视频卡与文件卡也能并排（跨类型同一行）', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: messageWith(
              media: const <MediaAsset>[
                MediaAsset(
                  id: 'vid_1',
                  kind: 'video',
                  mime: 'video/mp4',
                  bytes: 3 * 1024 * 1024,
                  model: 'wan3.0-video-prime',
                  prompt: '海边日落',
                  durationMs: 5000,
                  resolution: '480P',
                ),
              ],
              fileWrites: const <FileWriteView>[written],
            ),
            dispatchStates: const <String, String>{},
            onDispatch: (_) {},
          ),
        ),
      );

      final video = find.byType(MediaArtifactCard);
      final file = find.byType(FileWriteArtifactCard);
      expect(tester.getSize(video).width, closeTo(twoUpSlot, 0.5));
      expect(tester.getSize(file).width, closeTo(twoUpSlot, 0.5));
      expect(
        tester.getTopLeft(video).dy,
        closeTo(tester.getTopLeft(file).dy, 0.5),
        reason: '同属产物，应该凑成一行',
      );
    });
  });
}
