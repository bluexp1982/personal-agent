import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/client_platform.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ssh/ssh_controller.dart';
import '../../core/ui/shell_icon_button.dart';
import '../../core/ssh/ssh_models.dart';
import '../shell/panel_fullscreen.dart';
import '../shell/pane_controls.dart';
import '../shell/shell_dividers.dart';
import '../shell/shell_layout_state.dart';
import '../shell/immersive_fullscreen.dart';
import 'ssh_connect_form.dart';
import 'ssh_key_bar.dart';
import 'ssh_terminal_view.dart';

/// 终端状态栏里的全屏按钮 Key。
///
/// 面板工具条上也有一个全屏按钮（同一个 tooltip），但两者已经不是同一个状态：
/// 这里进入「终端全屏」（原生全屏 + 藏掉所有界面），工具条那个仍是
/// 「面板吃掉中栏」。测试必须靠 Key 分清点的是哪一个，不能拿文案定位。
const Key kTerminalFullscreenKey = Key('ssh-terminal-fullscreen');

/// 终端：未连接是连接卡片，连接后整块变成终端。
///
/// 它是右侧面板里的一个标签页，不再是一层顶部模式——所以这里不画自己的栏头，
/// 标签栏由 [ProjectPanel] 提供。终端会话存在 provider 里（`ref.keepAlive()`），
/// 切标签、切模式或收起面板再回来时，重建的只是视图，shell 与滚动缓冲都还在。
class SshPage extends ConsumerStatefulWidget {
  const SshPage({
    super.key,
    this.showPaneToggles = false,
    this.allowFullscreen = true,
    this.immersive = false,
  });

  /// 状态栏两端挂左/右栏开合按钮。只在宽屏浮层面板里需要：
  /// 终端铺满中栏时这两个开关是唯一还能调整布局的入口。
  final bool showPaneToggles;

  /// 是否提供全屏入口。窄屏整页面板本身已经铺满整屏，再点全屏不会有任何变化，
  /// 留一个按下去没反应的按钮只会让人以为坏了。
  final bool allowFullscreen;

  /// 终端全屏（沉浸模式）已经生效：状态栏、快捷键条都要让位。
  ///
  /// 由 `ProjectPanel` 传进来，而不是在这里读 provider：整页面板也复用它，
  /// 而整页形态本来就不进沉浸模式。
  final bool immersive;

  @override
  ConsumerState<SshPage> createState() => _SshPageState();
}

