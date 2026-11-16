import 'package:jarvis_app/src/features/conversations/approval_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认是「请求审批」，与改造前行为一致', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(composerApprovalProvider('conv_a')),
      ApprovalModes.request,
    );
  });

  test('切换后能读回，且只影响本会话', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(composerApprovalProvider('conv_a').notifier)
        .select(ApprovalModes.auto);

    expect(
      container.read(composerApprovalProvider('conv_a')),
      ApprovalModes.auto,
    );
    expect(
      container.read(composerApprovalProvider('conv_b')),
      ApprovalModes.request,
      reason: '另一个会话不该被带着放宽审批',
    );
  });

  test('认不出来的值不生效', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(
      composerApprovalProvider('conv_a').notifier,
    );
    notifier.select('full-access');
    notifier.select('');

    expect(
      container.read(composerApprovalProvider('conv_a')),
      ApprovalModes.request,
    );
  });

  test('文案与说明跟着模式走', () {
    expect(ApprovalModes.labelOf(ApprovalModes.request), '请求审批');
    expect(ApprovalModes.labelOf(ApprovalModes.auto), '帮我审批');
    expect(ApprovalModes.labelOf(ApprovalModes.trust), '完全放行');
    expect(ApprovalModes.describe(ApprovalModes.auto), contains('风险操作'));
    expect(ApprovalModes.describe(ApprovalModes.request), contains('都问你'));
    expect(ApprovalModes.describe(ApprovalModes.trust), contains('合并'));
  });

  test('第三档「完全放行」可切换，且只影响本会话', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(composerApprovalProvider('conv_a').notifier)
        .select(ApprovalModes.trust);

    expect(
      container.read(composerApprovalProvider('conv_a')),
      ApprovalModes.trust,
    );
    expect(
      container.read(composerApprovalProvider('conv_b')),
      ApprovalModes.request,
      reason: '完全放行必须按会话隔离',
    );
  });
}
