import 'dart:io';

import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/tasks/code_task_input_dialog.dart';
import 'package:jarvis_app/src/features/tasks/code_task_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能力清单的替身：只控制"哪些能跑"，其余字段照服务端结构给。
CodeProvidersView _providers({
  List<String> runnable = const <String>['opencode', 'codex'],
  String fastModel = '',
  String strongModel = '',
}) {
  const all = <String>['opencode', 'codebuddy', 'codex', 'claude'];
  return CodeProvidersView(
    defaultProvider: 'opencode',
    available: runnable,
    providers: <CodeProviderView>[
      for (final id in all)
        CodeProviderView(
          id: id,
          enabled: true,
          available: runnable.contains(id),
        ),
    ],
    fastModel: fastModel,
    strongModel: strongModel,
  );
}

class _ResultBox {
  CodeTaskInput? value;
}

class _Harness extends StatelessWidget {
  const _Harness({required this.providers, required this.result});

  final CodeProvidersView? providers;
  final _ResultBox result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result.value = await showCodeTaskInputDialog(
              context,
              projectPath: '/work/repo',
              providers: providers,
            );
          },
          child: const Text('打开'),
        ),
      ),
    );
  }
}

/// 每个用例一份独立回退目录：偏好是"记住上次选择"，用例之间不能互相影响。
SecretStore _store() {
  final dir = Directory.systemTemp.createTempSync('code-task-dialog-test');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return SecretStore(fallbackDirectory: dir);
}

Future<void> _pump(
  WidgetTester tester, {
  required SecretStore store,
  required _ResultBox result,
  CodeProvidersView? providers,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [secretStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: _Harness(providers: providers, result: result),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开'));
  // 上次选择是异步读出来的，多等一帧才画得出选择器。
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, {String instruction = '修个 bug'}) async {
  await tester.enterText(find.byType(TextField), instruction);
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, '创建'));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String label) async {
  // 收起态按钮上显示的是当前选项，点它就是展开。
  await tester.tap(find.text('自动（按任务形态选择）'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('多个可跑的 CLI 才给执行方式下拉', (tester) async {
    final result = _ResultBox();
    await _pump(
      tester,
      store: _store(),
      result: result,
      providers: _providers(),
    );
    await _open(tester);

    expect(find.text('执行方式'), findsOneWidget);
    expect(find.text('要改什么'), findsOneWidget);
    expect(
      find.text('模型档位'),
      findsNothing,
      reason: '快档与强档指向同一个模型时不显示档位',
    );
  });

  testWidgets('只有一个可跑的 CLI 时不显示下拉', (tester) async {
    final result = _ResultBox();
    await _pump(
      tester,
      store: _store(),
      result: result,
      providers: _providers(runnable: const <String>['opencode']),
    );
    await _open(tester);

    expect(
      find.text('执行方式'),
      findsNothing,
      reason: '只有一个选项的开关是假选择，不如不给',
    );
  });

  testWidgets('没拿到能力清单时退回纯输入框', (tester) async {
    final result = _ResultBox();
    await _pump(tester, store: _store(), result: result);
    await _open(tester);

    expect(find.text('执行方式'), findsNothing);
    expect(find.text('模型档位'), findsNothing);

    await _submit(tester);
    expect(result.value?.instruction, '修个 bug');
    expect(result.value?.provider, isNull);
  });

  testWidgets('选中 CLI 后创建，把 provider 带进结果', (tester) async {
    final result = _ResultBox();
    await _pump(
      tester,
      store: _store(),
      result: result,
      providers: _providers(),
    );
    await _open(tester);

    await _pick(tester, 'Codex');
    await _submit(tester);

    expect(result.value?.provider, 'codex');
    expect(result.value?.modelTier, isNull);
  });

  testWidgets('上次选过的 CLI 会回填', (tester) async {
    final store = _store();
    await CodeTaskPrefs(store).saveProvider('codex');

    final result = _ResultBox();
    await _pump(tester, store: store, result: result, providers: _providers());
    await _open(tester);

    await _submit(tester);
    expect(
      result.value?.provider,
      'codex',
      reason: '不回填的话，用户每次都要重新选一遍',
    );
  });

  testWidgets('上次的选择已经不可用时退回自动', (tester) async {
    final store = _store();
    await CodeTaskPrefs(store).saveProvider('claude');

    final result = _ResultBox();
    await _pump(
      tester,
      store: store,
      result: result,
      providers: _providers(runnable: const <String>['opencode', 'codex']),
    );
    await _open(tester);

    await _submit(tester);
    expect(
      result.value?.provider,
      isNull,
      reason: '卸载或禁用之后不能留一个必然失败的选择',
    );
  });

  testWidgets('创建时记住选择，改回自动会清掉', (tester) async {
    final store = _store();
    final prefs = CodeTaskPrefs(store);
    final result = _ResultBox();
    await _pump(tester, store: store, result: result, providers: _providers());

    await _open(tester);
    await _pick(tester, 'Codex');
    await _submit(tester);
    expect((await prefs.read()).provider, 'codex');

    await _open(tester);
    await _pick(tester, '自动（按任务形态选择）');
    await _submit(tester);
    expect(
      (await prefs.read()).provider,
      isNull,
      reason: '留着旧值会让下次打开回填一个用户已经放弃的选择',
    );
  });

  testWidgets('档位可选时会回填，并且只记住档位', (tester) async {
    final store = _store();
    await CodeTaskPrefs(store).saveModelTier('fast');

    final result = _ResultBox();
    await _pump(
      tester,
      store: store,
      result: result,
      providers: _providers(fastModel: 'fast-model', strongModel: 'strong-model'),
    );
    await _open(tester);

    expect(find.text('模型档位'), findsOneWidget);
    await _submit(tester);
    expect(result.value?.modelTier, 'fast');
  });

  test('codeTaskInputJson 合并 base，且只写有值的键', () {
    final merged = codeTaskInputJson(
      input: const CodeTaskInput(instruction: '修个 bug', provider: 'codex'),
      approval: 'auto',
      base: const <String, dynamic>{'hint': 1},
    );
    expect(merged, <String, dynamic>{
      'hint': 1,
      'instruction': '修个 bug',
      'approval': 'auto',
      'provider': 'codex',
    });

    final auto = codeTaskInputJson(
      input: const CodeTaskInput(instruction: '修个 bug'),
      approval: 'request',
    );
    expect(auto.containsKey('provider'), isFalse);
    expect(auto.containsKey('model_tier'), isFalse);
  });
}
