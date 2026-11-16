import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/app_dialog.dart';

/// 打开新增 / 编辑模型配置的弹窗。返回 `true` 表示已经保存过。
///
/// 与「新建项目」同一套形态：居中的 [Dialog]、标题右侧的关闭按钮、
/// 标题下一行说明，三端（宽屏与手机窄屏）都用同一形态；内容超高时
/// 窗口内部滚动，键盘弹起由 [Dialog] 自己让位，这里不再叠 `viewInsets`。
Future<bool?> showModelEditDialog(
  BuildContext context, {
  ModelProfileView? existing,
}) {
  return showAppDialog<bool>(
    context,
    builder: (_) => ModelEditDialog(existing: existing),
  );
}

class ModelEditDialog extends ConsumerStatefulWidget {
  const ModelEditDialog({super.key, this.existing});

  /// `null` 表示新增。
  final ModelProfileView? existing;

  @override
  ConsumerState<ModelEditDialog> createState() => _ModelEditDialogState();
}

class _ModelEditDialogState extends ConsumerState<ModelEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiPath;
  late final TextEditingController _model;
  late final TextEditingController _modelName;
  late final TextEditingController _contextWindow;
  late final TextEditingController _apiKey;

  late bool _vision;
  late bool _reasoning;
  bool _testing = false;
  bool _saving = false;
  ModelTestResult? _testResult;

  /// 字段级错误：提交与测试时一起校验，逐条挂在输入框下面。
  String? _nameError;
  String? _baseUrlError;
  String? _modelError;
  String? _modelNameError;
  String? _contextWindowError;

  /// 新增配置时的默认上下文窗口，与服务端 `DEFAULT_CONTEXT_WINDOW` 一致。
  static const int _defaultContextWindow = 128000;

  /// 合法区间，与服务端 `MIN/MAX_CONTEXT_WINDOW` 一致。
  static const int _minContextWindow = 1000;
  static const int _maxContextWindow = 100000000;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _baseUrl = TextEditingController(text: existing?.baseUrl ?? '');
    _apiPath = TextEditingController(
      text: existing?.apiPath.isNotEmpty == true ? existing!.apiPath : '/v1',
    );
    _model = TextEditingController(text: existing?.model ?? '');
    _modelName = TextEditingController(text: existing?.modelName ?? '');
    // 旧服务端不下发该字段（读回 0）：按默认值回显，保存后就能用上环形。
    _contextWindow = TextEditingController(
      text:
          '${existing == null || existing.contextWindow <= 0 ? _defaultContextWindow : existing.contextWindow}',
    );
    // 密钥永不回显：编辑态留空，空表示"不改动"。
    _apiKey = TextEditingController();
    _vision = existing?.vision ?? false;
    // 新增默认关闭：第三方网关多数不认 `reasoning_effort`，硬发只会 400。
    _reasoning = existing?.reasoning ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiPath.dispose();
    _model.dispose();
    _modelName.dispose();
    _contextWindow.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// 校验并写回字段级错误。返回是否可以继续。
  bool _validate() {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    final modelName = _modelName.text.trim();
    final contextWindowText = _contextWindow.text.trim();
    final contextWindow = int.tryParse(contextWindowText);

    setState(() {
      _nameError = name.isEmpty ? '填一个名字，方便在列表里区分' : null;
      _baseUrlError = baseUrl.isEmpty
          ? '必填，例如 https://api.deepseek.com'
          : (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://'))
          ? '必须以 http:// 或 https:// 开头'
          : baseUrl.endsWith('/chat/completions')
          ? '只填到域名，路径前缀交给下一栏'
          : _apiPath.text.contains('://')
          ? '路径前缀只填 /v1 这样的部分'
          : null;
      _modelError = model.isEmpty ? '必填，例如 deepseek-chat' : null;
      // 模型名可留空（列表回退显示模型ID），只挡超长；上限与服务端一致。
      _modelNameError = modelName.runes.length > 60 ? '最多 60 个字符' : null;
      _contextWindowError = contextWindowText.isEmpty
          ? '必填：输入栏的上下文占比要拿它当分母'
          : contextWindow == null
          ? '只能填数字，单位是 tokens'
          : (contextWindow < _minContextWindow ||
                contextWindow > _maxContextWindow)
          ? '需在 $_minContextWindow ~ $_maxContextWindow 之间'
          : null;
    });

    return _nameError == null &&
        _baseUrlError == null &&
        _modelError == null &&
        _modelNameError == null &&
        _contextWindowError == null;
  }

  Future<void> _test() async {
    if (_testing || _saving) {
      return;
    }
    if (!_validate()) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      _toast('还没连上服务端');
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final result = await client.testModel(
        id: widget.existing?.id,
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        apiPath: _apiPath.text.trim(),
        apiKey: _apiKey.text.trim(),
        reasoning: _reasoning,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _testResult = result;
        _testing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _testResult = ModelTestResult(ok: false, hint: _message(error));
        _testing = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || _testing) {
      return;
    }
    if (!_validate()) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      _toast('还没连上服务端');
      return;
    }

    setState(() => _saving = true);
    final key = _apiKey.text.trim();
    final contextWindow = int.parse(_contextWindow.text.trim());
    try {
      if (_isNew) {
        await client.createModel(
          name: _name.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          model: _model.text.trim(),
          modelName: _modelName.text.trim(),
          apiPath: _apiPath.text.trim(),
          apiKey: key.isEmpty ? null : key,
          vision: _vision,
          reasoning: _reasoning,
          contextWindow: contextWindow,
        );
      } else {
        await client.updateModel(
          widget.existing!.id,
          name: _name.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          model: _model.text.trim(),
          // 传空串即清空（列表回退模型ID）；不能因为留空就不传，否则旧名字留着。
          modelName: _modelName.text.trim(),
          apiPath: _apiPath.text.trim(),
          apiKey: key.isEmpty ? null : key,
          vision: _vision,
          reasoning: _reasoning,
          contextWindow: contextWindow,
        );
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      _toast(_message(error));
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _message(Object error) {
    if (error is ApiException) {
      return error.userMessage;
    }
    return '$error';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final existing = widget.existing;

    return AppDialog(
      title: _isNew ? '新增配置' : '编辑配置',
      subtitle: Text(
        '填一份 OpenAI 兼容网关的接入信息；密钥保存在服务端，'
        '保存后可在模型列表里切换使用。',
        style: text.hint,
      ),
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _field(
            controller: _name,
            label: '名称',
            hint: '例如 DeepSeek 官方',
            icon: Icons.label_outline,
            error: _nameError,
          ),
          const SizedBox(height: 14),
          _field(
            controller: _modelName,
            label: '模型名',
            hint: '例如 DeepSeek V3.2 Flash（可留空）',
            icon: Icons.badge_outlined,
            error: _modelNameError,
            helper: '给人看的名字；留空时列表显示模型ID',
          ),
          const SizedBox(height: 14),
          _field(
            controller: _model,
            label: '模型ID',
            hint: 'deepseek-chat',
            icon: Icons.memory,
            error: _modelError,
            helper: '发给上游的 model 字段，必须与网关侧的模型标识一致',
          ),
          const SizedBox(height: 14),
          _field(
            controller: _contextWindow,
            label: '上下文窗口',
            hint: '128000',
            icon: Icons.data_usage_rounded,
            error: _contextWindowError,
            keyboardType: TextInputType.number,
            helper:
                '单位 tokens，填模型的最大输入长度（1M 填 1000000）；'
                '用于输入栏的上下文占比环',
          ),
          const SizedBox(height: 14),
          _field(
            controller: _baseUrl,
            label: '网关地址',
            hint: 'https://api.deepseek.com',
            icon: Icons.link,
            error: _baseUrlError,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 14),
          _field(
            controller: _apiPath,
            label: '路径前缀',
            hint: '/v1',
            icon: Icons.route_outlined,
            helper: 'OpenAI 兼容网关通常是 /v1；百炼填 /compatible-mode/v1',
          ),
          const SizedBox(height: 14),
          _field(
            controller: _apiKey,
            label: 'API Key',
            hint: existing == null
                ? 'sk-…'
                : '留空表示不修改（当前：${existing.keyLabel}）',
            icon: Icons.key_outlined,
            obscure: true,
            helper: existing == null ? null : '密钥保存在服务端，界面不会回显；要换就重新填一把',
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.image_outlined,
              size: 18,
              color: palette.text.tertiary,
            ),
            title: Text('支持读图', style: text.row),
            subtitle: Text(
              '模型能吃 image_url 时再打开：关着的时候附件图片会换成一句说明',
              style: text.meta,
            ),
            value: _vision,
            onChanged: (value) => setState(() => _vision = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.psychology_outlined,
              size: 18,
              color: palette.text.tertiary,
            ),
            title: Text('支持推理等级', style: text.row),
            subtitle: Text(
              '网关认 reasoning_effort 时再打开：勾上后输入栏可选不思考 / 低 / 高 / 最高',
              style: text.meta,
            ),
            value: _reasoning,
            onChanged: (value) => setState(() => _reasoning = value),
          ),
          if (_testResult != null || _testing)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _testBanner(context, scheme, text, palette),
            ),

          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing || _saving ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _testing || _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _testBanner(
    BuildContext context,
    ColorScheme scheme,
    AppText text,
    AppPalette palette,
  ) {
    final result = _testResult;
    final (color, icon, message) = _testing
        ? (palette.text.tertiary, Icons.sync, '正在向网关发一次极小请求…')
        : result == null
        ? (palette.text.tertiary, Icons.info_outline, '')
        : result.ok
        ? (palette.status.success, Icons.check_circle_outline, result.userText)
        : (palette.status.danger, Icons.error_outline, result.userText);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(message, style: text.meta.copyWith(color: color)),
        ),
      ],
    );
  }

  /// 与「新建项目」同名输入框同一形态：标签在框内、前置图标、默认描边圆角。
  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    String? helper,
    String? error,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        errorText: error,
        errorMaxLines: 2,
        border: const OutlineInputBorder(),
        prefixIcon: Icon(icon),
      ),
    );
  }
}
