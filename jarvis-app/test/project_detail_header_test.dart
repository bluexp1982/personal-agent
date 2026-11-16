import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/mobile_top_bar.dart';
import 'package:jarvis_app/src/features/projects/project_detail_page.dart';

/// 项目详情页头那枚「新建」圆钮：会话 Tab 建会话、任务 Tab 派任务。
///
/// 两个 Tab 共用一条页头，按钮是同一枚、只换图标与 tooltip。这里只守
/// "换 Tab 时语义跟着换"，具体创建流程由 `createConversation` /
/// `createTask` 各自的实现保证（走真实网络，不在 widget 测试里展开）。
const Project _project = Project(
  id: 'w1',
  name: 'code-001',
  mode: ProjectModes.work,
  path: '/tmp/code-001',
);

Future<void> _pump(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      // 不接真实服务：两个 Tab 的空态都不该因为拿不到数据而报错。
      overrides: [apiClientProvider.overrideWithValue(null)],
      child: const MaterialApp(home: ProjectDetailPage(project: _project)),
    ),
  );
  // 列表里可能有常驻的加载指示器，不用 `pumpAndSettle`。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('会话 Tab：页头是「新建会话」，「⋯」仍在最右', (tester) async {
    await _pump(tester);

    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(find.byTooltip('派一件事'), findsNothing);
    // 两个 Tab 共用同一枚「+」图标，语义只靠 tooltip 区分。
    expect(
      find.descendant(
        of: find.byTooltip('新建会话'),
        matching: find.byIcon(Icons.add),
      ),
      findsOneWidget,
    );

    final create = tester.getRect(find.byTooltip('新建会话'));
    final more = tester.getRect(find.byTooltip('项目操作'));
    expect(create.right, lessThanOrEqualTo(more.left), reason: '新建在「⋯」左侧');
    expect(more.left - create.right, 1, reason: '两格之间只有 1dp 分隔线');

    // 两枚并成一枚胶囊：外接矩形正好包住两格，整组只建一层背板。
    final group = find.byType(MobileTopBarButtonGroup);
    expect(group, findsOneWidget);
    expect(tester.getSize(group), const Size(77, 38));
    final capsule = tester.getRect(group);
    expect(capsule.left, create.left);
    expect(capsule.right, more.right);
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务 Tab：同一枚按钮换成「派一件事」，且不再重复出悬浮按钮', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('任务 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('派一件事'), findsOneWidget);
    expect(find.byTooltip('新建会话'), findsNothing);
    expect(
      find.byType(FloatingActionButton),
      findsNothing,
      reason: '页头已经有新建入口，底部不该再浮一枚「派一件事」',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('切回会话 Tab：按钮换回来', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('任务 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('会话 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
