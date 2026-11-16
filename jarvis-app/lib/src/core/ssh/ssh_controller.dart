// SSH 段的状态机。
//
// 三个刻意为之的决定：
// 1. 终端实例（[Terminal]）不放进状态：它每收到一段输出就会通知监听者，
//    放进 Riverpod 会让整页每帧重建。
// 2. 连接保活（`ref.keepAlive()`）：切换项目再切回来，
//    用户期望看到的是"刚才那个终端还在"，而不是重新输密码。
// 3. 失败按 [SshFailureKind] 归类：不同原因要给出不同的下一步动作。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../session.dart';
import 'ssh_connector.dart';
import 'ssh_credentials.dart';
import 'ssh_models.dart';
import 'terminal_start_directory.dart';

/// 连接层。测试里覆盖成 Fake，不必起真实服务端。
final Provider<SshConnector> sshConnectorProvider = Provider<SshConnector>(
  (ref) => const TunnelSshConnector(),
);

/// 凭据存储。
final Provider<SshCredentials> sshCredentialsProvider =
    Provider<SshCredentials>(
      (ref) => SshCredentials(ref.watch(secretStoreProvider)),
    );

final NotifierProvider<SshController, SshState> sshControllerProvider =
    NotifierProvider<SshController, SshState>(SshController.new);

/// 「打开终端时自动登录」偏好。
///
/// 镜像 `themeModeProvider` 的写法：build 里先给默认值（开）再异步恢复，
/// `restore()` 公开是为了测试与"打开终端前先读准"这两处能确定性地等待。
final NotifierProvider<SshAutoLoginController, bool> sshAutoLoginProvider =
    NotifierProvider<SshAutoLoginController, bool>(SshAutoLoginController.new);

class SshAutoLoginController extends Notifier<bool> {
  @override
  bool build() {
    unawaited(restore());
    return true;
  }

  /// 从本地恢复开关并返回当前值。
  ///
  /// 返回 bool 而不是 void：打开终端的那一刻不能拿"还没恢复完"的默认值去做
  /// 决定——用户明明关了自动登录，却因为读到默认 true 被自动连上，是最难解释的那种 bug。
  Future<bool> restore() async {
    try {
      final enabled = await ref.read(sshCredentialsProvider).readAutoLogin();
      if (enabled != state) {
        state = enabled;
      }
    } on Exception {
      // 读不出来就用默认值：钥匙串在测试与 headless 环境里可能不可用。
    }
    return state;
  }

  /// 切换开关并落盘。落盘失败不回滚——当前这次选择用户已经看到了。
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    try {
      await ref.read(sshCredentialsProvider).saveAutoLogin(enabled);
    } on Exception {
      // 只影响"下次启动记不住"，不影响本次。
    }
  }
}

/// 当前配对服务端主机下已保存的 SSH 凭据。
///
/// 设置页与终端页共用同一份状态：终端页在 `IndexedStack` 里常驻，用户在设置页
/// 保存后它不会重新挂载，只能靠这个 provider 感知"凭据变了"。
final AsyncNotifierProvider<SshSavedCredentialsController, SshSavedCredentials>
sshSavedCredentialsProvider =
    AsyncNotifierProvider<SshSavedCredentialsController, SshSavedCredentials>(
      SshSavedCredentialsController.new,
    );

/// 表单回填用的凭据。
class SshSavedCredentials {
  const SshSavedCredentials({this.username = '', this.password = ''});

  final String username;
  final String password;

  bool get hasPassword => password.isNotEmpty;
}

class SshSavedCredentialsController extends AsyncNotifier<SshSavedCredentials> {
  @override
  Future<SshSavedCredentials> build() async {
    final host = await _host(watchSession: true);
    if (host == null) {
      return const SshSavedCredentials();
    }
    return _read(host);
  }

  /// 保存凭据。`password` 为 null 或空串表示"不修改已保存的密码"。
  ///
  /// 之所以不直接调 [SshCredentials.save]：那个方法的空密码语义是"这次不记住，
  /// 把旧的删掉"，放到设置页会把"只想改用户名"变成"顺手清了密码"。
  Future<void> save({required String username, String? password}) async {
    final host = await _host();
    if (host == null) {
      return;
    }
    final store = ref.read(sshCredentialsProvider);
    final trimmed = username.trim();
    await store.saveUsername(host: host, username: trimmed);
    if (password != null && password.isNotEmpty) {
      await store.save(host: host, username: trimmed, password: password);
    }
    state = AsyncData(await _read(host));
  }

