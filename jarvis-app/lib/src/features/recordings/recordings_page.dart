import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_models.dart';
import '../../core/recording/recording_providers.dart';
import '../../core/recording/recording_settings.dart';
import '../../core/ui/adaptive_card_list.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'recording_navigation.dart';
import 'recording_privacy_sheet.dart';
import 'recording_status_chip.dart';

/// 打开一条录音详情。宽屏下由外壳接住、在中栏原地切换。
typedef RecordingDetailOpener = void Function(
  LocalRecording? local,
  ServerRecording? server,
);

/// 录音列表每列的最小宽度。
///
/// 比会话 / 任务网格的 320 宽：录音行里有状态胶囊与两行预览，列一窄两者
/// 就会互相挤。380 下中栏约 860 放两条、1200 以上放三条；390 的手机宽度
/// 仍是单列铺满。
const double kRecordingTileMinWidth = 380;

/// 录音笔记列表。
///
/// 数据来自两处：本地账本（还没传完的）与服务端列表（已归档的）。
/// 两者按 `client_recording_id` 合并；服务不可达时只显示本地部分，不报空白。
///
/// [embedded] 为真时嵌在宽屏中栏：不画自己的 AppBar，改画三栏统一的细栏头，
/// 下一页由 [onOpenDetail] / [onOpenSession] 交给外壳切目标；为假时是窄屏整页，
/// 跳转仍走 `Navigator.push`。
class RecordingsPage extends ConsumerStatefulWidget {
  const RecordingsPage({
    super.key,
    this.embedded = false,
    this.onOpenDetail,
    this.onOpenSession,
    this.bottomInset = 0,
    this.topInset = 0,
  });

  final bool embedded;

  /// 底部额外留白（窄屏当一级标签时，为悬浮导航让位）。
  ///
  /// 只加在滚动内容末尾：给整页套 padding 会把胶囊底下一起垫空，
  /// 列表从玻璃底下面滚过的观感就没了。
  final double bottomInset;

  /// 顶部额外留白：窄屏当一级标签页时等于页头高度。
  ///
  /// body 延伸到页头之后（`frostTop`），列表首项要往下让出这一段；搜索框
  /// 打开时它是固定 chrome，同样要下移，此时列表的那份就不再叠加。
  final double topInset;

  /// 宽屏外壳接管"打开录音详情"。不传时退回整页路由（窄屏与设置页深链）。
  final RecordingDetailOpener? onOpenDetail;

  /// 宽屏外壳接管"打开录音进行页"。
  final VoidCallback? onOpenSession;

