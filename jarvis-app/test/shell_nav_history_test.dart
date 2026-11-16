import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 纯控制器用例：不建 widget 树、不出网，只验证"后退 / 前进"这套栈语义。

const Project _w1 = Project(
  id: 'w1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

const Project _w2 = Project(
  id: 'w2',
  name: '周报整理',
  mode: ProjectModes.work,
  path: '/tmp/weekly',
);

ConversationTarget _conversation(
  Project project, {
  String id = 'c1',
  String title = '会话一',
}) {
  return ConversationTarget(
    projectId: project.id,
    conversationId: id,
    title: title,
    projectPath: project.path,
    project: project,
  );
}

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  ShellTargetController targets() =>
      container.read(shellTargetProvider.notifier);
  ShellNavHistory history() => container.read(shellNavHistoryProvider);
  ShellTarget? current() => container.read(shellTargetProvider);

  /// 一路后退到退不动为止，返回途经的每一页。
  ///
  /// 断言"某个东西没留在历史里"时只能这样看：单看一步是否可退，
  /// 分不清被剪掉的是不该留的那条还是别的。
  List<ShellTarget?> drainBack(ShellTargetController controller) {
    final visited = <ShellTarget?>[];
    while (controller.goBack()) {
      visited.add(current());
    }
    return visited;
  }

  test('初始没有历史：两枚按钮都不可用，点了也不动', () {
    expect(history(), const ShellNavHistory());
    expect(targets().goBack(), isFalse);
    expect(targets().goForward(), isFalse);
    expect(current(), isNull);
  });

  test('选中一页就能退回空态，再前进回来', () {
    final controller = targets();

    controller.select(const ProjectTarget(_w1));
    expect(current(), const ProjectTarget(_w1));
    expect(history().canGoBack, isTrue);
    expect(history().canGoForward, isFalse);

    expect(controller.goBack(), isTrue);
    expect(current(), isNull, reason: '第一页之前是空态，空态也是一页');
    expect(history().canGoBack, isFalse);
    expect(history().canGoForward, isTrue);

    expect(controller.goForward(), isTrue);
    expect(current(), const ProjectTarget(_w1));
    expect(history().canGoForward, isFalse);
  });

  test('连续后退再连续前进，顺序与浏览顺序相反', () {
    final controller = targets();
    final conversation = _conversation(_w1);

    controller.select(const ProjectTarget(_w1));
    controller.select(conversation);
    controller.select(const ProjectTarget(_w2));

    expect(controller.goBack(), isTrue);
    expect(current(), conversation);
    expect(controller.goBack(), isTrue);
    expect(current(), const ProjectTarget(_w1));
    expect(controller.goBack(), isTrue);
    expect(current(), isNull);
    expect(controller.goBack(), isFalse, reason: '退到底之后再点没有副作用');

    expect(controller.goForward(), isTrue);
    expect(current(), const ProjectTarget(_w1));
    expect(controller.goForward(), isTrue);
    expect(current(), conversation);
    expect(controller.goForward(), isTrue);
    expect(current(), const ProjectTarget(_w2));
    expect(controller.goForward(), isFalse);
  });

  test('重复选中当前页不产生历史', () {
    final controller = targets();

    controller.select(const ProjectTarget(_w1));
    controller.select(const ProjectTarget(_w1));

    expect(controller.goBack(), isTrue);
    expect(current(), isNull);
    expect(controller.goBack(), isFalse, reason: '只应记住"空态 → w1"这一条');
  });

  test('后退之后另选一页：前进方向作废', () {
    final controller = targets();

    controller.select(const ProjectTarget(_w1));
    controller.select(const ProjectTarget(_w2));
    expect(controller.goBack(), isTrue);
    expect(current(), const ProjectTarget(_w1));
    expect(history().canGoForward, isTrue);

    controller.select(_conversation(_w2));
    expect(history().canGoForward, isFalse, reason: '从这里分叉了，原来那条往前的路不再成立');
  });

  test('关闭页面也算一次导航：后退能回到刚关掉的那一页', () {
    final controller = targets();

    controller.select(const ProjectTarget(_w1));
    controller.clear();
    expect(current(), isNull);
    expect(history().canGoBack, isTrue);

    expect(controller.goBack(), isTrue);
    expect(current(), const ProjectTarget(_w1));
  });

  test('会话页关闭后回到项目，后退能回到那个会话', () {
    final controller = targets();
    final conversation = _conversation(_w1);

    controller.select(const ProjectTarget(_w1));
    controller.select(conversation);
    controller.backToProject();
    expect(current(), const ProjectTarget(_w1));

    expect(controller.goBack(), isTrue);
    expect(current(), conversation);
  });

  test('改名同步历史：后退回去也是新标题', () {
    final controller = targets();
    final conversation = _conversation(_w1);

    controller.select(conversation);
    controller.select(const ProjectTarget(_w2));
    controller.retitle('c1', '会话二');
    expect(current(), const ProjectTarget(_w2));

    expect(controller.goBack(), isTrue);
    final restored = current();
    expect(restored, isA<ConversationTarget>());
    expect((restored! as ConversationTarget).title, '会话二');
  });

  test('删掉的会话从历史里剪干净', () {
    final controller = targets();
    controller.select(const ProjectTarget(_w1));
    controller.select(_conversation(_w1));

    // 删除的真实顺序：先回到项目（这时会把会话压进后退栈），再剪枝。
    controller.backToProject();
    controller.forgetConversation('c1');

    final visited = drainBack(controller);
    expect(
      visited.whereType<ConversationTarget>().where(
        (target) => target.conversationId == 'c1',
      ),
      isEmpty,
      reason: '不能后退到一个已经删除的会话',
    );
  });

  test('删掉的项目连同它名下的页面一起从历史里剪掉', () {
    final controller = targets();
    controller.select(const ProjectTarget(_w1));
    controller.select(_conversation(_w1));
    controller.select(const ProjectTarget(_w2));

    controller.clear();
    controller.forgetProject(_w1.id);

    final visited = drainBack(controller);
    expect(
      visited.where((target) => target?.projectId == _w1.id),
      isEmpty,
      reason: '项目删了，它名下的会话与项目页都不该还能退回去',
    );
    expect(visited, contains(const ProjectTarget(_w2)));
  });

  test('切换模式清空历史，且不留下可退的上一页', () {
    final controller = targets();
    controller.select(const ProjectTarget(_w1));
    controller.select(const ProjectTarget(_w2));
    controller.goBack();

    controller.reset();
    expect(current(), isNull);
    expect(history(), const ShellNavHistory());
    expect(controller.goBack(), isFalse);
    expect(controller.goForward(), isFalse);
  });

  test('历史深度有上限，最早的页面会被挤掉', () {
    final controller = targets();
    const total = ShellTargetController.historyLimit + 10;

    for (var i = 0; i < total; i++) {
      controller.select(
        ProjectTarget(
          Project(
            id: 'w$i',
            name: 'w$i',
            mode: ProjectModes.work,
            path: '/tmp/w$i',
          ),
        ),
      );
    }

    var steps = 0;
    while (controller.goBack()) {
      steps++;
    }
    expect(steps, ShellTargetController.historyLimit);
  });
}