  /// 清除已保存的用户名与密码，保留主机指纹（与「解除配对」的语义区分开）。
  Future<void> clear() async {
    final host = await _host();
    if (host == null) {
      return;
    }
    await ref.read(sshCredentialsProvider).clear(host: host);
    state = const AsyncData(SshSavedCredentials());
  }

  Future<SshSavedCredentials> _read(String host) async {
    final store = ref.read(sshCredentialsProvider);
    return SshSavedCredentials(
      username: await store.readUsername(host) ?? '',
      password: await store.readPassword(host) ?? '',
    );
  }

  /// 凭据按服务端主机分组；未配对（或地址解析不出主机）时为 null。
  ///
  /// `watchSession` 只在 `build` 里用：会话换了机器（重新配对）时要重建；
  /// 写操作的路径上不能 watch，否则一次保存会把 provider 自己标脏。
  Future<String?> _host({bool watchSession = false}) async {
    try {
      final session = watchSession
          ? await ref.watch(sessionProvider.future)
          : await ref.read(sessionProvider.future);
      if (!session.isReady) {
        return null;
      }
      final host = Uri.tryParse(session.serverUrl)?.host;
      return host == null || host.isEmpty ? null : host;
    } on Object {
      return null;
    }
  }
}

/// 打开终端时的一次性决策结果。
///
/// 把"读凭据 + 读开关 + 判断现在能不能连"合成一次调用：页面只在 `_bootstrap`
/// 里问一次，避免分三次读钥匙串再各自判断。
class SshAutoLoginPlan {
  const SshAutoLoginPlan({
    required this.credentials,
    required this.autoLogin,
    required this.canAutoLogin,
  });

  final SshSavedCredentials credentials;

  /// 开关的值（不代表一定能连：凭据不全、未配对、已经连着都不算）。
  final bool autoLogin;

  final bool canAutoLogin;
}

class SshController extends Notifier<SshState> {
  /// 滚动缓冲区。太小会让 `ls` 的输出立刻被顶掉，太大会占内存；
  /// 5000 行对"看目录/看日志"这类用途够用。
  final Terminal _terminal = Terminal(maxLines: 5000);

  SshConnection? _connection;
  StreamSubscription<String>? _stdout;
  Timer? _resizeTimer;
  int? _pendingCols;
  int? _pendingRows;

  /// 上一次成功连接用的密码。没勾"记住密码"时不落盘，但重连要能直接用。
  String? _lastPassword;
  bool _hostKeyMismatch = false;
  bool _disposed = false;
  int _connectAttempt = 0;

  /// 终端实例。切换 tab 后由 `TerminalView` 重新挂载到同一个对象上。
  Terminal get terminal => _terminal;

  @override
  SshState build() {
    // 切走项目时不能把会话连同 provider 一起销毁。
    ref.keepAlive();
    ref.onDispose(() {
      _disposed = true;
      unawaited(_release());
    });

    _terminal.onOutput = _handleOutput;
    _terminal.onResize = _handleResize;

    unawaited(_restoreUsername());
    return const SshState.initial();
  }

  /// 服务端主机名（凭据按它分组）。
  String? get serverHost {
    final url = _session?.serverUrl;
    if (url == null || url.isEmpty) {
      return null;
    }
    final host = Uri.tryParse(url)?.host;
    return host == null || host.isEmpty ? null : host;
  }

  SessionState? get _session {
    final session = ref.read(sessionProvider).value;
    if (session == null || !session.isReady) {
      return null;
    }
    return session;
  }

  /// 等会话加载完再判断。
  ///
  /// 启动瞬间（或冷启动后立刻点 SSH）会话还在 `AsyncLoading`，同步读会拿到 null，
  /// 于是把"还没加载完"误报成"没配对"。这里等一次 future，代价只有一次微任务。
  Future<SessionState?> _sessionAsync() async {
    final current = ref.read(sessionProvider);
    if (current.isLoading && !current.hasValue) {
      try {
        final resolved = await ref.read(sessionProvider.future);
        return resolved.isReady ? resolved : null;
      } on Object {
        return null;
      }
    }
    return _session;
  }

