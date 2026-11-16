import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/session.dart';
import '../../core/ssh/ssh_controller.dart';
import 'settings_widgets.dart';

/// 设置页的「SSH 登录」卡片：保存一次账号密码，之后打开终端直接进 shell。
///
/// 密码写完就不再回显：只显示「已保存」状态，输入框留空表示不修改。
/// 与配对令牌同级敏感，读取一律走 `SecretStore`（钥匙串优先）。
class SshLoginCard extends ConsumerStatefulWidget {
  const SshLoginCard({super.key, required this.session});

  final SessionState session;

  @override
  ConsumerState<SshLoginCard> createState() => _SshLoginCardState();
}

class _SshLoginCardState extends ConsumerState<SshLoginCard> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 回填已保存的用户名。密码不回填：输入框里出现的每一个字符都必须是用户刚敲的。
  Future<void> _restore() async {
    final saved = await ref.read(sshSavedCredentialsProvider.future);
    if (!mounted || _username.text.isNotEmpty) {
      return;
    }
    setState(() {
      _username.text = saved.username;
    });
  }

  Future<void> _save() async {
    final username = _username.text.trim();
    final password = _password.text;
    final saved = ref.read(sshSavedCredentialsProvider).value;
    final hasPassword = saved?.hasPassword ?? false;

    if (username.isEmpty) {
      _toast('请填写用户名');
      return;
    }
    if (password.isEmpty && !hasPassword) {
      _toast('请填写密码：首次保存必须输入一次的登录密码');
      return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(sshSavedCredentialsProvider.notifier)
          .save(username: username, password: password);
      if (!mounted) {
        return;
      }
      _password.clear();
      _toast('SSH 凭据已保存，打开终端将自动登录');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await ref.read(sshSavedCredentialsProvider.notifier).clear();
      if (!mounted) {
        return;
      }
      _username.clear();
      _password.clear();
      _toast('已清除 SSH 凭据');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.session.isReady;
    final saved =
        ref.watch(sshSavedCredentialsProvider).value ??
        const SshSavedCredentials();
    final autoLogin = ref.watch(sshAutoLoginProvider);
    final editable = ready && !_busy;
    final hasSaved = saved.username.isNotEmpty || saved.hasPassword;

    return Card(
      child: Column(
        children: <Widget>[
          const SettingsCardHeader(
            icon: Icons.terminal_outlined,
            title: 'SSH 登录',
            subtitle: SettingsDescription('经已配对的通道登录服务端本机；保存后打开终端可直接进入 shell'),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _username,
                  enabled: editable,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  decoration: _decoration(
                    '用户名',
                    Icons.person_outline,
                    hint: '服务端这台电脑的登录账号',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: editable,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => editable ? _save() : null,
                  decoration:
                      _decoration(
                        '密码',
                        Icons.lock_outline,
                        hint: saved.hasPassword ? '已保存 · 留空表示不修改' : '登录密码',
                      ).copyWith(
                        helperText: saved.hasPassword
                            ? '已保存（不回显），填写新密码即覆盖'
                            : '首次保存需要填写密码',
                      ),
                ),
              ],
            ),
          ),
          SettingsSwitchRow(
            icon: Icons.bolt_outlined,
            title: '打开终端时自动登录',
            description: hasSaved
                ? '凭据已保存，打开终端时直接连接；失败会退回表单并说明原因'
                : '还没有保存凭据：先填好用户名与密码',
            value: autoLogin,
            onChanged: ready
                ? (value) =>
                      ref.read(sshAutoLoginProvider.notifier).setEnabled(value)
                : null,
          ),
          if (!ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '还没有配对服务端：完成配对后才能保存 SSH 凭据',
                  style: AppText.of(
                    context,
                  ).hint.copyWith(color: AppPalette.of(context).status.warning),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: <Widget>[
                FilledButton(
                  onPressed: editable ? _save : null,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: editable && hasSaved ? _clear : null,
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.of(context).status.danger,
                  ),
                  child: const Text('清除凭据'),
                ),
                const Spacer(),
                _SavedChip(hasSaved: hasSaved),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      prefixIcon: Icon(icon, size: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    );
  }
}

/// 「已保存 / 未保存」小标签。
///
/// 用它代替回显密码：用户需要的确定信息只有"到底存没存"。
/// 尺寸与设置页其它标签一致（[SettingsTag]），不再自带一套 11.5 的写法。
class _SavedChip extends StatelessWidget {
  const _SavedChip({required this.hasSaved});

  final bool hasSaved;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return SettingsTag(
      label: hasSaved ? '已保存' : '未保存',
      color: hasSaved ? palette.status.success : palette.text.secondary,
    );
  }
}
