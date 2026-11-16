import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/memory/memory_models.dart';
import '../../core/memory/memory_providers.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'memory_menu.dart';
import 'memory_navigation.dart';
import 'memory_settings_dialog.dart';

/// 记忆列表。
///
/// 数据是服务端权威：离线时不做本地缓存，直接告诉用户"需要连接服务端"。
/// 搜索与筛选都由服务端做（`q` 走 FTS + LIKE 兜底），客户端只负责防抖。
///
/// [embedded] 为真时嵌在宽屏中栏：不画 AppBar，改用三栏统一的细栏头。
class MemoryListPage extends ConsumerStatefulWidget {
  const MemoryListPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<MemoryListPage> createState() => _MemoryListPageState();
}

class _MemoryListPageState extends ConsumerState<MemoryListPage> {
  /// 栏头图标按钮的统一样式：命中区 24、8dp 圆角方形、零内边距。
  static final ButtonStyle _headerButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  final TextEditingController _search = TextEditingController();

  /// 窄屏「更多操作」的菜单控制器：触发钮在胶囊里，开合由它自己发起。
  final MenuController _menuController = MenuController();

  Timer? _debounce;

  MemoryStatus? _status = MemoryStatus.active;
  MemoryKind? _kind;
  String _query = '';

  /// 翻页取到的后续条目，只对 `_extraFor` 对应的查询有效。
  final List<Memory> _extra = <Memory>[];
  MemoryQuery? _extraFor;
  String? _cursor;
  bool _loadingMore = false;

  /// 本页发起的手动整理是否在跑。服务端快照里的 `organizing` 另算：
  /// 夜间自动整理、或从别的页面发起的那一轮也要把按钮置灰。
  bool _organizing = false;

