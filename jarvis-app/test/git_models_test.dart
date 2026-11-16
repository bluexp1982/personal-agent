import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/git_models.dart';

/// 契约解析测试。
///
/// 这里的 JSON 是从服务端真实响应里抄下来的形状（见 `crates/jarvis-service/tests/git_api.rs`
/// 的断言）：字段名对不上在客户端只表现为"值全是默认值"，界面看着正常却处处不对，
/// 所以必须逐字段钉住，而不是只测"能解析不报错"。
void main() {
  test('status 解析三组变更与分支', () {
    final json = jsonDecode('''
        {
          "repo": true,
          "branch": "main",
          "detached": false,
          "head": {
            "hash": "5f2a1c0d9e8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f",
            "short_hash": "5f2a1c0",
            "subject": "chore: 初始提交",
            "author": "张三",
            "time_ms": 1700000000000
          },
          "staged": [{"path": "staged.txt", "state": "added"}],
          "unstaged": [{"path": "tracked.txt", "state": "modified"}],
          "untracked": [{"path": "fresh.txt", "state": "untracked"}]
        }
        ''') as Map<String, dynamic>;

    final status = GitStatusReport.fromJson(json);
    expect(status.repo, isTrue);
    expect(status.branch, 'main');
    expect(status.branchLabel, 'main');
    expect(status.changeCount, 3);
    expect(status.isClean, isFalse);
    expect(status.head?.shortHash, '5f2a1c0');
    expect(status.head?.timeMs, 1700000000000);
    expect(status.staged.single.state, GitFileState.added);
    expect(status.untracked.single.state, GitFileState.untracked);
    expect(status.commitBlockedReason, isNull, reason: '有暂存内容就可以提交');
  });

  test('status 非仓库时是状态而不是错误', () {
    final status = GitStatusReport.fromJson(
      jsonDecode('{"repo":false,"detached":false,"reason":"/tmp/x 不是 Git 仓库"}')
          as Map<String, dynamic>,
    );
    expect(status.repo, isFalse);
    expect(status.reason, '/tmp/x 不是 Git 仓库');
    expect(status.isClean, isFalse, reason: '不是仓库不能被当成「干净」');
    expect(status.commitBlockedReason, '当前目录不是 Git 仓库');
  });

  test('status 中间态会挡住提交', () {
    final status = GitStatusReport.fromJson(
      jsonDecode(
        '{"repo":true,"branch":"main","detached":false,"operation":"merge",'
        '"staged":[{"path":"a.txt","state":"modified"}],'
        '"unstaged":[],"untracked":[]}',
      ) as Map<String, dynamic>,
    );
    expect(status.operation, GitOperation.merge);
    expect(status.commitBlockedReason, contains('merge'));
  });

  test('游离 HEAD 时分支名有专门文案', () {
    final status = GitStatusReport.fromJson(
      jsonDecode(
        '{"repo":true,"detached":true,"staged":[],"unstaged":[],"untracked":[]}',
      ) as Map<String, dynamic>,
    );
    expect(status.branch, isNull);
    expect(status.branchLabel, '游离 HEAD');
  });

  test('rename 保留源路径，文件名与目录分开', () {
    final change = GitFileChange.fromJson(
      jsonDecode(
        '{"path":"lib/src/new_name.dart","orig_path":"lib/src/old.dart","state":"renamed"}',
      ) as Map<String, dynamic>,
    );
    expect(change.state, GitFileState.renamed);
    expect(change.origPath, 'lib/src/old.dart');
    expect(change.name, 'new_name.dart');
    expect(change.directory, 'lib/src');
  });

  test('root 目录下的文件没有目录段', () {
    final change = GitFileChange.fromJson(
      jsonDecode('{"path":"README.md","state":"modified"}')
          as Map<String, dynamic>,
    );
    expect(change.name, 'README.md');
    expect(change.directory, isEmpty);
  });

  test('未知状态退化成已修改，不让整页解析失败', () {
    final change = GitFileChange.fromJson(
      jsonDecode('{"path":"a.dart","state":"some_future_state"}')
          as Map<String, dynamic>,
    );
    expect(change.state, GitFileState.modified);
  });

  test('diff 解析截断与二进制标记', () {
    final diff = GitDiffReport.fromJson(
      jsonDecode(
        '{"path":"a.png","staged":false,"text":"","truncated":true,'
        '"binary":true,"additions":0,"deletions":0}',
      ) as Map<String, dynamic>,
    );
    expect(diff.binary, isTrue);
    expect(diff.truncated, isTrue);
    expect(diff.text, isEmpty);
    expect(diff.path, 'a.png');
  });

  test('commits 分页解析 has_more', () {
    final page = GitCommitsPage.fromJson(
      jsonDecode(
        '{"commits":[{"hash":"abc1234","short_hash":"abc1234",'
        '"subject":"feat: 面板","author":"李四","time_ms":1700000001000}],'
        '"has_more":true}',
      ) as Map<String, dynamic>,
    );
    expect(page.hasMore, isTrue);
    expect(page.commits.single.subject, 'feat: 面板');
    expect(page.commits.single.hash, 'abc1234');
  });

  test('空对象也能解析成安全的默认值', () {
    final status = GitStatusReport.fromJson(const <String, dynamic>{});
    expect(status.repo, isFalse);
    expect(status.changeCount, 0);

    final page = GitCommitsPage.fromJson(const <String, dynamic>{});
    expect(page.commits, isEmpty);
    expect(page.hasMore, isFalse);
  });
}