  @override
  ConsumerState<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends ConsumerState<RecordingsPage> {
  /// 栏头图标按钮的统一样式：命中区 24、8dp 圆角方形、零内边距。
  ///
  /// 与左栏栏头、中栏其它页的栏头按钮同一份规格：内嵌时这枚搜索键要和
  /// 左右两栏的按钮落在同一条水平线上，Material 默认 48 的命中区会顶出栏头。
  static final ButtonStyle _headerButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowDisclosure());
    // 列表里的"待转写/转写中"是服务端状态，本地账本不会主动通知。
    // 停留在列表页时按 3 秒轮询，直到所有记录都进入终态。
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) {
        return;
      }
      final entries = _entries(
        ref.read(recordingsLibraryProvider).value,
        ref.read(recordingControllerProvider),
      );
      if (entries.any(_needsRefresh)) {
        ref.invalidate(recordingsLibraryProvider);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _search.dispose();
    super.dispose();
  }

  bool _needsRefresh(_Entry entry) {
    if (entry.live) {
      return true;
    }
    final server = entry.server;
    if (server != null) {
      return server.status == RecordingStatus.recording ||
          server.status == RecordingStatus.recorded ||
          server.status == RecordingStatus.transcribing;
    }
    // 本地已经有 serverId 但列表还没拿到对应服务端记录（刚建完/刚传完），
    // 说明这次列表快照落后了。
    return entry.local?.serverId != null;
  }

  Future<void> _maybeShowDisclosure() async {
    // 偏好是异步读的：首帧时 `.value` 往往还是 null，直接读会永久跳过告知。
    final RecordingPreferences prefs;
    try {
      prefs = await ref.read(recordingPreferencesProvider.future);
    } on Object {
      return;
    }
    if (!mounted || prefs.disclosureSeen) {
      return;
    }
    final enabled = await showRecordingPrivacySheet(context, ref);
    if (enabled && mounted) {
      await ref.read(recordingControllerProvider.notifier).syncPending();
    }
  }

  /// 打开录音进行页：宽屏交给外壳在中栏原地切换，窄屏整页推入。
  void _openSession() {
    final opener = widget.onOpenSession;
    if (opener != null) {
      opener();
      return;
    }
    unawaited(openRecordingSession(context));
  }

  /// 打开一条录音的详情。`local` 与 `server` 至少给一个。
  Future<void> _openDetail({
    LocalRecording? local,
    ServerRecording? server,
  }) async {
    final opener = widget.onOpenDetail;
    if (opener != null) {
      opener(local, server);
      return;
    }
    await openRecordingDetail(context, local: local, server: server);
    if (!mounted) {
      return;
    }
    // 详情页里可能刚完成上传/转写：返回列表时立刻重拉一次，
    // 不必等 3 秒轮询。
    ref.invalidate(recordingsLibraryProvider);
  }

  Future<void> _start(RecordingMode mode) async {
    final session = ref.read(recordingControllerProvider);
    if (session.active) {
      _openSession();
      return;
    }

    final controller = ref.read(recordingControllerProvider.notifier);
    final started = await controller.start(mode);
    if (!mounted) {
      return;
    }
    if (!started) {
      final error = ref.read(recordingControllerProvider).error;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error ?? '无法开始录音')));
      return;
    }
    _openSession();
  }

  Future<void> _enableUpload() async {
    final enabled = await showRecordingPrivacySheet(context, ref);
    if (enabled && mounted) {
      await ref.read(recordingControllerProvider.notifier).syncPending();
      ref.invalidate(recordingsLibraryProvider);
    }
  }

  /// 栏头右侧的搜索开关。整页形态挂在 AppBar 上，内嵌形态挂在细栏头上。
  ///
  /// 整页（手机版）用 38dp 玻璃圆钮 + 原型描边放大镜；收起时换成 Material
  /// 的 close（原型没有"关搜索"这个状态，只有打开态有放大镜）。
  Widget _searchButton() {
    void toggle() {
      setState(() {
        _searching = !_searching;
        if (!_searching) {
          _search.clear();
        }
      });
    }

    if (!widget.embedded) {
      return MobileTopBarButton(
        glyph: _searching ? null : MobileTopBarGlyph.search,
        icon: _searching ? Icons.close : null,
        tooltip: _searching ? '关闭搜索' : '搜索',
        onPressed: toggle,
      );
    }

    return IconButton(
      tooltip: _searching ? '关闭搜索' : '搜索',
      onPressed: toggle,
      style: _headerButtonStyle,
      iconSize: kPaneHeaderIconSize,
      icon: Icon(_searching ? Icons.close : Icons.search),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(recordingsLibraryProvider);
    final prefs = ref.watch(recordingPreferencesProvider).value;
    final info = ref.watch(recordingInfoProvider).value;
    final session = ref.watch(recordingControllerProvider);

    final entries = _entries(library.value, session);
    final keyword = _search.text.trim().toLowerCase();
    final filtered = keyword.isEmpty
        ? entries
        : entries
              .where(
                (entry) =>
                    entry.title.toLowerCase().contains(keyword) ||
                    entry.preview.toLowerCase().contains(keyword),
              )
              .toList();

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时底色由骨架的渐变透上来；
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded
          ? paneSurfaceColor(Theme.of(context).colorScheme)
          : null,
      // 窄屏一级标签：body 铺到页头之后，列表才能从页头底下滚过并被糊掉。
      frostTop: widget.topInset > 0,
      // 内嵌形态不画第二层 AppBar：外层已经是三栏统一的细栏头。
      appBar: widget.embedded
          ? null
          : MobileAppBar(
              title: '录音笔记',
              // 作为底部导航的一级标签时是根路由，没有可返回的上一页。
              showBack: Navigator.of(context).canPop(),
              actions: <Widget>[_searchButton()],
            ),
      body: SafeArea(
        top: false,
        // 窄屏当一级标签时底部压着悬浮导航与虚化带：视口要铺到物理底边，
        // 列表才能像设置页那样被毛玻璃糊掉（`SafeArea` 会把视口抬到安全区
        // 线上，`ListView` 默认 `Clip.hardEdge` 就地硬切，虚化带最下那段
        // 没有内容可糊）。内嵌中栏没有浮层，仍避开 Home 指示条。
        bottom: widget.embedded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.embedded)
              EmbeddedToolbar(
                title: '录音笔记',
                actions: <Widget>[_searchButton()],
              ),
            if (_searching)
              Padding(
                padding: EdgeInsets.fromLTRB(20, 8 + widget.topInset, 20, 0),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '搜索标题或转写稿',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(recordingsLibraryProvider);
                  ref.invalidate(recordingInfoProvider);
                  await ref.read(recordingsLibraryProvider.future);
                },
                child: ListView(
                  // 内嵌形态下切到详情再回来会重建这一页：滚动位置靠它留住。
                  key: const PageStorageKey<String>('recordings-list'),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    // 搜索框打开时它已经让出了页头那一段，这里不再叠加。
                    16 + (_searching ? 0 : widget.topInset),
                    20,
                    32 + widget.bottomInset,
                  ),
                  children: <Widget>[
                    if (library.value?.offline == true)
                      _Banner(
                        icon: Icons.cloud_off_outlined,
                        color: AppPalette.of(context).status.warning,
                        title: '暂时连不上服务',
                        body: library.value?.error ?? '录音仍会保存在本机，连上后再上传',
                        action: '重试',
                        onAction: () {
                          ref.invalidate(recordingsLibraryProvider);
                          ref.invalidate(recordingInfoProvider);
                        },
                      ),
                    if (prefs?.uploadEnabled != true)
                      _Banner(
                        icon: Icons.lock_outline,
                        color: AppPalette.of(context).status.info,
                        title: '仅本地录音',
                        body: '音频不会离开这台电脑；开启上传后才能转写。',
                        action: '允许上传',
                        onAction: _enableUpload,
                      ),
                    if (prefs?.uploadEnabled == true &&
                        info != null &&
                        !info.asrAvailable)
                      _Banner(
                        icon: Icons.translate_outlined,
                        color: AppPalette.of(context).status.warning,
                        title: '服务端未开启转写',
                        body: '音频会上传归档，但暂时不会生成文字。在服务端配置 asr 后重启即可。',
                      ),
                    if (session.active)
                      _ActiveRecordingCard(
                        session: session,
                        onTap: _openSession,
                      ),
                    const SizedBox(height: 4),
                    _ModeActions(onStart: _start),
                    const SizedBox(height: 20),
                    if (library.isLoading && entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (filtered.isEmpty)
                      _EmptyState(keyword: keyword, onStart: _start)
                    else
                      ..._grouped(
                        filtered,
                        uploadEnabled: prefs?.uploadEnabled == true,
                        onOpen: (entry) => _openDetail(
                          local: entry.local,
                          server: entry.server,
                        ),
                      ),
                    const SizedBox(height: 20),
                    _UsageFooter(
                      key: ValueKey<int>(filtered.length),
                      enabled: prefs?.uploadEnabled == true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_Entry> _entries(
    RecordingsLibrary? library,
    RecordingSessionState session,
  ) {
    if (library == null) {
      return <_Entry>[];
    }
    final entries = <_Entry>[];
    for (final local in library.local) {
      entries.add(
        _Entry(
          local: local,
          server: library.serverForClient(local.clientId),
          live: session.active && session.recording?.clientId == local.clientId,
        ),
      );
    }
    for (final server in library.serverOnly) {
      entries.add(_Entry(server: server));
    }
    entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return entries;
  }

  List<Widget> _grouped(
    List<_Entry> entries, {
    required bool uploadEnabled,
    required void Function(_Entry entry) onOpen,
  }) {
    // 先按日期切组：同一组的条目要一起进网格才算得出每行放几条。
    // 条目本身已按时间倒序，`putIfAbsent` 的插入顺序就是分组的显示顺序。
    final groups = <String, List<_Entry>>{};
    for (final entry in entries) {
      groups
          .putIfAbsent(dayGroupLabel(entry.startedAt), () => <_Entry>[])
          .add(entry);
    }

    final widgets = <Widget>[];
    var first = true;
    for (final MapEntry<String, List<_Entry>> group in groups.entries) {
      // 分组标题整行占满，不参与网格。
      widgets.add(
        Padding(
          padding: EdgeInsets.only(top: first ? 0 : 16, bottom: 8),
          child: Text(group.key, style: AppText.of(context).section),
        ),
      );
      first = false;
      widgets.add(
        AdaptiveCardList(
          // 外层 ListView 已经是纵向滚动容器：自己不能再带一层。
          scrollable: false,
          minItemWidth: kRecordingTileMinWidth,
          // 行距 20 = 原来的网格行距 12 + 行自带的下边距 8。卡片底改由
          // `AdaptiveCard` 统一绘制后，行内边距会变成卡片的一部分，所以把
          // 那 8dp 挪到行距上，观感与之前一致。
          runSpacing: 20,
          itemCount: group.value.length,
          itemBuilder: (context, index) {
            final entry = group.value[index];
            return _RecordingRow(
              entry: entry,
              uploadEnabled: uploadEnabled,
              onTap: () => onOpen(entry),
            );
          },
        ),
      );
    }
    return widgets;
  }
}

class _Entry {
  _Entry({this.local, this.server, this.live = false});

  final LocalRecording? local;
  final ServerRecording? server;
  final bool live;

  String get title => server?.title ?? local?.title ?? '未命名录音';

  String get preview {
    final serverText = server?.preview.trim() ?? '';
    if (serverText.isNotEmpty) {
      return serverText;
    }
    final localText = local?.preview.trim() ?? '';
    if (localText.isNotEmpty) {
      return localText;
    }
    return local?.mode.hint ?? '音频已归档，等待转写';
  }

  int get startedAt => local?.startedAt ?? server?.createdAt ?? 0;

  int get durationMs => server?.durationMs ?? local?.durationMs ?? 0;

  int get bytes => server?.bytes ?? local?.bytes ?? 0;
}

class _RecordingRow extends ConsumerWidget {
  const _RecordingRow({
    required this.entry,
    required this.uploadEnabled,
    required this.onTap,
  });

  final _Entry entry;

  /// 关着开关时，本地录音的准确状态是「仅本地」而不是「待上传」。
  final bool uploadEnabled;

  /// 打开详情：内嵌形态由外壳接管，整页形态在这里 push。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final status = _statusOf(entry, palette);

    // 内文与另外两处列表共用同一套几何（`AdaptiveCardRow`）：图标块、字阶、
    // 内边距都只在那一个组件里定义。
    return AdaptiveCardRow(
      icon: Icons.graphic_eq,
      iconColor: status.color,
      title: entry.title,
      trailing: RecordingStatusChip(
        label: status.label,
        color: status.color,
        compact: true,
      ),
      preview: entry.preview,
      meta:
          '${formatDuration(entry.durationMs)} · '
          '${formatBytes(entry.bytes)} · '
          '${formatListTime(entry.startedAt)}',
      onTap: onTap,
    );
  }

  ({String label, Color color}) _statusOf(_Entry entry, AppPalette palette) {
    if (entry.live) {
      return (label: '录音中', color: palette.status.danger);
    }
    final server = entry.server;
    if (server == null) {
      return uploadEnabled
          ? (label: '待上传', color: palette.status.warning)
          : (label: '仅本地', color: palette.status.neutral);
    }
    if (entry.local?.hasPendingUpload == true) {
      return (label: '待上传', color: palette.status.warning);
    }
    final label = switch (server.status) {
      RecordingStatus.recording => '录音中',
      RecordingStatus.recorded => '待转写',
      RecordingStatus.transcribing => '转写中',
      RecordingStatus.ready => '已转写',
      RecordingStatus.partial => '部分失败',
      RecordingStatus.failed => '转写失败',
    };
    return (
      label: label,
      color: recordingStatusColor(server.status, palette),
    );
  }
}

/// 顶部模式入口：始终一行，按钮按内容取宽；放不下时横向滑动。
///
/// 不用 `Expanded` 均分（"平铺"）：后面还要再加 3 个左右模式，均分只会让
/// 每个按钮越来越窄。入口是数据驱动的，加模式只需往 [_modes] 里补一条。
class _ModeActions extends StatelessWidget {
  const _ModeActions({required this.onStart});

  final Future<void> Function(RecordingMode mode) onStart;

  /// 入口表：模式 + 图标。顺序就是从左到右的显示顺序。
  static const List<({RecordingMode mode, IconData icon})> _modes =
      <({RecordingMode mode, IconData icon})>[
        (mode: RecordingMode.realtime, icon: Icons.multitrack_audio),
        (mode: RecordingMode.batch, icon: Icons.library_music_outlined),
      ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _modes.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 8),
            _ModeButton(
              mode: _modes[i].mode,
              icon: _modes[i].icon,
              onTap: () => onStart(_modes[i].mode),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.icon,
    required this.onTap,
  });

  final RecordingMode mode;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);
    // 两个模式入口用同一个强调色，区分靠图标与文案：它们不是状态，
    // 借 `status.info` / `status.success` 会在暖纸或靛蓝主题里留下一蓝一绿。
    final color = palette.accent.projectStart;

    // 说明不进按钮：一行要放 4~5 个按钮，带副标题会把每个撑到 200dp 以上。
    // 悬停（桌面）/ 长按（移动端）仍能读到它。
    return Tooltip(
      message: mode.hint,
      child: Material(
        color: palette.status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: palette.status.borderOf(color)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Text(
                  mode.label,
                  style: text.row.copyWith(fontWeight: AppWeight.medium),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveRecordingCard extends StatelessWidget {
  const _ActiveRecordingCard({required this.session, required this.onTap});

  final RecordingSessionState session;

  /// 回到录音进行页：内嵌形态由外壳切目标，整页形态在这里 push。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final recording = session.recording;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: palette.status.surfaceOf(palette.status.danger),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.fiber_manual_record,
                  size: 14,
                  color: palette.status.danger,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    session.paused ? '录音已暂停' : '正在录音',
                    style: text.row.copyWith(fontWeight: AppWeight.medium),
                  ),
                ),
                Text(formatElapsed(session.elapsedMs), style: text.mono()),
                if (recording != null) ...<Widget>[
                  const SizedBox(width: 12),
                  Text(
                    '${recording.uploadedCount}/${recording.segments.length} 段',
                    style: text.meta,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: palette.status.borderOf(color)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: text.row.copyWith(fontWeight: AppWeight.medium),
                ),
                const SizedBox(height: 4),
                Text(body, style: text.hint),
              ],
            ),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.keyword, required this.onStart});

  final String keyword;
  final Future<void> Function(RecordingMode mode) onStart;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: palette.status.surfaceOf(palette.accent.projectStart),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Icon(
              keyword.isEmpty ? Icons.mic_none_outlined : Icons.search_off,
              size: 28,
              color: palette.accent.projectStart,
            ),
          ),
          const SizedBox(height: 16),
          Text(keyword.isEmpty ? '还没有录音' : '没有匹配的录音', style: text.section),
          const SizedBox(height: 8),
          Text(
            keyword.isEmpty ? '会议、灵感、路上想到的事，先录下来再慢慢看。' : '换个关键词试试，或清空搜索。',
            textAlign: TextAlign.center,
            style: text.hint,
          ),
          if (keyword.isEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => onStart(RecordingMode.realtime),
                  icon: const Icon(Icons.multitrack_audio, size: 18),
                  label: const Text('实时记录'),
                ),
                OutlinedButton.icon(
                  onPressed: () => onStart(RecordingMode.batch),
                  icon: const Icon(Icons.library_music_outlined, size: 18),
                  label: const Text('录完再转'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _UsageFooter extends ConsumerStatefulWidget {
  const _UsageFooter({super.key, required this.enabled});

  final bool enabled;

  @override
  ConsumerState<_UsageFooter> createState() => _UsageFooterState();
}

class _UsageFooterState extends ConsumerState<_UsageFooter> {
  int? _usage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = await ref.read(recordingStoreProvider.future);
      final usage = await store.diskUsage();
      if (mounted) {
        setState(() => _usage = usage);
      }
    } on Object {
      // 读不到占用不是错误：页脚只是辅助信息。
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final usage = _usage;
    return Text(
      usage == null
          ? '本地音频占用读取中…'
          : '本地音频占用 ${formatBytes(usage)} · '
                '${widget.enabled ? '已允许上传转写' : '仅保存在本机'}',
      textAlign: TextAlign.center,
      style: text.meta,
    );
  }
}
