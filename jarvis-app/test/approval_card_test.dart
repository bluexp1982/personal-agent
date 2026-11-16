import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/tasks/approval_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ApprovalView _toolApproval({bool rememberable = true, String id = 'apr_tool'}) {
  return ApprovalView.fromJson(<String, dynamic>{
    'id': id,
    'task_id': 'task_1',
    'action': 'code.tool_use',
    'scope': 'tool',
    'expires_at': DateTime.now().millisecondsSinceEpoch + 60000,
    'tool': <String, dynamic>{
      'name': 'Bash',
      'risk': 'irreversible_write',
      'digest': 'python3 -c "import json"',
      'rememberable': rememberable,
    },
  });
}

ApprovalView _taskApproval() {
  return ApprovalView.fromJson(<String, dynamic>{
    'id': 'apr_task',
    'task_id': 'task_1',
    'action': 'merge_changes',
    'scope': 'task',
    'target': 'agent/task_1',
    'impact': '改动不可撤销',
    'expires_at': DateTime.now().millisecondsSinceEpoch + 60000,
  });
}

Widget _harness(
  ApprovalView approval, {
  void Function(bool remember, String? scope)? onApprove,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ApprovalCard(
          approval: approval,
          busy: false,
          onApprove: onApprove ?? (_, _) {},
          onReject: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('可记忆的工具审批提供勾选，勾上后放行回传 true', (tester) async {
    bool? remembered;
    await tester.pumpWidget(
      _harness(_toolApproval(), onApprove: (value, _) => remembered = value),
    );

    expect(find.text('记住这类操作，不再重复询问'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('放行这一步'));
    await tester.pump();

    expect(remembered, isTrue);
  });

  testWidgets('不可记忆的工具审批不显示勾选，放行回传 false', (tester) async {
    bool? remembered;
    await tester.pumpWidget(
      _harness(
        _toolApproval(rememberable: false),
        onApprove: (value, _) => remembered = value,
      ),
    );

    expect(find.text('记住这类操作，不再重复询问'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('放行这一步'));
    await tester.pump();

    expect(remembered, isFalse);
  });

  testWidgets('任务级审批（合并确认）不出现勾选', (tester) async {
    await tester.pumpWidget(_harness(_taskApproval()));

    expect(find.text('批准并继续'), findsOneWidget);
    expect(find.text('记住这类操作，不再重复询问'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('换一张审批单会清空上一次的勾选', (tester) async {
    await tester.pumpWidget(_harness(_toolApproval(id: 'apr_1')));

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    await tester.pumpWidget(_harness(_toolApproval(id: 'apr_2')));
    await tester.pump();

    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isFalse,
      reason: '上一张卡的"记住"不该顺延到另一条规则',
    );
  });
}
