import 'package:jarvis_app/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Project', () {
    test('解析服务端字段并识别模式', () {
      final project = Project.fromJson(<String, dynamic>{
        'id': 'ws_1',
        'name': '个人事务',
        'mode': 'work',
        'path': '/Users/you/Documents',
        'conversation_count': 2,
        'task_count': 1,
        'created_at': 1,
        'updated_at': 2,
      });

      expect(project.id, 'ws_1');
      expect(project.isCode, isFalse);
      expect(project.conversationCount, 2);
      expect(project.directoryName, 'Documents');
    });

    test('缺字段时给安全默认值，不把列表读崩', () {
      final project = Project.fromJson(<String, dynamic>{});
      expect(project.name, '未命名项目');
      expect(project.mode, ProjectModes.work);
      expect(project.conversationCount, 0);
    });
  });

  group('ProjectPreflight', () {
    test('未初始化的目录：不能直接建，但可以初始化', () {
      final preflight = ProjectPreflight.fromJson(<String, dynamic>{
        'path': '/Users/you/work/demo',
        'mode': 'code',
        'ready': false,
        'git': 'missing',
        'can_init': true,
        'reason': '还不是 Git 仓库',
      });

      expect(preflight.ready, isFalse);
      expect(preflight.needsInit, isTrue);
      expect(preflight.isRepo, isFalse);
      expect(preflight.gitDetail, isNull);
      expect(preflight.reason, '还不是 Git 仓库');
    });

    test('嵌套目录带上父仓库路径，供确认框解释后果', () {
      final preflight = ProjectPreflight.fromJson(<String, dynamic>{
        'path': '/Users/you/mono/app',
        'mode': 'code',
        'ready': false,
        'git': 'nested',
        'git_detail': '/Users/you/mono',
        'can_init': true,
      });

      expect(preflight.git, GitStates.nested);
      expect(preflight.gitDetail, '/Users/you/mono');
    });

    test('游离 HEAD 不可初始化：只能人工修', () {
      final preflight = ProjectPreflight.fromJson(<String, dynamic>{
        'path': '/Users/you/work/demo',
        'mode': 'code',
        'ready': false,
        'git': 'detached',
        'can_init': false,
        'reason': '换回一个分支',
      });

      expect(preflight.needsInit, isFalse);
      expect(preflight.reason, '换回一个分支');
    });

    test('缺字段时给保守默认值（不可建、不可初始化）', () {
      final preflight = ProjectPreflight.fromJson(<String, dynamic>{});
      expect(preflight.ready, isFalse);
      expect(preflight.canInit, isFalse);
      expect(preflight.git, GitStates.notApplicable);
    });
  });

  group('DirListing', () {
    DirListing listing(String path, {String? parent, String? root}) {
      return DirListing.fromJson(<String, dynamic>{
        'path': path,
        'parent': parent,
        'roots': <String>[root ?? '/Users/you'],
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'code',
            'path': '/Users/you/code',
            'kind': 'repo',
          },
        ],
      });
    }

    test('仓库目录标记为 repo', () {
      final data = listing('/Users/you');
      expect(data.entries.single.isRepo, isTrue);
      expect(data.parent, isNull);
    });

    test('面包屑从根目录开始逐段展开', () {
      final data = listing('/Users/you/work/docs', parent: '/Users/you/work');
      final crumbs = data.crumbs();
      expect(crumbs.map((crumb) => crumb.label).toList(), <String>[
        'you',
        'work',
        'docs',
      ]);
      expect(crumbs.first.path, '/Users/you');
      expect(crumbs.last.path, '/Users/you/work/docs');
    });

    test('根目录本身只有一个面包屑', () {
      final crumbs = listing('/Users/you').crumbs();
      expect(crumbs.length, 1);
      expect(crumbs.single.label, 'you');
    });
  });

  group('ProjectListing', () {
    test('解析目录与文件，文件带大小、目录不带', () {
      final data = ProjectListing.fromJson(<String, dynamic>{
        'path': '/Users/you/demo',
        'truncated': true,
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'src',
            'path': '/Users/you/demo/src',
            'kind': 'dir',
          },
          <String, dynamic>{
            'name': 'main.rs',
            'path': '/Users/you/demo/main.rs',
            'kind': 'file',
            'size': 2048,
          },
        ],
      });

      expect(data.path, '/Users/you/demo');
      expect(data.truncated, isTrue);
      expect(data.entries.first.isDir, isTrue);
      expect(data.entries.first.size, isNull);
      expect(data.entries.last.isDir, isFalse);
      expect(data.entries.last.size, 2048);
    });

    test('缺字段时给安全默认值', () {
      final data = ProjectListing.fromJson(<String, dynamic>{});
      expect(data.path, '');
      expect(data.entries, isEmpty);
      expect(data.truncated, isFalse);
    });
  });

  group('FileContent', () {
    test('解析截断标记与完整大小', () {
      final content = FileContent.fromJson(<String, dynamic>{
        'path': '/Users/you/demo/big.txt',
        'size': 1048576,
        'text': 'hello',
        'truncated': true,
      });

      expect(content.path, '/Users/you/demo/big.txt');
      expect(content.size, 1048576);
      expect(content.text, 'hello');
      expect(content.truncated, isTrue);
    });
  });

  group('文件展示辅助', () {
    test('大小换算保留一位小数并去掉多余的 .0', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(1023), '1023 B');
      expect(formatFileSize(1024), '1 KB');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(1024 * 1024), '1 MB');
      expect(formatFileSize(5 * 1024 * 1024), '5 MB');
    });

    test('文件名兼容 / 与 \\ 两种分隔符', () {
      expect(fileNameOf('/Users/you/demo/main.rs'), 'main.rs');
      expect(fileNameOf(r'C:\Users\you\demo\main.rs'), 'main.rs');
      expect(fileNameOf('main.rs'), 'main.rs');
    });
  });
}
