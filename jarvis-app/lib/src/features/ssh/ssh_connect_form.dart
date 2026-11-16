import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ssh/ssh_models.dart';

/// SSH 段未连接时的连接卡片。
///
/// 表单里没有"主机 / 端口"：隧道终点由服务端配置决定（且必须是回环地址），
/// 让客户端填只会造出"填了却连不上"的困惑，也会把服务端变成跳板。
class SshConnectForm extends StatelessWidget {
  const SshConnectForm({
    super.key,
    required this.state,
    required this.username,
    required this.password,
    required this.obscurePassword,
    required this.rememberPassword,
    required this.onToggleObscure,
    required this.onToggleRemember,
    required this.onConnect,
    required this.onCancel,
    required this.onRetryProbe,
  });

  final SshState state;
  final TextEditingController username;
  final TextEditingController password;
  final bool obscurePassword;
  final bool rememberPassword;
  final VoidCallback onToggleObscure;
  final ValueChanged<bool> onToggleRemember;
  final VoidCallback onConnect;
  final VoidCallback onCancel;
  final VoidCallback onRetryProbe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppPalette.of(context).accent;
    final busy = state.isConnecting;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      // 宽屏下不要把表单横向拉满：输入框只有一两列内容，铺满整块反而更难读。
      // 560 是"两个输入框 + 一行说明"仍然舒展的宽度；窄屏 360 本来就到不了这个值。
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: accent.sshTint.withValues(alpha: 0.22)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: accent.sshTint.withValues(alpha: 0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Container(
                      width: 4,
                      decoration: BoxDecoration(gradient: accent.sshGradient),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _header(context),
                            const SizedBox(height: 14),
                            _targetLine(context),
                            const SizedBox(height: 16),
                            TextField(
                              controller: username,
                              enabled: !busy,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: _decoration(
                                context,
                                '用户名',
                                Icons.person_outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: password,
                              enabled: !busy,
                              obscureText: obscurePassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              onSubmitted: (_) => onConnect(),
                              decoration:
                                  _decoration(
                                    context,
                                    '密码',
                                    Icons.lock_outline,
                                  ).copyWith(
                                    suffixIcon: IconButton(
                                      tooltip: obscurePassword
                                          ? '显示密码'
                                          : '隐藏密码',
                                      onPressed: onToggleObscure,
                                      icon: Icon(
                                        obscurePassword
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                            ),
                            const SizedBox(height: 6),
                            // 不用 SwitchListTile：它要求最近的 Material 祖先来画水波纹，
                            // 而这张卡片是一个带渐变边框的 DecoratedBox，会触发
                            // "ListTile background color or ink splashes may be invisible"。
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        '记住密码',
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '保存在系统钥匙串；不勾选时密码只在本次运行内有效',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: rememberPassword,
                                  onChanged: busy ? null : onToggleRemember,
                                ),
                              ],
                            ),
                            if (state.message != null &&
                                !state.isConnected) ...<Widget>[
                              const SizedBox(height: 10),
                              _ErrorBanner(
                                message: state.message!,
                                onRetry: onRetryProbe,
                              ),
                            ],
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: _ConnectButton(
                                busy: busy,
                                gradient: accent.sshGradient,
                                onConnect: onConnect,
                                onCancel: onCancel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = palette.accent;
    final text = AppText.of(context);
    return Row(
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            gradient: accent.sshGradient,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(
            Icons.terminal,
            size: 18,
            color: palette.text.onAccent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'SSH 隧道',
                style: text.row.copyWith(fontWeight: AppWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '经已配对的通道登录服务端本机',
                style: text.meta.copyWith(color: palette.text.secondary),
              ),
            ],
          ),
        ),
        _TunnelChip(state: state, tint: accent.sshTint),
      ],
    );
  }

  Widget _targetLine(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = AppPalette.of(context).accent;
    final target = state.target.isEmpty ? '127.0.0.1:22' : state.target;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: accent.sshTint.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.dns_outlined, size: 15, color: accent.sshTint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '服务端本机 · $target',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.of(context)
                  .mono(size: AppFontSize.sm, height: AppLineHeight.tight),
            ),
          ),
          Text(
            '不可改',
            style: TextStyle(
              fontSize: AppFontSize.sm,
              color: AppPalette.of(context).text.tertiary,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(
    BuildContext context,
    String label,
    IconData icon,
  ) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      prefixIcon: Icon(icon, size: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    );
  }
}

/// 隧道可用性胶囊。预检还没回来时不显示"不可用"，否则每次进页面都会闪一下红。
class _TunnelChip extends StatelessWidget {
  const _TunnelChip({required this.state, required this.tint});

  final SshState state;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final status = palette.status;
    final (label, color) = switch (state) {
      _ when state.phase == SshPhase.connecting => ('连接中', status.info),
      _ when state.tunnelEnabled == false => ('隧道未开启', status.danger),
      _ when state.sshdReachable == false => ('sshd 不可达', status.warning),
      _ when state.tunnelEnabled == true && state.sshdReachable == true => (
        '隧道就绪',
        status.success,
      ),
      _ => ('检测中', status.neutral),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: status.borderOf(color)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              fontWeight: AppWeight.semiBold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final status = AppPalette.of(context).status;
    final error = status.danger;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: status.borderOf(error)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                height: AppLineHeight.code,
                color: error,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: error,
              minimumSize: const Size(48, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('重试', style: TextStyle(fontSize: AppFontSize.sm)),
          ),
        ],
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({
    required this.busy,
    required this.gradient,
    required this.onConnect,
    required this.onCancel,
  });

  final bool busy;
  final LinearGradient gradient;
  final VoidCallback onConnect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: gradient.colors.last.withValues(alpha: busy ? 0.16 : 0.32),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          // 连接中时这颗按钮变成"取消"：握手可能卡在隧道半通的状态，
          // 没有出口就只能等超时。
          onTap: busy ? onCancel : onConnect,
          child: SizedBox(
            height: 46,
            child: Center(
              child: busy
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.onAccent,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          '取消连接',
                          style: TextStyle(
                            color: AppColors.onAccent,
                            fontSize: AppFontSize.base,
                            fontWeight: AppWeight.semiBold,
                          ),
                        ),
                      ],
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.login_rounded,
                          size: 17,
                          color: AppColors.onAccent,
                        ),
                        SizedBox(width: 8),
                        Text(
                          '连接服务器',
                          style: TextStyle(
                            color: AppColors.onAccent,
                            fontSize: AppFontSize.base,
                            fontWeight: AppWeight.bold,
                            letterSpacing: AppLetterSpacing.tight,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
