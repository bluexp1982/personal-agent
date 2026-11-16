import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

SkillInfo _skill(String name) {
  return SkillInfo(
    name: name,
    version: '1.0.0',
    source: 'builtin',
    riskLevel: 'read',
    support: SkillSupport.supported,
    description: '$name 的说明',
  );
}

void main() {
  test('没有标签时 firstSkillName 为 null，文本原样返回', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    setComposerText(controller, '帮我看看这个');

    expect(composerText(controller), '帮我看看这个');
    expect(firstSkillName(controller), isNull);
  });

  test('标签落在光标处，纯文本里不带占位符', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    setComposerText(controller, '整理一下');
    // 光标移到最前：标签应该插在这里，而不是追加到末尾。
    controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );

    insertSkillEmbed(controller, _skill('weekly-digest'));

    expect(firstSkillName(controller), 'weekly-digest');
    expect(composerText(controller), '整理一下');
    expect(
      composerText(controller).contains(kEmbedPlaceholder),
      isFalse,
      reason: '占位符不能漏进发送内容',
    );
    expect(
      controller.document.toPlainText().indexOf(kEmbedPlaceholder),
      0,
      reason: '标签应插在光标处（开头）',
    );
  });

  /// 派任务的状态是单值：两个标签就得定义"谁优先"，那是产品决策。
  test('只保留一个标签：再插第二个会替换第一个', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertSkillEmbed(controller, _skill('weekly-digest'));
    insertSkillEmbed(controller, _skill('site-brief'));

    expect(skillEmbeds(controller), hasLength(1));
    expect(firstSkillName(controller), 'site-brief');
  });

  test('clearSkillEmbeds 之后不再有标签，正文也不受影响', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    setComposerText(controller, '看看这个网页');
    insertSkillEmbed(controller, _skill('site-brief'));
    expect(firstSkillName(controller), 'site-brief');

    final removed = clearSkillEmbeds(controller);

    expect(removed, 1);
    expect(firstSkillName(controller), isNull);
    expect(composerText(controller), '看看这个网页');
  });

  test('清空输入栏会连标签一起清掉', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertSkillEmbed(controller, _skill('site-brief'));
    clearComposer(controller);

    expect(firstSkillName(controller), isNull);
    expect(composerText(controller), isEmpty);
  });
}