class _SshPageState extends ConsumerState<SshPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  bool _remember = true;
  bool _obscure = true;
  bool _bootstrapped = false;

  /// 上一次自动登录用的凭据指纹。
  ///
  /// 同一份凭据只自动登录一次：终端页在 `IndexedStack` 里常驻，provider 每次
  /// 重新 emit（例如设置页保存了同样的值）都不该再拨一次号。
  String? _autoLoginSignature;

  /// 自动登录正在进行（已决定要连、还没出结果）。
  ///
  /// 它同时是"别把连接表单画出来"的开关：已保存凭据时表单只会闪一下就被提交，
  /// 看起来像界面在自作主张地替用户点了一次按钮。
  bool _autoLoginPending = false;

  /// 点了「重连」，正在走同一条无感路径。
  ///
  /// 它与自动登录的区别只是入口：都是"用户什么都没填，界面替他把上一次的
  /// 凭据再送一遍"，因此同样不该退回表单。
  bool _reconnecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final controller = ref.read(sshControllerProvider.notifier);
    SshAutoLoginPlan plan;
    try {
      plan = await controller.loadAutoLoginPlan();
    } on Object {
      // 读凭据失败不该让面板永远停在占位态：按"没有可用的自动登录"处理，
      // 交给用户手动填，比空白一片可诊断得多。
      plan = const SshAutoLoginPlan(
        credentials: SshSavedCredentials(),
        autoLogin: false,
        canAutoLogin: false,
      );
    }
    if (!mounted) {
      return;
    }
    _fillCredentials(plan.credentials);
    setState(() {
      _bootstrapped = true;
      // 有保存的密码说明上次勾了"记住密码"，沿用上次的选择。
      _remember = plan.credentials.hasPassword;
    });

    if (plan.canAutoLogin) {
      await _autoLogin(plan.credentials);
      return;
    }
    await controller.probe();
  }

  /// 回填表单。只在输入框为空时写：用户正在编辑的内容不该被异步结果覆盖。
  void _fillCredentials(SshSavedCredentials saved) {
    if (_username.text.isEmpty) {
      _username.text = saved.username;
    }
    if (_password.text.isEmpty) {
      _password.text = saved.password;
    }
  }

  /// 用已保存的凭据直接登录。
  ///
  /// 这里**不能再 probe 一次**：`connect()` 内部已经先预检再握手，两次探测并发
  /// 会互相覆盖状态（一个写"就绪"、一个写"检测中"）。
  Future<void> _autoLogin(SshSavedCredentials saved) async {
    if (_autoLoginPending) {
      return;
    }
    _autoLoginSignature = _signatureOf(saved);
    setState(() => _autoLoginPending = true);
    try {
      await ref
          .read(sshControllerProvider.notifier)
          .connect(
            username: saved.username,
            password: saved.password,
            rememberPassword: true,
          );
    } finally {
      if (mounted) {
        setState(() => _autoLoginPending = false);
      }
    }
  }

  /// 设置页改了凭据后补一次自动登录。
  ///
  /// 终端页常驻，保存凭据不会让它重新 `initState`；只有真的换了凭据且当前处于
  /// idle（没连着、也没在连）才连，已经开着的终端不该被"另一次登录"顶掉。
  Future<void> _maybeAutoLogin(SshSavedCredentials saved) async {
    if (!mounted || _autoLoginPending) {
      return;
    }
    if (ref.read(sshControllerProvider).phase != SshPhase.idle) {
      return;
    }
    final enabled = await ref.read(sshAutoLoginProvider.notifier).restore();
    if (!mounted || !enabled) {
      return;
    }
    if (ref.read(sshControllerProvider).phase != SshPhase.idle) {
      return;
    }
    if (_autoLoginSignature == _signatureOf(saved)) {
      return;
    }
    await _autoLogin(saved);
  }

  String _signatureOf(SshSavedCredentials saved) =>
      '${saved.username}\u0000${saved.password}';

  /// 从终端页点「重连」。
  ///
  /// 期间终端保持可见（只盖一层"正在重连"），不落回表单：用户看着自己的输出
  /// 点了一次按钮，结果界面翻出一张要他重新输密码的卡片，是最难解释的跳变。
  /// 只有真的没有任何可用凭据、或者重连失败，才回到表单。
  Future<void> _reconnect() async {
    if (_reconnecting) {
      return;
    }
    setState(() => _reconnecting = true);
    try {
      await ref.read(sshControllerProvider.notifier).reconnect();
    } finally {
      if (mounted) {
        setState(() => _reconnecting = false);
      }
    }
  }

  void _connect() {
    FocusScope.of(context).unfocus();
    final username = _username.text.trim();
    final password = _password.text;
    if (password.isEmpty && username.isNotEmpty) {
      _passwordFocus.requestFocus();
    }
    ref
        .read(sshControllerProvider.notifier)
        .connect(
          username: username,
          password: password,
          rememberPassword: _remember,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sshControllerProvider);
    final controller = ref.read(sshControllerProvider.notifier);
    // 两套全屏在这里汇合：
    // - `fullscreen`（旧）：面板吃掉中栏，入口在面板工具条，状态栏这里只负责退出；
    // - `immersive`（新）：窗口原生全屏 + 只剩终端，由 `ProjectPanel` 传进来，
    //   按钮只负责进入（进去之后状态栏本身就不在了）。
    final fullscreen = ref.watch(panelFullscreenProvider);
    final fullscreenController = ref.read(panelFullscreenProvider.notifier);
    final immersiveFullscreen = ref.read(immersiveFullscreenProvider.notifier);

    // 用户名可能由 provider 异步恢复（例如从设置页回来）：只在输入框为空时回填，
    // 否则会把用户正在编辑的内容覆盖掉。
    if (_bootstrapped && state.username.isNotEmpty && _username.text.isEmpty) {
      _username.text = state.username;
    }

    // 终端页在面板里常驻：设置页刚保存的凭据不会让这里重新 initState，
    // 只能靠 provider 通知补一次自动登录（已连着 / 正在连时什么都不做）。
    ref.listen<AsyncValue<SshSavedCredentials>>(sshSavedCredentialsProvider, (
      previous,
      next,
    ) {
      final saved = next.value;
      if (saved == null ||
          !saved.hasPassword ||
          saved.username.isEmpty ||
          !_bootstrapped) {
        return;
      }
      _fillCredentials(saved);
      if (!_remember) {
        setState(() => _remember = true);
      }
      unawaited(_maybeAutoLogin(saved));
    });

    // 重连期间同样留在终端页：已经断开时本来就是终端形态，连上就自然换回正常终端。
    final showTerminal =
        state.isConnected ||
        state.phase == SshPhase.disconnected ||
        _reconnecting;

    // 「还没决定要不要自动登录」和「自动登录正在进行」都不画表单。
    //
    // 否则用户会看到一张已经填好的登录卡片闪一下、自己按下去——明明什么都没点，
    // 界面却像替他做了决定。这段窗口只有几帧到一次握手的时间，占位用终端同底色。
    final autoLoggingIn = !_bootstrapped || _autoLoginPending;

    // 旧的「面板全屏」刻意不跟连接状态走：全屏属于面板，表单上方一直有标签栏，
    // 早先那句"回到表单就退出"只会让"全屏下打开终端"这种正常操作莫名掉出全屏。
    //
    // 新的「终端全屏」反过来必须退出：它把标签栏、左栏、状态栏全藏了，
    // 满屏只剩一张连接表单时，用户连"这是哪儿"都看不出来，也没有任何入口。
    if (!showTerminal && !autoLoggingIn && widget.immersive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        immersiveFullscreen.exit();
      });
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: showTerminal
          ? _TerminalPane(
              key: const ValueKey<String>('ssh-terminal'),
              state: state,
              terminal: controller.terminal,
              fullscreen: fullscreen,
              immersive: widget.immersive,
              reconnecting: _reconnecting,
              showPaneToggles:
                  widget.showPaneToggles && !fullscreen && !widget.immersive,
              allowFullscreen: widget.allowFullscreen,
              onExitFullscreen: fullscreenController.exit,
              onEnterTerminalFullscreen: () => unawaited(
                immersiveFullscreen.enter(ImmersiveSurface.panel),
              ),
              onExitTerminalFullscreen: immersiveFullscreen.exit,
              onReconnect: _reconnect,
              // 断开 = 停在终端页的「已断开」态（输出保留、中央浮出重新连接），
              // 与在远端敲 `exit` 完全同一条路径。旧的全屏属于面板，
              // 不跟着连接状态走（标签栏上一直有退出全屏的按钮）。
              onDisconnect: () => unawaited(controller.disconnect()),
            )
          : autoLoggingIn
          ? const _AutoLoginPlaceholder(key: ValueKey<String>('ssh-auto-login'))
          : SshConnectForm(
              key: const ValueKey<String>('ssh-form'),
              state: state,
              username: _username,
              password: _password,
              obscurePassword: _obscure,
              rememberPassword: _remember,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
              onToggleRemember: (value) => setState(() => _remember = value),
              onConnect: _connect,
              onCancel: controller.cancelConnect,
              onRetryProbe: () => controller.probe(),
            ),
    );
  }
}