  Future<SshSavedCredentials> loadSaved() async {
    final host = await _resolveHost();
    if (host == null) {
      return const SshSavedCredentials();
    }
    final store = ref.read(sshCredentialsProvider);
    return SshSavedCredentials(
      username: await store.readUsername(host) ?? '',
      password: await store.readPassword(host) ?? '',
    );
  }

  /// 打开终端前的一次性决策：这次要不要直接登录、拿什么登录。
  ///
  /// `canAutoLogin` 的门槛刻意都放在这里，而不是让页面分散判断：
  /// 已配对（拿得到 host）、开关为开、用户名与密码都非空、当前处于 idle。
  /// 已经连着 / 正在连 / 失败态都不重连——切个 tab 回来不该把用户踢下线。
  Future<SshAutoLoginPlan> loadAutoLoginPlan() async {
    final saved = await loadSaved();
    final enabled = await ref.read(sshAutoLoginProvider.notifier).restore();
    final session = await _sessionAsync();
    final canAutoLogin =
        enabled &&
        session != null &&
        state.phase == SshPhase.idle &&
        saved.username.isNotEmpty &&
        saved.password.isNotEmpty;
    return SshAutoLoginPlan(
      credentials: saved,
      autoLogin: enabled,
      canAutoLogin: canAutoLogin,
    );
  }

  /// 凭据分组用的主机：冷启动时会话可能还在加载，等一次 future 再取。
  Future<String?> _resolveHost() async {
    final session = await _sessionAsync();
    final url = session?.serverUrl;
    if (url == null || url.isEmpty) {
      return serverHost;
    }
    final host = Uri.tryParse(url)?.host;
    return host == null || host.isEmpty ? serverHost : host;
  }

  /// 进入 SSH 段时探测一次隧道。失败只影响提示，不阻止用户尝试连接——
  /// 探测本身也可能因为瞬时网络抖动失败。
  Future<void> probe() async {
    final session = await _sessionAsync();
    if (session == null) {
      // 已经连着的时候不回退到失败态：切个 tab 回来不该把活着的终端变成一张表单。
      if (!state.isConnected && !state.isConnecting) {
        _fail(SshFailureKind.unauthenticated);
      }
      return;
    }

    try {
      final info = await ref
          .read(sshConnectorProvider)
          .probe(
            baseUrl: session.serverUrl,
            token: session.token!,
            tlsFingerprint: session.serverTlsFingerprint,
          );
      _update(
        (current) => current.copyWith(
          target: info.target,
          tunnelEnabled: info.enabled,
          sshdReachable: info.sshdReachable,
          // 预检成功时清掉上一次的错误，避免"已经好了还挂着红字"。
          clearMessage: info.ready,
          clearFailure: info.ready,
        ),
      );
    } on Object catch (error) {
      // 同理：探测失败不能改写一条正在工作的连接。
      if (state.isConnected || state.isConnecting) {
        return;
      }
      _fail(classifySshError(error));
    }
  }

  Future<void> connect({
    required String username,
    required String password,
    required bool rememberPassword,
  }) async {
    if (state.isConnecting) {
      return;
    }

    final session = await _sessionAsync();
    if (session == null) {
      _fail(SshFailureKind.unauthenticated);
      return;
    }

    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty || password.isEmpty) {
      _update(
        (current) => current.copyWith(
          phase: SshPhase.failed,
          failure: SshFailureKind.authFailed,
          message: '请填写用户名与密码',
          username: trimmedUser,
        ),
      );
      return;
    }

    // 每次连接拿一个序号：用户在握手途中点"取消"时序号会变，
    // 迟到的连接结果据此丢弃，不会在用户已经退出后突然冒出一个终端。
    final attempt = ++_connectAttempt;

    _update(
      (current) => current.copyWith(
        phase: SshPhase.connecting,
        username: trimmedUser,
        clearMessage: true,
        clearFailure: true,
      ),
    );
    _hostKeyMismatch = false;

