import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/features/conversations/attachment_embed.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';

AttachmentEmbed _embed({
  String localId = 'local-1',
  String name = 'api.md',
  String kind = 'file',
  String mime = 'text/markdown',
  String id = '',
  bool uploading = true,
}) {
  return AttachmentEmbed(
    localId: localId,
    id: id,
    name: name,
    kind: kind,
    mime: mime,
    bytes: 12,
    uploading: uploading,
  );
}

void main() {
  test('插入附件芯片：文本里不留占位符，上传中不算可发送内容', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertAttachmentEmbed(controller, _embed());

    expect(attachmentEmbeds(controller), hasLength(1));
    expect(attachmentEmbeds(controller).single.name, 'api.md');
    expect(
      composerText(controller).contains(kEmbedPlaceholder),
      isFalse,
      reason: '占位符不能漏进发送内容',
    );
    expect(pendingAttachmentCount(controller), 1);
    expect(
      composerHasContent(controller),
      isFalse,
      reason: '还在上传的附件不能算作可发送内容',
    );
    expect(attachmentIds(controller), isEmpty);
  });

  test('上传完成后再替换：同一位置、变成可发送', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    setComposerText(controller, '看看这个');
    controller.updateSelection(
      const TextSelection.collapsed(offset: 4),
      ChangeSource.local,
    );
    final embed = _embed();
    insertAttachmentEmbed(controller, embed);

    final replaced = replaceAttachmentEmbed(
      controller,
      embed.localId,
      embed.complete(id: 'att_1'),
    );

    expect(replaced, isTrue);
    expect(attachmentIds(controller), <String>['att_1']);
    expect(pendingAttachmentCount(controller), 0);
    expect(composerHasContent(controller), isTrue);
    expect(composerText(controller), '看看这个');
    // 位置没变：芯片仍夹在文字中间，而不是被挪到末尾。
    expect(
      controller.document.toPlainText().indexOf(kEmbedPlaceholder),
      4,
    );
  });

  test('找不到 localId 时替换返回 false（用户已经删掉那枚芯片）', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    expect(
      replaceAttachmentEmbed(controller, 'local-x', _embed().complete(id: 'a')),
      isFalse,
    );
  });

  test('上传失败的芯片不会进发送列表', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    final embed = _embed();
    insertAttachmentEmbed(controller, embed);
    replaceAttachmentEmbed(controller, embed.localId, embed.failed('超过上限'));

    expect(attachmentIds(controller), isEmpty);
    expect(attachmentEmbeds(controller).single.error, '超过上限');
  });

  test('多枚附件可以并存（与"只留一个技能标签"不同）', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertAttachmentEmbed(controller, _embed(localId: 'a', name: 'a.md'));
    insertAttachmentEmbed(
      controller,
      _embed(localId: 'b', name: 'b.png', kind: 'image', mime: 'image/png'),
    );

    expect(attachmentEmbeds(controller).map((embed) => embed.name), <String>[
      'a.md',
      'b.png',
    ]);
  });

  test('只有附件、没有文字也是可发送内容', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    final embed = _embed(kind: 'image', mime: 'image/png');
    insertAttachmentEmbed(controller, embed);
    replaceAttachmentEmbed(controller, embed.localId, embed.complete(id: 'a'));

    expect(composerText(controller), isEmpty);
    expect(composerHasContent(controller), isTrue);
  });

  testWidgets('芯片显示文件名，点 X 触发删除', (tester) async {
    var removed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AttachmentChip(
              embed: _embed(uploading: false, id: 'att_1'),
              onRemove: () => removed += 1,
            ),
          ),
        ),
      ),
    );

    expect(find.text('api.md'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    expect(removed, 1);
  });

  testWidgets('只读芯片不画 X（气泡里那种）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AttachmentChip(embed: _embed(uploading: false, id: 'a')),
          ),
        ),
      ),
    );

    expect(find.text('api.md'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