/// 自动登录占位：与终端同底色，只有一枚小转圈。
///
/// 不画表单、也不画"连接中"的按钮：这一步用户什么都没点，界面上不该出现
/// 一个看起来可以点的东西。握手失败后才会正常回到表单并说明原因。
class _AutoLoginPlaceholder extends StatelessWidget {
  const _AutoLoginPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;
    return ColoredBox(
      color: palette.background,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: palette.chromeForeground,
          ),
        ),
      ),
    );
  }
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.state,
    required this.terminal,
    required this.fullscreen,
    required this.immersive,
    required this.reconnecting,
    required this.showPaneToggles,
    required this.allowFullscreen,
    required this.onExitFullscreen,
    required this.onEnterTerminalFullscreen,
    required this.onExitTerminalFullscreen,
    required this.onReconnect,
    required this.onDisconnect,
  });

  final SshState state;
  final Terminal terminal;

  /// 旧的面板全屏（面板吃掉中栏）。
  final bool fullscreen;

  /// 新的终端全屏（原生全屏 + 只剩终端）。
  final bool immersive;

  /// 正在重连：遮罩与状态栏文字都换成"重连中"。
  final bool reconnecting;

  final bool showPaneToggles;
  final bool allowFullscreen;
  final VoidCallback onExitFullscreen;
  final VoidCallback onEnterTerminalFullscreen;
  final VoidCallback onExitTerminalFullscreen;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  /// 选区控制器与输入焦点由这一层持有：状态栏上的「复制选中 / 粘贴」
  /// 要用到它们，终端视图只负责渲染。
  final TerminalController _terminalController = TerminalController();
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(covariant _TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进出沉浸模式时，状态栏上的按钮会被移除/加回来。焦点原本可能就在那颗
    // 按钮上——不补一次，回到终端后敲键盘没有任何反应，看起来像卡死了。
    if (oldWidget.immersive != widget.immersive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _terminalController.dispose();
    super.dispose();
  }

  Future<void> _copySelection() async {
    final range = _terminalController.selection;
    if (range == null) {
      _toast('先在终端里选中要复制的内容');
      return;
    }
    final text = widget.terminal.buffer.getText(range);
    if (text.isEmpty) {
      _toast('选中的内容为空');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();
    _toast('已复制');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    widget.terminal.paste(text);
    _focusNode.requestFocus();
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = isMobilePlatform(defaultTargetPlatform);

    // 三个槽位恒定存在（状态栏 / 终端 / 快捷键条）：沉浸模式只把它们换成
    // 零尺寸占位，绝不增删子节点——否则 `Expanded` 里的 `TerminalView`
    // 会跟着重新挂载，选区与滚动位置就没了。
    return Column(
      children: <Widget>[
        widget.immersive
            ? const SizedBox.shrink()
            : _StatusBar(
                state: widget.state,
                fullscreen: widget.fullscreen,
                reconnecting: widget.reconnecting,
                showPaneToggles: widget.showPaneToggles,
                allowFullscreen: widget.allowFullscreen,
                onEnterFullscreen: widget.onEnterTerminalFullscreen,
                onReconnect: widget.onReconnect,
                onDisconnect: widget.onDisconnect,
                onCopy: _copySelection,
                onPaste: _paste,
              ),
        Expanded(
          child: SshTerminalView(
            terminal: widget.terminal,
            controller: _terminalController,
            focusNode: _focusNode,
            disconnected: widget.state.phase == SshPhase.disconnected,
            reconnecting: widget.reconnecting,
            onReconnect: widget.onReconnect,
            // Esc 的归属按"最彻底的那个模式"来定：
            // 沉浸模式 → 退出沉浸；旧面板全屏 → 退出面板全屏；
            // 两者都不是时传 null，Esc 必须原样透传给远端（vim/less/tmux）。
            onExitFullscreen: widget.immersive
                ? widget.onExitTerminalFullscreen
                : widget.fullscreen
                ? widget.onExitFullscreen
                : null,
          ),
        ),
        // 移动端的快捷键条在全屏下也保留：虚拟键盘没有 Esc，这里是唯一的组合键入口。
        // 沉浸模式（桌面专属）里整条让位给终端。
        widget.immersive
            ? const SizedBox.shrink()
            : mobile
            ? SshKeyBar(
                terminal: widget.terminal,
                tint: AppPalette.of(context).accent.sshTint,
              )
            : const SizedBox.shrink(),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.state,
    required this.fullscreen,
    required this.reconnecting,
    required this.showPaneToggles,
    required this.allowFullscreen,
    required this.onEnterFullscreen,
    required this.onReconnect,
    required this.onDisconnect,
    required this.onCopy,
    required this.onPaste,
  });

  final SshState state;

  /// 正在重连：状态文字换成"重连中"，重连按钮置灰（上一次点击还在办）。
  final bool reconnecting;

  /// 旧的面板全屏：把纵向留白与按钮尺寸收紧，尽量把空间让给终端。
  final bool fullscreen;

  /// 宽屏浮层面板且非全屏时，状态栏两侧挂栏开合按钮。
  final bool showPaneToggles;

  /// 是否显示全屏按钮。窄屏整页面板里恒为 false。
  final bool allowFullscreen;

  /// 进入「终端全屏」。这颗按钮只负责进入：进去之后整条状态栏都不在了，
  /// 退出走 Esc（或窗口顶部的提示）。旧面板全屏的退出按钮在标签栏上。
  final VoidCallback onEnterFullscreen;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;

  /// 复制选中 / 粘贴：原来浮在终端右上角，现在并进这一行，靠右侧一组。
  final VoidCallback onCopy;
  final VoidCallback onPaste;

  /// 三枚动作按钮共用栏头规格：24 命中区 + 8dp 圆角方形悬停底。
  /// 全屏与非全屏不再分两套；全屏只收紧整条栏的 padding。
  static final ButtonStyle _actionStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  /// 复制 / 粘贴两枚字形的绘制缩放。
  ///
  /// 它们和前三枚同为 [kPaneHeaderIconSize]（14），但 Material 的
  /// `content_copy` / `content_paste` 是铺满 24 网格的实心字形，
  /// 而重连 / 断开 / 全屏都是四周留白较多的描边字形：同样字号下，
  /// 这两枚的墨迹要比那一组高出 2–3dp，并排时一眼就看得出"大一号"。
  /// 栏头规格（命中区 24、图标 14）不动，只把绘制收到 0.85，
  /// 让墨迹高度落回前三枚那档。
  static const double _filledGlyphScale = 0.85;

  @override
  Widget build(BuildContext context) {
    // 状态栏与终端同族取色：浅色主题下不能还挂着一条深色黑条。
    final shellPalette = AppPalette.of(context);
    final palette = shellPalette.terminal;
    // 三枚动作按钮的图标色跟项目页那排图标一致（第二档灰），
    // 不用终端的 tint / chromeForeground：前者在浅色栏上偏青、后者偏黑，
    // 一栏里两套色会让这三个按钮看起来像另一套控件。
    final actionColor = shellPalette.text.secondary;
    final status = shellPalette.status;
    final (dot, label) = switch (state.phase) {
      _ when reconnecting => (status.info, '重连中'),
      SshPhase.connected => (status.success, '已连接'),
      _ => (status.warning, '已断开'),
    };
    final target = state.target.isEmpty ? '服务端本机' : state.target;

    // 360dp 下这一行有五个元素：状态点 + 文本 + 重连 + 断开 + 全屏，
    // 再往右是「复制 / 粘贴」一组（中间隔一道竖线）。
    // 文本已经 Expanded + ellipsis。所有动作按钮与栏头同一套规格
    // （命中区 24、图标 14），不再按全屏与否派生尺寸：行高由 padding 决定，
    // 按钮自己不去撑整条栏。复制 / 粘贴的两枚实心字形只额外缩绘制，
    // 见 [_filledGlyphScale]。
    // 贴分隔线那一侧（左）要扣掉 8dp 栏缝：拖动条涂的是面板底色，
    // 视觉上那 8dp 已经算进面板。全屏与窄屏整页都没有栏缝，直接用统一内边距。
    final leftInset = !fullscreen && ShellDividerScope.isActive(context)
        ? kPaneEdgeInset
        : kPaneContentInset;
    final padding = fullscreen
        ? const EdgeInsets.fromLTRB(kPaneContentInset, 2, kPaneContentInset, 2)
        : EdgeInsets.fromLTRB(leftInset, 4, kPaneContentInset, 4);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(bottom: BorderSide(color: palette.chromeBorder)),
      ),
      child: Row(
        children: <Widget>[
          if (showPaneToggles) ...<Widget>[
            RailToggleButton(
              onlyWhenCollapsed: true,
              color: palette.chromeForeground,
            ),
            const SizedBox(width: 2),
          ],
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$target · ${state.username} · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.of(context).mono(
                size: AppFontSize.sm,
                height: AppLineHeight.tight,
                color: palette.chromeForeground,
              ),
            ),
          ),
          IconButton(
            tooltip: '重连',
            // 重连途中置灰：这一次点击还在办，再点一次只会再造一条握手。
            onPressed: reconnecting ? null : onReconnect,
            style: _actionStyle,
            iconSize: kPaneHeaderIconSize,
            color: actionColor,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '断开',
            onPressed: onDisconnect,
            style: _actionStyle,
            iconSize: kPaneHeaderIconSize,
            color: actionColor,
            icon: const Icon(Icons.link_off_rounded),
          ),
          if (allowFullscreen)
            IconButton(
              key: kTerminalFullscreenKey,
              // 这里只负责进入，所以文案与图标不再跟着状态切两套。
              // 退出方式写在进入时的提示里（「按 Esc 退出」）。
              tooltip: '全屏',
              onPressed: onEnterFullscreen,
              style: _actionStyle,
              iconSize: kPaneHeaderIconSize,
              color: actionColor,
              icon: const Icon(Icons.fullscreen_rounded),
            ),
          // 复制 / 粘贴独立成组：用一道竖线与会话动作隔开，否则六枚图标
          // 挤成一条分不清"哪些是在动会话、哪些是在动选中内容"的按钮带。
          const _StatusBarDivider(),
          IconButton(
            tooltip: '复制选中',
            onPressed: onCopy,
            style: _actionStyle,
            iconSize: kPaneHeaderIconSize,
            color: actionColor,
            icon: const _FilledGlyphIcon(Icons.content_copy_rounded),
          ),
          IconButton(
            tooltip: '粘贴',
            onPressed: onPaste,
            style: _actionStyle,
            iconSize: kPaneHeaderIconSize,
            color: actionColor,
            icon: const _FilledGlyphIcon(Icons.content_paste_rounded),
          ),
          if (showPaneToggles)
            FilePaneToggleButton(color: palette.chromeForeground),
        ],
      ),
    );
  }
}

/// 只缩绘制的实心字形图标。
///
/// 布局尺寸仍由 `IconButton.iconSize`（[kPaneHeaderIconSize]）决定，
/// [Transform.scale] 只影响绘制：命中区、按钮排布、悬停底都不变，
/// 变的仅是墨迹大小，好让实心字形与同排的描边字形视觉等高。
class _FilledGlyphIcon extends StatelessWidget {
  const _FilledGlyphIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: _StatusBar._filledGlyphScale,
      child: Icon(icon),
    );
  }
}

/// 状态栏里的分组竖线：与标签之间的接缝同高（14），颜色取终端栏的描边色，
/// 深浅两套终端配色下都不会偏。
class _StatusBarDivider extends StatelessWidget {
  const _StatusBarDivider();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(width: 1, height: 14, color: palette.chromeBorder),
    );
  }
}