    // 起始目录在发起连接前取一次快照：握手要几秒，期间用户完全可能又点了
    // 另一个项目。以"按下连接的这一刻"为准，迟到的目录不该改写已经谈好的落点。
    final startDirectory = ref.read(terminalStartDirectoryProvider);

    try {
      final connector = ref.read(sshConnectorProvider);

      // 先预检：把"服务端没开 sshd"与"密码错了"在握手前分开，
      // 否则两者在界面上都会退化成一次失败的登录。
      final info = await connector.probe(
        baseUrl: session.serverUrl,
        token: session.token!,
        tlsFingerprint: session.serverTlsFingerprint,
      );
      if (!info.enabled) {
        throw const SshConnectException(SshFailureKind.tunnelDisabled);
      }
      if (!info.sshdReachable) {
        throw const SshConnectException(SshFailureKind.sshdUnreachable);
      }

      final connection = await connector.open(
        baseUrl: session.serverUrl,
        token: session.token!,
        tlsFingerprint: session.serverTlsFingerprint,
        username: trimmedUser,
        password: password,
        verifyHostKey: _verifyHostKey,
        cols: _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
        rows: _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
      );

      if (_disposed || attempt != _connectAttempt) {
        await connection.close();
        return;
      }

      // 上一次没关干净（比如握手超时后 late 的返回）：先释放再接管。
      await _release(keepTerminal: true);
      _connection = connection;
      _lastPassword = password;
      _attach(connection);
      _enterStartDirectory(connection, startDirectory);

      final host = serverHost;
      if (host != null) {
        await ref
            .read(sshCredentialsProvider)
            .save(
              host: host,
              username: trimmedUser,
              password: rememberPassword ? password : null,
            );
      }

      _update(
        (current) => current.copyWith(
          phase: SshPhase.connected,
          target: info.target,
          username: trimmedUser,
          tunnelEnabled: true,
          sshdReachable: true,
          clearMessage: true,
          clearFailure: true,
        ),
      );

      // pty 建立时用的是默认尺寸，挂载后立刻按真实视口校正一次。
      _resizeTimer?.cancel();
      _resizeTimer = Timer(const Duration(milliseconds: 50), () {
        final conn = _connection;
        if (conn == null) {
          return;
        }
        conn.shell.resizeTerminal(
          _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
          _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
        );
      });
    } on Object catch (error) {
      if (attempt != _connectAttempt) {
        return;
      }
      final kind = _hostKeyMismatch
          ? SshFailureKind.hostKeyChanged
          : classifySshError(error);
      _fail(kind);
    }
  }

  /// 中断正在进行中的连接。
  ///
  /// 握手的哪一步都可能卡住（尤其是隧道半通），而窗口里已经显示"连接中"，
  /// 没有取消就只能等超时——所以这里只负责让结果作废，迟到的连接会自己关掉。
  void cancelConnect() {
    if (!state.isConnecting) {
      return;
    }
    _connectAttempt++;
    _update(
      (current) => current.copyWith(
        phase: SshPhase.idle,
        clearMessage: true,
        clearFailure: true,
      ),
    );
  }

  /// 断线重连：沿用上次的参数与密码。
  ///
  /// 内存里没有密码时（进程重启、或先前没勾记住）再读一次已保存的凭据：
  /// 用户点的是「重连」而不是「重新登录」，能自己搞定就不该把表单推给他。
  Future<void> reconnect() async {
    var password = _lastPassword;
    var username = state.username;
    if (password == null) {
      final saved = await loadSaved();
      username = username.isEmpty ? saved.username : username;
      password = saved.hasPassword ? saved.password : null;
    }
    if (password == null || username.isEmpty) {
      // 真的没有任何可用凭据：回到表单让用户重新输入。
      _update(
        (current) => current.copyWith(
          phase: SshPhase.idle,
          clearMessage: true,
          clearFailure: true,
        ),
      );
      return;
    }
    await connect(
      username: username,
      password: password,
      // 重连不改变"是否记住密码"：用户上次的选择已经落盘。
      rememberPassword: await _hasSavedPassword(),
    );
  }

  /// 主动断开：**留在终端页**，进入与远端 `exit` 完全一样的「已断开」态。
  ///
  /// 界面因此保持终端形态：输出还在、状态栏显示「已断开」、中央浮出
  /// 「连接已断开 / 重新连接」的遮罩。不回到连接表单——用户刚敲完命令，
  /// 最可能想先看一眼输出或直接重连，一张表单会把它们全盖住。
  ///
  /// 与 [discardSession] 的分工：这里是"用户按了断开"，那边是"关掉标签、
  /// 放弃这台 shell"。后者下次打开终端应该从表单开始，不能停在这台旧终端上。
  Future<void> disconnect() async {
    // 先把状态落成已断开，再关连接：`_release` 会触发 shell 的 done 回调，
    // 那条路径会调 `_markDisconnected(network)`。先置位后，它会被
    // 「phase 不是 connected」的早退保护挡住，这次主动断开就不会被记成网络故障。
    _update(
      (current) => current.copyWith(
        phase: SshPhase.disconnected,
        clearMessage: true,
        clearFailure: true,
      ),
    );
    await _release(keepTerminal: true);
  }

  /// 放弃这台 shell（关闭终端标签时）：回到 idle，下次打开终端从连接表单开始。
  ///
  /// 与 [disconnect] 的唯一差别是"界面停在哪"：这里不留已断开的旧终端，
  /// 也顺手把内存里的密码清掉——标签都关了，没有理由再留着它
  /// （已保存的凭据不受影响，那是用户勾了「记住密码」的东西）。
  Future<void> discardSession() async {
    await _release(keepTerminal: true);
    _lastPassword = null;
    _update(
      (current) => current.copyWith(
        phase: SshPhase.idle,
        clearMessage: true,
        clearFailure: true,
      ),
    );
  }

  /// 解除配对时调用：那台机器已经不被信任，凭据与主机指纹一起清掉。
  Future<void> forgetSaved() async {
    final host = serverHost;
    await _release();
    _lastPassword = null;
    if (host != null) {
      await ref.read(sshCredentialsProvider).forget(host);
    }
    _update(
      (current) => current.copyWith(
        phase: SshPhase.idle,
        clearMessage: true,
        clearFailure: true,
      ),
    );
  }

  Future<void> _restoreUsername() async {
    final saved = await loadSaved();
    if (_disposed || saved.username.isEmpty || state.username.isNotEmpty) {
      return;
    }
    _update((current) => current.copyWith(username: saved.username));
  }

  Future<bool> _hasSavedPassword() async {
    final host = serverHost;
    if (host == null) {
      return false;
    }
    final saved = await ref.read(sshCredentialsProvider).readPassword(host);
    return saved != null && saved.isNotEmpty;
  }

  /// 静默 TOFU：首次记录指纹，之后不一致就阻断。
  ///
  /// 不弹确认框：隧道的身份已经由配对签名与 TLS 证书指纹证明，这里的 host key
  /// 只是"服务端本地 sshd 被换过"的额外防线，多一次确认只会变成无脑点"信任"。
  Future<bool> _verifyHostKey(SshHostKey key) async {
    final host = serverHost;
    if (host == null) {
      return false;
    }

    final store = ref.read(sshCredentialsProvider);
    final stored = await store.readHostKey(host);
    if (stored == null || stored.isEmpty) {
      await store.saveHostKey(host, key.fingerprint);
      return true;
    }
    if (stored == key.fingerprint) {
      return true;
    }

    _hostKeyMismatch = true;
    return false;
  }

  void _attach(SshConnection connection) {
    // 用流式解码器：一个中文字符可能被拆在两段输出里，逐段 `utf8.decode`
    // 会把它变成替换字符。
    final decoded = const Utf8Decoder(allowMalformed: true)
        .bind(connection.shell.stdout.cast<List<int>>());

    // 新会话的第一段输出常以换行开头（登录 banner 之前的空行）：终端会把
    // 这块空行原样画在顶边，看起来就像多出一条"黑边"。只裁掉开头这一段，
    // 之后的输出（含交互式程序自己的换行）一律原样透传。
    var trimmingLeadingBreaks = true;

    _stdout = decoded.listen(
      (data) {
        var chunk = data;
        if (trimmingLeadingBreaks) {
          chunk = chunk.replaceFirst(RegExp(r'^(?:\r\n|\r|\n)+'), '');
          // 整段都是换行：继续等下一个分片，直到真正有内容为止。
          if (chunk.isEmpty) {
            return;
          }
          trimmingLeadingBreaks = false;
        }
        _terminal.write(chunk);
      },
      onError: (Object _, StackTrace _) =>
          _markDisconnected(SshFailureKind.network),
      onDone: () => _markDisconnected(SshFailureKind.network),
    );

    // shell 结束（远端 exit / 隧道断开）时同样要落状态，否则界面会一直显示"已连接"。
    unawaited(
      connection.shell.done.then(
        (_) => _markDisconnected(SshFailureKind.network),
        onError: (Object _, StackTrace _) =>
            _markDisconnected(SshFailureKind.network),
      ),
    );
  }

  /// 让这次新 shell 直接落在用户点「终端」时所在的项目目录。
  ///
  /// dartssh2 建 shell 时没有 cwd 参数（后端只是一条 TCP 隧道，pty 由远端 sshd
  /// 拉起），所以只能像用户一样敲一条 `cd`：远端会把它回显出来，看起来就是
  /// "打开终端就在项目里"。写不进去不改连接状态——终端已经能用了，只是这次
  /// 没换目录，把它记成失败反而更难解释。
  ///
  /// 只在接管连接的这条路径上调用：已连着的终端再点「终端」不会走到这里，
  /// 因此不会打断正在跑的 vim / top。
  void _enterStartDirectory(SshConnection connection, String? path) {
    if (path == null || path.isEmpty) {
      return;
    }
    try {
      connection.shell.write(utf8.encode('cd ${_shellQuote(path)}\n'));
    } on Object {
      // 已经断开时写入会抛异常；断线本身由 stdout 与 done 那条路记账。
    }
  }

  void _handleOutput(String data) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    try {
      connection.shell.write(utf8.encode(data));
    } on Object {
      _markDisconnected(SshFailureKind.network);
    }
  }

  /// 尺寸变化去抖：拖窗口时 `resizeTerminal` 会被调上百次，
  /// 每次都发一个 channel request 既浪费又容易让远端重排到闪烁。
  void _handleResize(int cols, int rows, int pixelWidth, int pixelHeight) {
    _pendingCols = cols;
    _pendingRows = rows;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      final connection = _connection;
      final width = _pendingCols;
      final height = _pendingRows;
      if (connection == null || width == null || height == null) {
        return;
      }
      connection.shell.resizeTerminal(width, height);
    });
  }

  void _markDisconnected(SshFailureKind kind) {
    if (state.phase != SshPhase.connected) {
      return;
    }
    _update(
      (current) => current.copyWith(
        phase: SshPhase.disconnected,
        failure: kind,
        message: '连接已断开，可点击重连',
      ),
    );
    unawaited(_release(keepTerminal: true));
  }

  Future<void> _release({bool keepTerminal = false}) async {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _pendingCols = null;
    _pendingRows = null;

    final subscription = _stdout;
    _stdout = null;
    await subscription?.cancel();

    final connection = _connection;
    _connection = null;
    await connection?.close();

    if (!keepTerminal) {
      // 终端缓冲区跟着会话一起丢弃，避免下次连另一台机器时看到旧输出。
      _terminal.buffer.clear();
    }
  }

  void _fail(SshFailureKind kind) {
    _update(
      (current) => current.copyWith(
        phase: SshPhase.failed,
        failure: kind,
        message: kind.hint,
      ),
    );
  }

  void _update(SshState Function(SshState current) transform) {
    if (_disposed) {
      return;
    }
    state = transform(state);
  }
}

/// 把任意路径安全地放进 `cd` 的位置。
///
/// 单引号包裹 + 把内部单引号拆成 `'\''`：这一套在 bash / zsh / fish / sh 上
/// 行为一致，路径里的空格、`$`、反斜杠都不会被二次解释。
/// 不写 `--`：`Project.path` 恒为服务端的绝对路径（不以 `-` 开头），
/// 而 dash / ash 的 `cd` 对 `--` 支持不一致，多写一段只会在这类 shell 上报错。
String _shellQuote(String path) => "'${path.replaceAll("'", r"'\''")}'";
