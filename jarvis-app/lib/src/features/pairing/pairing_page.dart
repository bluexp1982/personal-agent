import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/client_platform.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/session.dart';
import '../../core/tls_pinning.dart';

/// 首次配对页：填服务地址 + 配对码，提交后等本机确认。
///
/// 配对码由服务端在本机生成（`jarvis-service pair`），只在本机显示，
/// 因此客户端这边没有任何"自动批准"入口——这是有意设计。
class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({
    super.key,
    required this.initialServerUrl,
    this.initialCode = '',
  });

  final String initialServerUrl;

  /// 预填的配对码：只有开发模式（`dev.sh client` 注入参数后自动配对失败）会用到，
  /// 正常入口留空，行为不变。
  final String initialCode;

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  late final TextEditingController _server;
  late final TextEditingController _code;
  late final TextEditingController _deviceName;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 握手时观察到的服务端证书指纹（仅 https）。为空表示还没探测过，或服务走明文。
  String? _tlsFingerprint;

  /// 用户是否已核对指纹。明文 http 不需要核对，因此默认 true。
  bool _confirmed = true;
  bool _probing = false;
  String? _probeError;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.initialServerUrl);
    _server.addListener(_resetTrust);
    // 预填的码也走一遍格式化：终端打印的是 `ABCD-EFGH-JKLM`，用户看到的分组
    // 与输入框里的一致，才不会有"为什么少了两个横杠"的疑问。
    _code = TextEditingController(
      text: widget.initialCode.trim().isEmpty
          ? ''
          : PairingCodeInputFormatter()
                .formatEditUpdate(
                  TextEditingValue.empty,
                  TextEditingValue(text: widget.initialCode.trim()),
                )
                .text,
    );
    _deviceName = TextEditingController(text: _defaultDeviceName());
  }

  /// 地址一改，之前核对过的指纹就作废：那是另一台机器的证书。
  void _resetTrust() {
    if (_tlsFingerprint == null && _confirmed && _probeError == null) {
      return;
    }
    setState(() {
      _tlsFingerprint = null;
      _confirmed = true;
      _probeError = null;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  String _defaultDeviceName() {
    // 移动端不用主机名（通常就是 "localhost"），由 client_platform 给出可读名字。
    return deviceLabel(
      platform: defaultTargetPlatform,
      hostname: Platform.localHostname,
    );
  }

  String get _platform => platformName(defaultTargetPlatform);

  /// 手机端提示要具体到"填电脑的局域网地址"，桌面仍然是自己这台机器。
  String get _serverHint => isMobilePlatform(defaultTargetPlatform)
      ? 'https://192.168.1.10:8787'
      : kDesktopServerUrl;

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final serverUrl = _server.text.trim();

    // https 且还没核对过指纹：先只握手取证书，不把配对码发出去。
    // 顺序很重要——先发码再核对，等于把码交给了一个尚未确认身份的对端。
    if (isTlsUrl(serverUrl) && _tlsFingerprint == null) {
      setState(() {
        _probing = true;
        _probeError = null;
      });
      try {
        final fingerprint = await probeTlsFingerprint(serverUrl);
        setState(() {
          _probing = false;
          _tlsFingerprint = fingerprint;
          // 没有指纹说明证书被系统信任（公网证书），不需要人工核对。
          _confirmed = fingerprint == null;
        });
      } catch (error) {
        // 走统一的错误翻译：`No route to host` 与"端口没监听"处置动作不同，
        // 前者多半是手机的本地网络权限或网段不对，提示必须说到点上。
        setState(() {
          _probing = false;
          _probeError = isTlsFailure(error)
              ? '证书握手失败：$error'
              : ApiException.network(error, baseUrl: serverUrl).userMessage;
        });
      }
      if (_tlsFingerprint != null) {
        return; // 等用户核对并勾选后再点一次
      }
    }

    if (!_confirmed) {
      return;
    }

    await ref
        .read(pairingProvider.notifier)
        .start(
          serverUrl: serverUrl,
          code: normalizePairingCode(_code.text),
          deviceName: _deviceName.text.trim(),
          platform: _platform,
          pinnedFingerprint: _tlsFingerprint,
        );
  }

  bool get _blockedByTrust => !canSubmitPairing(
    serverUrl: _server.text.trim(),
    observedFingerprint: _tlsFingerprint,
    confirmed: _confirmed,
  );

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(pairingProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        '连接你的机器',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontSize: AppFontSize.displayLg,
                              fontWeight: AppWeight.semiBold,
                              color: AppPalette.of(context).text.primary,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '先在运行服务的机器上执行 jarvis-service pair 生成配对码，'
                        '再输入到这里。配对需要在本机确认，这是防止别人冒名配对的唯一手段。',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: AppFontSize.base,
                          color: AppPalette.of(context).text.secondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: '服务地址',
                          hintText: _serverHint,
                          helperText: isMobilePlatform(defaultTargetPlatform)
                              ? '填运行服务的电脑地址；手机与电脑需在同一局域网'
                              : null,
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) => serverUrlValidator(
                          value,
                          platform: defaultTargetPlatform,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _deviceName,
                        decoration: const InputDecoration(
                          labelText: '这台设备的名称',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            (value?.trim().isEmpty ?? true) ? '请填写设备名' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        // 粘贴终端里的 `FGDS-DE77-XUAQ` 会原样保留分组；
                        // 粘贴不带分隔符的 12 位也会被自动分组，省得用户自己数位数。
                        inputFormatters: <TextInputFormatter>[
                          PairingCodeInputFormatter(),
                        ],
                        // 只在离开输入框时校验：边打边报"还不到 12 位"太吵，
                        // 但提交失败后再补全也不会一直挂着旧的红字。
                        autovalidateMode: AutovalidateMode.onUnfocus,
                        decoration: const InputDecoration(
                          labelText: '配对码',
                          hintText: '如 FGDS-DE77-XUAQ',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => isValidPairingCode(value ?? '')
                            ? null
                            : '配对码是 12 位字母数字（连字符可省略）',
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_tlsFingerprint != null) ...<Widget>[
                        const SizedBox(height: 16),
                        _TrustCard(
                          fingerprint: _tlsFingerprint!,
                          confirmed: _confirmed,
                          onChanged: (value) =>
                              setState(() => _confirmed = value),
                        ),
                      ],
                      if (_probeError != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _probeError!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.error),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed:
                            (pairing.isBusy || _probing || _blockedByTrust)
                            ? null
                            : _submit,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: (pairing.isBusy || _probing)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_blockedByTrust ? '先核对证书指纹' : '开始配对'),
                        ),
                      ),
                      if (pairing.phase != PairingPhase.idle) ...<Widget>[
                        const SizedBox(height: 20),
                        _StatusBanner(state: pairing),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 配对码输入格式化：统一大写、只保留字母数字、按 4 位分组显示。
///
/// 服务端终端打印的是 `FGDS-DE77-XUAQ` 这种分组形式，用户会直接粘贴，
/// 也可能记着连着敲 12 位。两种输入都收敛到同一个展示形式：
/// 不必手动删连字符，多敲的一位也会被丢掉，光标固定在末尾（最多 14 字符，
/// 中途编辑的收益不值得为它加一套光标映射）。
class PairingCodeInputFormatter extends TextInputFormatter {
  PairingCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final code = normalizePairingCode(newValue.text);
    final capped = code.length > kPairingCodeLength
        ? code.substring(0, kPairingCodeLength)
        : code;

    final buffer = StringBuffer();
    for (var start = 0; start < capped.length; start += 4) {
      if (start > 0) {
        buffer.write('-');
      }
      final end = start + 4 > capped.length ? capped.length : start + 4;
      buffer.write(capped.substring(start, end));
    }
    final text = buffer.toString();

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// 首次连接 https 服务时的信任确认。
///
/// 指纹必须由人对着服务端终端的输出核对——这是唯一能排除中间人的环节，
/// 因此不做"自动接受"，只提供一个必须勾选的确认项。
class _TrustCard extends StatelessWidget {
  const _TrustCard({
    required this.fingerprint,
    required this.confirmed,
    required this.onChanged,
  });

  final String fingerprint;
  final bool confirmed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '服务端证书指纹',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: AppFontSize.base,
              fontWeight: AppWeight.semiBold,
              color: AppPalette.of(context).text.primary,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            fingerprint,
            style: AppText.of(context)
                .mono(
                  size: AppFontSize.lg,
                  height: AppLineHeight.normal,
                  color: AppPalette.of(context).text.primary,
                )
                .copyWith(letterSpacing: AppLetterSpacing.display),
          ),
          const SizedBox(height: 6),
          Text(
            '在运行服务的机器上执行 jarvis-service pair，把这个指纹与终端输出比对。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: AppFontSize.sm,
              color: AppPalette.of(context).text.secondary,
            ),
          ),
          CheckboxListTile(
            value: confirmed,
            onChanged: (value) => onChanged(value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '我已核对，与终端显示的指纹一致',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends ConsumerWidget {
  const _StatusBanner({required this.state});

  final PairingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (state.phase) {
      PairingPhase.approved => (Icons.check_circle_outline, scheme.primary),
      PairingPhase.failed => (Icons.error_outline, scheme.error),
      _ => (Icons.hourglass_top, scheme.tertiary),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: AppFontSize.base),
                ),
                if (state.tlsFingerprint != null) ...<Widget>[
                  const SizedBox(height: 6),
                  SelectableText(
                    '证书指纹 ${state.tlsFingerprint}',
                    style: AppText.of(context).mono(
                      size: AppFontSize.sm,
                      height: AppLineHeight.tight,
                      color: AppPalette.of(context).text.secondary,
                    ),
                  ),
                ],
                if (state.fingerprint != null) ...<Widget>[
                  const SizedBox(height: 6),
                  SelectableText(
                    '服务端指纹 ${state.fingerprint}',
                    style: AppText.of(context).mono(
                      size: AppFontSize.sm,
                      height: AppLineHeight.tight,
                      color: AppPalette.of(context).text.secondary,
                    ),
                  ),
                ],
                // 指纹对不上时唯一正确的出路是"重新信任"：先清掉旧基准，再重新配对。
                if (state.code == 'tls_fingerprint_mismatch') ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () async {
                      await ref.read(sessionProvider.notifier).forgetDevice();
                      ref.read(pairingProvider.notifier).reset();
                    },
                    child: const Text('解除配对并重新核对'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
