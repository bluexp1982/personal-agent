import 'package:jarvis_app/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务详情里的「工作树」区块依赖这个字段：解析错了就整块消失。
/// 老数据没有它，所以解析必须容忍缺字段。
void main() {
  Map<String, dynamic> taskJson({Object? worktree}) {
    return <String, dynamic>{
      'id': 'task_1',
      'conversation_id': 'conv_1',
      'type': 'skill:code-task',
      'skill': 'code-task',
      'state': 'canceled',
      'retry_count': 0,
      'created_at': 1,
      'updated_at': 2,
      'worktree': ?worktree,
    };
  }

  test('解析现场：路径、分支与存在性', () {
    final task = TaskView.fromJson(
      taskJson(
        worktree: <String, dynamic>{
          'path': '/data/worktrees/task_1/wt',
          'branch': 'agent/task_1',
          'exists': true,
        },
      ),
    );

    expect(task.worktree, isNotNull);
    expect(task.worktree!.path, '/data/worktrees/task_1/wt');
    expect(task.worktree!.branch, 'agent/task_1');
    expect(task.worktree!.exists, isTrue);
    expect(task.isTerminal, isTrue, reason: '取消的任务应可清理');
  });

  test('清理过的现场 exists=false', () {
    final task = TaskView.fromJson(
      taskJson(
        worktree: <String, dynamic>{
          'path': '/data/worktrees/task_1/wt',
          'branch': 'agent/task_1',
          'exists': false,
        },
      ),
    );
    expect(task.worktree!.exists, isFalse);
  });

  test('普通任务没有现场字段', () {
    final task = TaskView.fromJson(taskJson());
    expect(task.worktree, isNull, reason: '没有该字段时不该凭空造一个区块');
  });

  test('字段形状不对时按没有现场处理', () {
    final task = TaskView.fromJson(taskJson(worktree: 'not-a-map'));
    expect(task.worktree, isNull);
  });

  test('缺 exists 时默认 false（宁可显示"已清理"，也不要显示可清理）', () {
    final task = TaskView.fromJson(
      taskJson(worktree: <String, dynamic>{'path': '/x', 'branch': 'agent/x'}),
    );
    expect(task.worktree!.exists, isFalse);
  });
}
