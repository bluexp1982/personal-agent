import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/project_paths.dart';
import 'package:jarvis_app/src/features/conversations/attachment_embed.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';

ProjectPathReference _ref({
  String name = 'theme.css',
  String relativePath = 'styles/theme.css',
  String absolutePath = '/tmp/demo/styles/theme.css',
  bool isDir = false,
}) {
  return ProjectPathReference(
    name: name,
    relativePath: relativePath,
    absolutePath: absolutePath,
    isDir: isDir,
  );
}

AttachmentEmbed _attachment() {
  return AttachmentEmbed(
    localId: 'local-1',
    id: 'att_1',
    name: 'api.md',
    kind: 'file',
    mime: 'text/markdown',
    bytes: 12,
    uploading: false,
  );
}

void main() {
  test('插入路径芯片：正文展开为相对路径，不算附件', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertPathRefEmbed(controller, _ref());

    expect(pathRefEmbeds(controller), hasLength(1));
    expect(pathRefEmbeds(controller).single.name, 'theme.css');
    expect(
      pathRefEmbeds(controller).single.absolutePath,
      '/tmp/demo/styles/theme.css',
    );
    expect(composerText(controller), 'styles/theme.css');
    expect(
      composerHasContent(controller),
      isTrue,
      reason: '只拖了一枚路径芯片、没写文字，也是可发送内容',
    );
    expect(attachmentIds(controller), isEmpty);
    expect(pendingAttachmentCount(controller), 0);
  });

  test('路径芯片与附件并存：附件不进正文，路径照常发送', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertPathRefEmbed(controller, _ref());
    insertAttachmentEmbed(controller, _attachment());

    expect(composerText(controller), 'styles/theme.css');
    expect(composerText(controller).contains(kEmbedPlaceholder), isFalse);
    expect(attachmentIds(controller), <String>['att_1']);
    expect(pathRefEmbeds(controller), hasLength(1));
  });

  test('多枚路径芯片按出现顺序展开，中间保留插入时的空格', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertPathRefEmbed(controller, _ref());
    insertPathRefEmbed(
      controller,
      _ref(
        name: 'cat.html',
        relativePath: 'cat.html',
        absolutePath: '/tmp/demo/cat.html',
      ),
    );

    expect(
      pathRefEmbeds(controller).map((embed) => embed.relativePath),
      <String>['styles/theme.css', 'cat.html'],
    );
    expect(composerText(controller), 'styles/theme.css cat.html');
  });

  test('目录芯片标记为目录，图标与提示靠它区分', () {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    insertPathRefEmbed(
      controller,
      _ref(
        name: 'styles',
        relativePath: 'styles',
        absolutePath: '/tmp/demo/styles',
        isDir: true,
      ),
    );

    expect(pathRefEmbeds(controller).single.isDir, isTrue);
    expect(composerText(controller), 'styles');
  });
}
