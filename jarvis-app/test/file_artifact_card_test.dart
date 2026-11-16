import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/artifact_card.dart';
import 'package:jarvis_app/src/features/conversations/file_artifact_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

const FileWriteView _pending = FileWriteView(
  requestId: 'fw_1',
  path: 'index.html',
  scope: 'draft',
  status: 'pending',
  bytes: 2048,
  existingBytes: 1024,
  expiresAt: 4_000_000_000_000,
);

const FileWriteView _written = FileWriteView(
  requestId: 'fw_2',
  path: 'calc.html',
  scope: 'project',
  status: 'written',
  bytes: 512,
);

void main() {
  group('FileWriteView 解析', () {
    test('完整字段照原样读出', () {
      final write = FileWriteView.fromJson(<String, dynamic>{
        'request_id': 'fw_9',
        'path': 'prototypes/calc.html',
        'scope': 'project',
        'status': 'written',
        'bytes': 1234,
        'existing_bytes': 0,
        'backup_path': '/tmp/backup/index.html',
        'created_at': 1700000000000,
      });

      expect(write.requestId, 'fw_9');
      expect(write.path, 'prototypes/calc.html');
      expect(write.inProject, isTrue);
      expect(write.isWritten, isTrue);
      expect(write.previewable, isTrue);
      expect(write.backupPath, '/tmp/backup/index.html');
    });

    test('缺字段时给安全默认值，不抛异常', () {
      final write = FileWriteView.fromJson(<String, dynamic>{
        'request_id': 'fw_min',
        'path': 'a.md',
      });

      expect(write.scope, 'draft');
      expect(write.status, 'written');
      expect(write.bytes, 0);
      expect(write.existingBytes, 0);
      expect(write.expiresAt, isNull);
      expect(write.previewable, isFalse, reason: 'markdown 不归预览站管');
    });

    test('消息里的 file_writes 形状不对时降级为空列表', () {
      final message = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_1',
        'role': 'assistant',
        'content': '写好了',
        'file_writes': '不是数组',
      });
      expect(message.fileWrites, isEmpty);

      final legacy = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_2',
        'role': 'assistant',
        'content': '旧消息',
      });
      expect(legacy.fileWrites, isEmpty);
    });

    test('数组里的坏项被过滤，好的照常显示', () {
      final message = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_3',
        'role': 'assistant',
        'content': '写好了',
        'file_writes': <dynamic>[
          <String, dynamic>{'request_id': 'fw_ok', 'path': 'a.html'},
          <String, dynamic>{'request_id': '', 'path': 'broken.html'},
          'not-an-object',
        ],
      });

      expect(message.fileWrites.length, 1);
      expect(message.fileWrites.first.requestId, 'fw_ok');
    });
  });

  testWidgets('待确认时给覆盖与取消两个按钮', (tester) async {
    final decisions = <bool>[];

    await tester.pumpWidget(
      _wrap(
        FileWriteArtifactCard(
          write: _pending,
          onDecide: (write, approve) => decisions.add(approve),
        ),
      ),
    );

    expect(find.text('待确认覆盖'), findsOneWidget);
    expect(find.text('index.html'), findsOneWidget);
    expect(find.text('覆盖'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 覆盖前要说清两边大小，用户才知道自己在改什么。
    expect(find.textContaining('原 1 KB'), findsOneWidget);
    expect(find.textContaining('新 2 KB'), findsOneWidget);

    await tester.tap(find.text('覆盖'));
    expect(decisions, <bool>[true]);

    await tester.tap(find.text('取消'));
    expect(decisions, <bool>[true, false]);
  });

  testWidgets('已写入的文件给打开与保存，两个回调各自生效', (tester) async {
    var opened = 0;
    var saved = 0;

    await tester.pumpWidget(
      _wrap(
        FileWriteArtifactCard(
          write: _written,
          onOpen: (write) => opened += 1,
          onSave: () => saved += 1,
        ),
      ),
    );

    expect(find.text('已写入'), findsOneWidget);
    expect(find.text('覆盖'), findsNothing);

    await tester.tap(find.byKey(kFileOpenKey));
    expect(opened, 1);

    await tester.tap(find.byKey(kFileSaveKey));
    expect(saved, 1);
  });

  testWidgets('保存靠左、打开靠右，打开图标与媒体卡同一枚', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FileWriteArtifactCard(
          write: _written,
          onOpen: (write) {},
          onSave: _noop,
        ),
      ),
    );

    final save = tester.getTopLeft(find.byKey(kFileSaveKey));
    final open = tester.getTopLeft(find.byKey(kFileOpenKey));
    expect(
      save.dx,
      lessThan(open.dx),
      reason: '右下角动作区的顺序是「保存、打开」',
    );

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(kFileOpenKey),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.icon, kArtifactOpenIcon);
  });

  testWidgets('不给回调就不出现对应按钮（草案里的非网页文件）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const FileWriteArtifactCard(
          write: FileWriteView(
            requestId: 'fw_3',
            path: 'notes.md',
            status: 'written',
            bytes: 12,
          ),
          onSave: _noop,
        ),
      ),
    );

    expect(
      find.byKey(kFileOpenKey),
      findsNothing,
      reason: '草案里的 markdown 打不开，不该给一个必然失败的入口',
    );
    expect(find.byKey(kFileSaveKey), findsOneWidget);
  });

  testWidgets('失败与过期的卡片不提供操作', (tester) async {
    for (final status in <String>['failed', 'expired', 'rejected']) {
      await tester.pumpWidget(
        _wrap(
          FileWriteArtifactCard(
            write: FileWriteView(
              requestId: 'fw_$status',
              path: 'a.html',
              status: status,
              bytes: 10,
            ),
            onDecide: (write, approve) {},
            onOpen: (write) {},
            onSave: _noop,
          ),
        ),
      );

      expect(find.text('覆盖'), findsNothing, reason: '$status 不该还能覆盖');
      expect(
        find.byKey(kFileOpenKey),
        findsNothing,
        reason: '$status 不是可用的成品',
      );
      expect(find.byKey(kFileSaveKey), findsNothing);
    }
  });

  testWidgets('备份路径要显示出来，方便用户还原', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const FileWriteArtifactCard(
          write: FileWriteView(
            requestId: 'fw_4',
            path: 'index.html',
            status: 'written',
            bytes: 100,
            backupPath: '/data/file-backups/conv/index.html',
          ),
        ),
      ),
    );

    expect(
      find.textContaining('/data/file-backups/conv/index.html'),
      findsOneWidget,
    );
  });
}

void _noop() {}
