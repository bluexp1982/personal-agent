import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import 'code_task_prefs.dart';

/// 编码任务只需要一个输入：要改什么。
///
/// 仓库路径由项目提供，不再让用户手输——同一个目录写两遍（项目 + 任务）
/// 迟早会写出不一致，而任务真正的执行边界必须是项目那一个。
/// 服务端也会覆盖 `input.repo`，客户端这里的只读展示只是让人确认"改的是哪儿"。
class CodeTaskInput {
  const CodeTaskInput({
    required this.instruction,
    this.provider,
    this.modelTier,
  });

  final String instruction;

  /// 显式指定的编码 CLI。为空表示交给服务端按任务形态路由。
  final String? provider;

  /// 显式指定的模型档位（`fast` / `strong`）。为空同上。
  final String? modelTier;
}

/// 把弹窗结果并进任务的 `input`。
///
/// 所有发起编码任务的入口都走这里：手写两次 map 迟早会漏键，而漏掉 `provider`
/// 的表现是"用户选了却没生效"——最难查的一种失败。
Map<String, dynamic> codeTaskInputJson({
  required CodeTaskInput input,
  required String approval,
  Map<String, dynamic> base = const <String, dynamic>{},
}) {
  return <String, dynamic>{
    ...base,
    'instruction': input.instruction,
    'approval': approval,
    if (input.provider != null) 'provider': input.provider,
    if (input.modelTier != null) 'model_tier': input.modelTier,
  };
}

Future<CodeTaskInput?> showCodeTaskInputDialog(
  BuildContext context, {
  String? projectPath,
  String? initialInstruction,
  CodeProvidersView? providers,
}) {
  return showDialog<CodeTaskInput>(
    context: context,
    builder: (_) => _CodeTaskDialog(
      projectPath: projectPath,
      initialInstruction: initialInstruction,
      providers: providers,
    ),
  );
}

class _CodeTaskDialog extends ConsumerStatefulWidget {
  const _CodeTaskDialog({
    this.projectPath,
    this.initialInstruction,
    this.providers,
  });

  final String? projectPath;
  final String? initialInstruction;

  /// 服务端上报的能力清单。为空（未拉到 / 老服务端）时不显示执行方式选择：
  /// 少一个开关，也比给一个"选了却不生效"的开关好。
  final CodeProvidersView? providers;

  @override
  ConsumerState<_CodeTaskDialog> createState() => _CodeTaskDialogState();
}

class _CodeTaskDialogState extends ConsumerState<_CodeTaskDialog> {
  late final TextEditingController _instruction = TextEditingController(
    text: widget.initialInstruction ?? '',
  );

  /// `null` 表示"自动（按任务路由）"。
  String? _provider;

  /// `null` 表示按任务形态自动选档位。
  String? _tier;

  /// 上次选择是异步读出来的。读回来之前不画选择器：`DropdownButtonFormField`
  /// 的 `initialValue` 只在首帧生效，先画再改会出现"回填了但框里还是自动"。
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  bool get _ready => _instruction.text.trim().isNotEmpty;

  /// 能真正派单的 CLI（已启用且装了可执行文件）。
  List<CodeProviderView> get _runnable =>
      widget.providers?.runnable ?? const <CodeProviderView>[];

  /// 只有一个能跑时不给下拉：那是假选择，选了也换不了东西。
  bool get _canPickProvider => _runnable.length > 1;

  /// 两个档位指向同一个模型时也没有选择的意义。
  bool get _canPickTier {
    final providers = widget.providers;
    if (providers == null) {
      return false;
    }
    return providers.fastModel.isNotEmpty &&
        providers.fastModel != providers.strongModel;
  }

  Future<void> _restore() async {
    final choice = widget.providers == null
        ? const CodeTaskChoice()
        : await ref.read(codeTaskPrefsProvider).read();
    if (!mounted) {
      return;
    }
    setState(() {
      _provider = _usableProvider(choice.provider);
      _tier = _canPickTier ? choice.modelTier : null;
      _restored = true;
    });
  }

  /// 回填前校验可用性：CLI 被卸载或被显式禁用后，不该留一个必然失败的选择。
  String? _usableProvider(String? id) {
    if (id == null || !_canPickProvider) {
      return null;
    }
    return _runnable.any((provider) => provider.id == id) ? id : null;
  }

  /// 只记住这次真正给过用户选择权的那一项：没出现下拉时用"自动"去覆盖旧值，
  /// 等于把用户上次的选择悄悄抹掉。
  void _remember() {
    final prefs = ref.read(codeTaskPrefsProvider);
    if (_canPickProvider) {
      unawaited(prefs.saveProvider(_provider));
    }
    if (_canPickTier) {
      unawaited(prefs.saveModelTier(_tier));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('编码任务'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.projectPath?.isNotEmpty == true
                            ? widget.projectPath!
                            : '由当前项目提供仓库目录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.of(context).mono(
                          size: AppFontSize.sm,
                          height: AppLineHeight.tight,
                          color: AppPalette.of(context).text.tertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _instruction,
                onChanged: (_) => setState(() {}),
                minLines: 3,
                maxLines: 6,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '要改什么',
                  hintText: '例如：修复登录过期后没有跳回首页的问题',
                  border: OutlineInputBorder(),
                ),
              ),
              ..._routingRows(context),
              const SizedBox(height: 8),
              Text(
                '改动会在独立工作树里完成，你确认后才合并回原分支',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _ready
              ? () {
                  _remember();
                  Navigator.of(context).pop(
                    CodeTaskInput(
                      instruction: _instruction.text.trim(),
                      provider: _provider,
                      modelTier: _tier,
                    ),
                  );
                }
              : null,
          child: const Text('创建'),
        ),
      ],
    );
  }

  /// 执行方式与档位。两者都可以留空——留空即"服务端按任务形态路由"。
  List<Widget> _routingRows(BuildContext context) {
    if (widget.providers == null || !_restored) {
      return const <Widget>[];
    }
    final runnable = _runnable;
    final rows = <Widget>[];
    if (_canPickProvider) {
      rows.add(const SizedBox(height: 12));
      rows.add(
        DropdownButtonFormField<String?>(
          initialValue: _provider,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '执行方式',
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<String?>>[
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('自动（按任务形态选择）'),
            ),
            for (final provider in runnable)
              DropdownMenuItem<String?>(
                value: provider.id,
                child: Text(provider.label),
              ),
          ],
          onChanged: (value) => setState(() => _provider = value),
        ),
      );
    }
    // 两个档位指向同一个模型时没有选择的意义，干脆不显示。
    if (_canPickTier) {
      rows.add(const SizedBox(height: 12));
      rows.add(
        DropdownButtonFormField<String?>(
          initialValue: _tier,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '模型档位',
            border: OutlineInputBorder(),
          ),
          items: const <DropdownMenuItem<String?>>[
            DropdownMenuItem<String?>(value: null, child: Text('自动')),
            DropdownMenuItem<String?>(value: 'fast', child: Text('快档（省 token）')),
            DropdownMenuItem<String?>(value: 'strong', child: Text('强档（更稳）')),
          ],
          onChanged: (value) => setState(() => _tier = value),
        ),
      );
    }
    return rows;
  }
}