  /// 是否已经在轮询。退出页面再进来时靠它避免重复起轮询。
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    // Riverpod 的 FutureProvider 会缓存上一次的结果：重新进入页面看到的是旧数据。
    // 记忆是后台写入的（抽取、心跳），列表必须每次进来都重查一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.invalidate(memoryStateProvider);
      ref.invalidate(memoryListProvider);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    // 300ms 防抖：每敲一个字都打一次服务端，输入法还没上屏就已经发了三次。
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || value.trim() == _query) {
        return;
      }
      setState(() {
        _query = value.trim();
        _resetPaging();
      });
    });
  }

  void _resetPaging() {
    _extra.clear();
    _extraFor = null;
    _cursor = null;
  }

  Future<void> _loadMore(MemoryQuery query, String cursor) async {
    final api = ref.read(memoryApiProvider);
    if (api == null || _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await api.list(
        kind: query.kind,
        status: query.status,
        query: query.query,
        cursor: cursor,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _extra.addAll(page.items);
        _extraFor = query;
        _cursor = page.nextCursor;
      });
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.hint)));
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  MemoryQuery get _currentQuery =>
      (kind: _kind, status: _status, query: _query);

  /// 页头「更多操作」：整理 / 候选 / 导出 / 清空归档 收进一个「⋯」。
  ///
  /// 窄屏把触发器画成玻璃圆钮（`bare`：底与描边由整枚胶囊提供，
  /// 这样它才能和「记忆设置」并成一格）；宽屏栏头仍是 24/14 的方钮。
  Widget _moreMenu(
    BuildContext context, {
    required bool mobile,
    required bool busy,
    required MemoryStateView? state,
  }) {
    return AgentMenu<MemoryMenuSelection>(
      width: 208,
      // 窄屏时 tooltip 由胶囊里那枚按钮自己给：两层都挂会连续弹两次。
      tooltip: mobile ? null : '更多操作',
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(208),
      // 触发器是自带 onPressed 的按钮：点击交给它，组件只管开合与浮层。
      triggerHandlesTap: false,
      controller: mobile ? _menuController : null,
      groups: memoryMenuGroups(
        organizing: busy,
        candidateCount: state?.counts.candidate ?? 0,
        archivedCount: state?.counts.archived ?? 0,
      ),
      onSelected: _onMenuSelected,
      builder: (context, controller, open, hovering) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (!mobile) {
          return IconButton(
            key: kMemoryMenuKey,
            tooltip: '更多操作',
            onPressed: toggle,
            style: _headerButtonStyle,
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.more_horiz),
          );
        }
        return MobileTopBarButton(
          key: kMemoryMenuKey,
          bare: true,
          glyph: MobileTopBarGlyph.more,
          tooltip: '更多操作',
          onPressed: toggle,
        );
      },
    );
  }

  /// 页头「记忆设置」。窄屏同样是胶囊里的一格。
  Widget _settingsButton(BuildContext context, {required bool mobile}) {
    if (!mobile) {
      return IconButton(
        tooltip: '记忆设置',
        onPressed: () => showMemorySettingsDialog(context),
        style: _headerButtonStyle,
        iconSize: kPaneHeaderIconSize,
        icon: const Icon(Icons.tune),
      );
    }
    return MobileTopBarButton(
      bare: true,
      icon: Icons.tune,
      tooltip: '记忆设置',
      onPressed: () => showMemorySettingsDialog(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final state = ref.watch(memoryStateProvider).value;
    final query = _currentQuery;
    final page = ref.watch(memoryListProvider(query));

    // 忙碌态以服务端快照为准：退出页面再进来，按钮与状态条仍然要显示"整理中"。
    final busy = _organizing || (state?.maintenance.organizing ?? false);
    if (busy && !_polling) {
      // 快照可能是进入页面前就缓存好的，`ref.listen` 不会触发；这里补一次。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_polling &&
            (ref.read(memoryStateProvider).value?.maintenance.organizing ??
                false)) {
          _resumePolling();
        }
      });
    }

    // 整页与内嵌共用同一份动作：内嵌时按钮尺寸收到栏头那一档；
    // 窄屏整页把两枚并成一枚胶囊（手机端原型 06 的「搜索 | 更多」同款）。
    final embedded = widget.embedded;
    final actions = <Widget>[
      if (embedded) ...<Widget>[
        _moreMenu(context, mobile: false, busy: busy, state: state),
        _settingsButton(context, mobile: false),
      ] else
        MobileTopBarButtonGroup(
          children: <Widget>[
            _moreMenu(context, mobile: true, busy: busy, state: state),
            _settingsButton(context, mobile: true),
          ],
        ),
    ];

    return AppPageScaffold(
      // 内嵌时与中栏其他页面同一层栏底：骨架的渐变透上来；
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: embedded ? paneSurfaceColor(theme.colorScheme) : null,
      // 内嵌形态不画第二层 AppBar：外层已经是三栏统一的细栏头。
      appBar: embedded
          ? null
          : MobileAppBar(title: '记忆', actions: actions),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (embedded) EmbeddedToolbar(title: '记忆', actions: actions),
          if (state != null) _summary(theme, text, state),
          if (busy) _organizingBanner(text, palette),
          if (state?.digestWarning != null) _warning(theme, text, palette, state!),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              style: text.row,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索记忆',
                hintStyle: text.hint,
                prefixIcon: Icon(Icons.search, size: 18, color: palette.text.tertiary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                for (final status in <MemoryStatus>[
                  MemoryStatus.active,
                  MemoryStatus.candidate,
                  MemoryStatus.archived,
                ])
                  _Chip(
                    label: status.label,
                    selected: _status == status,
                    onTap: () => setState(() {
                      _status = status;
                      _resetPaging();
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final kind in <MemoryKind?>[null, ...MemoryKind.values])
                  _Chip(
                    label: kind?.label ?? '全部',
                    selected: _kind == kind,
                    onTap: () => setState(() {
                      _kind = kind;
                      _resetPaging();
                    }),
                  ),
              ],
            ),
          ),
          Expanded(
            child: () {
              // 不用 `AsyncValue.when`：它把"正在重试"也算作 loading，
              // 服务真的不可达时页面会一直转圈，用户看不到那句可执行的提示。
              if (page.hasError) {
                return _error(page.error!, text, () {
                  ref.invalidate(memoryListProvider(query));
                });
              }
              final data = page.value;
              if (data == null) {
                return _skeleton(text);
              }

              final items = <Memory>[
                ...data.items,
                if (_extraFor == query) ..._extra,
              ];
              if (items.isEmpty) {
                return _empty(text);
              }

              final cursor = _extraFor == query ? _cursor : data.nextCursor;
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: items.length + (cursor == null ? 0 : 1),
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    if (index >= items.length) {
                      return _loadMoreRow(query, cursor!, text);
                    }
                    return _row(items[index], text, palette);
                  },
                ),
              );
            }(),
          ),
        ],
      ),
    );
  }

  Widget _summary(ThemeData theme, AppText text, MemoryStateView state) {
    final parts = <String>[
      '生效 ${state.counts.active}',
      '候选 ${state.counts.candidate}',
      '已归档 ${state.counts.archived}',
    ];
    final quota = state.extract;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(parts.join(' · '), style: text.meta)),
          Text(
            quota.enabled
                ? '今日抽取 ${quota.usedToday}/${quota.dailyLimit}'
                : '自动抽取未开启',
            style: text.meta,
          ),
        ],
      ),
    );
  }

  /// 整理进行中的状态条。
  ///
  /// 只靠按钮上的小圈不够明显：这一轮可能跑几十秒，用户退出再进来时必须
  /// 一眼看到"还在整理"，而不是面对一个灰掉的按钮猜发生了什么。
  Widget _organizingBanner(AppText text, AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: palette.status.surfaceOf(palette.status.info),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: palette.status.borderOf(palette.status.info),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: palette.status.info,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在整理记忆：重算主体状态、归档与归并。可以先离开，完成后列表会自动刷新。',
                style: text.hint.copyWith(color: palette.status.info),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _warning(
    ThemeData theme,
    AppText text,
    AppPalette palette,
    MemoryStateView state,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: palette.status.surfaceOf(palette.status.warning),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: palette.status.borderOf(palette.status.warning)),
        ),
        child: Text(
          state.digestWarning ?? '',
          style: text.hint.copyWith(color: palette.status.warning),
        ),
      ),
    );
  }

  /// 下拉刷新：翻页缓存一并清掉，否则"刷新后还挂着上一次翻到的条目"。
  Future<void> _refresh() async {
    setState(() {
      _extra.clear();
      _extraFor = null;
      _cursor = null;
    });
    ref.invalidate(memoryStateProvider);
    ref.invalidate(memoryListProvider);
  }

  /// 「⋯」菜单的分发。子页面跳转与动作分开处理；清空归档先弹确认框。
  void _onMenuSelected(MemoryMenuSelection selection) {
    switch (selection) {
      case MemoryMenuOrganize():
        _organize();
      case MemoryMenuCandidates():
        openMemoryCandidates(context);
      case MemoryMenuExport():
        openMemoryExport(context);
      case MemoryMenuPurgeArchived(:final kind):
        unawaited(_purgeArchived(kind));
    }
  }

  /// 清空归档：确认后才调服务端，完成后刷新列表与计数。
  Future<void> _purgeArchived(MemoryKind? kind) async {
    if (!mounted || !await confirmPurgeArchived(context, kind)) {
      return;
    }
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      _toast('记忆需要连接服务端才能清空归档');
      return;
    }
    try {
      final purged = await api.purgeArchived(kind: kind);
      ref.invalidate(memoryStateProvider);
      ref.invalidate(memoryListProvider);
      _toast(purged > 0 ? '已清除 $purged 条归档记忆' : '没有可清除的归档记忆');
    } on ApiException catch (error) {
      _toast(error.hint);
    }
  }

  /// 手动整理：服务端立即返回，真正跑完靠轮询状态快照。
  ///
  /// 为什么不等到请求返回：一轮整理最多触发 50 次模型调用，同步等会让按钮
  /// 转圈几十秒，用户会以为卡死。
  Future<void> _organize() async {
    if (_organizing || _polling) {
      return;
    }
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      _toast('记忆需要连接服务端才能整理');
      return;
    }

    setState(() => _organizing = true);
    try {
      final startedAt = await api.organize();
      if (!mounted) {
        return;
      }
      _toast('已开始整理');
      await _pollUntilDone(startedAt: startedAt);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      // 409 是"已经有一轮在跑"：把忙碌态恢复成 false，等那一轮自己结束。
      setState(() => _organizing = false);
      _toast(error.hint);
    }
  }

  /// 进入页面时服务端还在整理：接着轮询，跑完照样刷新并提示结果。
  void _resumePolling() {
    if (_polling) {
      return;
    }
    unawaited(_pollUntilDone());
  }

  /// 轮询到这一轮结束。
  ///
  /// `startedAt` 用来区分"这一轮"和"上一轮"的结果；从快照恢复时拿不到它，
  /// 只要求看到 `organizing` 转 false 即可。
  Future<void> _pollUntilDone({int? startedAt}) async {
    if (_polling) {
      return;
    }
    _polling = true;
    try {
      const step = Duration(seconds: 2);
      const deadline = Duration(seconds: 90);
      var waited = Duration.zero;

      while (mounted && waited < deadline) {
        await Future<void>.delayed(step);
        waited += step;
        if (!mounted) {
          return;
        }

        final api = ref.read(memoryApiProvider);
        if (api == null) {
          break;
        }

        MaintenanceView maintenance;
        try {
          maintenance = (await api.state()).maintenance;
        } on ApiException {
          // 网络抖一下不终止：下一轮再问，超时由 deadline 收口。
          continue;
        }

        final finished =
            !maintenance.organizing &&
            (startedAt == null || (maintenance.lastOrganizedAt ?? 0) >= startedAt);
        if (!finished) {
          continue;
        }

        await _refresh();
        if (!mounted) {
          return;
        }
        setState(() => _organizing = false);
        _toast(_reportSummary(maintenance.lastReport));
        return;
      }

      if (!mounted) {
        return;
      }
      setState(() => _organizing = false);
      _toast('整理还在后台进行，稍后回来查看');
    } finally {
      _polling = false;
    }
  }

  /// 整理结果的摘要。四步都没动到数据时明确说"没有需要整理的内容"，
  /// 而不是弹一个"整理完成"让用户以为出了什么成果。
  String _reportSummary(MaintenanceReportView? report) {
    if (report == null) {
      return '整理完成';
    }
    final parts = <String>[
      if (report.recomputed > 0) '重算 ${report.recomputed} 个主体',
      if (report.consolidated > 0) '归并 ${report.consolidated} 条',
      if (report.decayed > 0) '归档 ${report.decayed} 条',
      if (report.sedimented > 0) '沉淀 ${report.sedimented} 条',
    ];
    if (parts.isEmpty) {
      return '没有需要整理的内容';
    }
    final body = parts.join(' · ');
    return report.modelAvailable ? body : '$body（未配置模型，实体状态未重算）';
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    // 先收掉上一条（"已开始整理"）：否则结果要排在它后面，用户等 4 秒才看到。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _row(Memory memory, AppText text, AppPalette palette) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => openMemoryDetail(context, memory.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    memory.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.row,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Text(memory.metaLine, style: text.meta),
                      if (memory.isPrivate) ...<Widget>[
                        const SizedBox(width: 6),
                        _PrivateBadge(text: text, palette: palette),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (memory.pinned)
              Icon(
                Icons.push_pin_outlined,
                size: 14,
                color: palette.text.tertiary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _loadMoreRow(MemoryQuery query, String cursor, AppText text) {
    return Center(
      child: TextButton(
        onPressed: _loadingMore ? null : () => _loadMore(query, cursor),
        child: Text(_loadingMore ? '加载中…' : '加载更多', style: text.row),
      ),
    );
  }

  Widget _skeleton(AppText text) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
    );
  }

  Widget _empty(AppText text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '还没有记忆。你可以直接说"记住…"，或在候选里确认',
          textAlign: TextAlign.center,
          style: text.hint,
        ),
      ),
    );
  }

  Widget _error(Object error, AppText text, VoidCallback retry) {
    final hint = error is ApiException
        ? '连不上服务端，记忆是服务端权威，无法离线查看'
        : '记忆暂时不可用';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(hint, textAlign: TextAlign.center, style: text.hint),
          const SizedBox(height: 8),
          TextButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 胶囊筛选按钮。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: text.row.copyWith(
            color: selected ? scheme.onPrimaryContainer : null,
          ),
        ),
      ),
    );
  }
}

/// 「私密」胶囊：这类条目不会出现在日常对话的常驻记忆里。
class _PrivateBadge extends StatelessWidget {
  const _PrivateBadge({required this.text, required this.palette});

  final AppText text;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(palette.status.warning),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.status.borderOf(palette.status.warning)),
      ),
      child: Text(
        '私密',
        style: text.badge.copyWith(color: palette.status.warning),
      ),
    );
  }
}
