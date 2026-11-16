import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// `@` 候选面板的键盘操作。
///
/// 这些键必须由 quill 的 `onKeyPressed` 接：放在外层 `Shortcuts` 里，
/// 方向键会先被编辑器拿去移动光标，候选高亮不动而光标在跑。

SkillInfo _skill(String name, String description) {
  return SkillInfo(
    name: name,
    version: '1.0.0',
    source: 'builtin',
    riskLevel: 'read',
    support: SkillSupport.supported,
    description: description,
  );
}

class _Harness {
  _Harness(this.controller, this.sent);

  final QuillController controller;
  int sent;
}

Future<_Harness> _pump(WidgetTester tester) async {
  final controller = QuillController.basic();
  addTearDown(controller.dispose);
  final harness = _Harness(controller, 0);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        atSkillsProvider.overrideWith(
          (ref) async => <SkillInfo>[
            _skill('weekly-digest', '整理一周记录'),
            _skill('site-brief', '读一个网页并摘要'),
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          // 输入栏要贴底：真实页面就是这样，候选面板向上溢出后仍在屏幕内。
          // 放在顶部会让面板跑到屏幕外的负坐标，点不中，测试就测不出真问题。
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              ChatComposer(
                controller: controller,
                sending: false,
                onSend: () => harness.sent += 1,
                onStop: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 编辑器要先拿到焦点：按键事件是从它往下派的。
  await tester.tap(find.byType(QuillEditor));
  await tester.pump();

  return harness;
}

/// 在光标处打一个 `@`，等候选出来。
Future<void> _typeAt(WidgetTester tester, QuillController controller) async {
  controller.replaceText(
    0,
    controller.document.toPlainText().length - 1,
    '@',
    const TextSelection.collapsed(offset: 1),
  );
  await tester.pumpAndSettle();
}

void main() {
  /// 新会话页是「品牌行 + 输入栏」整块居中的（`NewSessionStage`）。
  /// 候选面板一旦参与布局，整块变高而中心不变，输入栏就会往下沉——
  /// 这条测试把"面板不许占布局高度"钉住。
  testWidgets('候选面板浮在上方，不推挤输入栏', (tester) async {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          atSkillsProvider.overrideWith(
            (ref) async => <SkillInfo>[
              _skill('weekly-digest', '整理一周记录'),
              _skill('site-brief', '读一个网页并摘要'),
            ],
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text('探索未来'),
                  ChatComposer(
                    controller: controller,
                    sending: false,
                    onSend: () {},
                    onStop: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(QuillEditor));
    await tester.pump();

    final before = tester.getRect(find.byKey(kChatComposerPanelKey));

    await _typeAt(tester, controller);
    expect(find.text('@weekly-digest'), findsOneWidget);

    final after = tester.getRect(find.byKey(kChatComposerPanelKey));
    expect(
      after.top,
      closeTo(before.top, 0.5),
      reason: '弹出候选不该让输入栏往下沉',
    );
    expect(after.bottom, closeTo(before.bottom, 0.5));
  });

  testWidgets('↓ 会点亮候选行（否则看不出高亮在动）', (tester) async {
    final harness = await _pump(tester);
    await _typeAt(tester, harness.controller);

    AgentMenuCommandRow firstRow() =>
        tester.widget<AgentMenuCommandRow>(find.byType(AgentMenuCommandRow).at(0));
    AgentMenuCommandRow secondRow() =>
        tester.widget<AgentMenuCommandRow>(find.byType(AgentMenuCommandRow).at(1));

    expect(firstRow().highlighted, isTrue, reason: '默认停在第一条');
    expect(secondRow().highlighted, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(firstRow().highlighted, isFalse);
    expect(secondRow().highlighted, isTrue, reason: '↓ 之后高亮应该走第二条');
  });

  testWidgets('第一次打 @ 就该出候选（清单是预热好的）', (tester) async {
    final harness = await _pump(tester);
    await _typeAt(tester, harness.controller);

    expect(
      find.text('@weekly-digest'),
      findsOneWidget,
      reason: '首次 @ 若为空，用户要删掉重打才看得见',
    );
    expect(find.text('@site-brief'), findsOneWidget);
  });

  testWidgets('Esc 收起候选面板', (tester) async {
    final harness = await _pump(tester);
    await _typeAt(tester, harness.controller);
    expect(find.text('@weekly-digest'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('@weekly-digest'), findsNothing);
    // 收起后输入内容不变，也不该被派出去。
    expect(composerText(harness.controller), '@');
    expect(harness.sent, 0);
  });

  testWidgets('↓ 移动高亮，Enter 选中高亮的那一条', (tester) async {
    final harness = await _pump(tester);
    await _typeAt(tester, harness.controller);

    // 默认高亮第一条，按一次 ↓ 落到第二条。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      firstSkillName(harness.controller),
      'site-brief',
      reason: 'Enter 应选中高亮项而不是永远第一条',
    );
    // 选中后 `@` 片段被替换成标签，不会残留。
    expect(composerText(harness.controller), isEmpty);
    expect(harness.sent, 0, reason: '候选打开时 Enter 不是发送');
  });

  /// 用户的真实操作顺序：点候选行选中技能，再按回车发送。
  ///
  /// 候选行是 `MenuItemButton`，点它会把焦点抢到行上；如果焦点没还回编辑器，
  /// 之后按回车就不会被编辑器收到——表现正是"选了技能之后按回车没反应"。
  testWidgets('点候选行选中后，焦点回到编辑器，回车仍能发送', (tester) async {
    final harness = await _pump(tester);
    await _typeAt(tester, harness.controller);

    await tester.tap(find.text('@weekly-digest'));
    await tester.pumpAndSettle();
    expect(firstSkillName(harness.controller), 'weekly-digest');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      harness.sent,
      1,
      reason: '选中技能后焦点必须回到编辑器，否则回车发不出去',
    );
  });

  testWidgets('候选没打开时 Enter 是发送', (tester) async {
    final harness = await _pump(tester);

    harness.controller.replaceText(
      0,
      0,
      '帮我看看这个',
      const TextSelection.collapsed(offset: 6),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(harness.sent, 1);
  });
}
