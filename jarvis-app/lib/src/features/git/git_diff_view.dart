import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/git_models.dart';
import '../../core/git_providers.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/shell_layout_state.dart';

/// 单个文件（或某次提交）的 diff。
///
/// 不做并排双栏：面板最窄 320、最宽 900，双栏在窄屏上会把每侧压到 150 以内，
/// 连一个缩进都放不下。统一视图 + 横向滚动在三种宽度上都读得下去。
class GitDiffView extends ConsumerWidget {
  const GitDiffView({super.key, required this.diffKey, required this.onBack});

  final GitDiffKey diffKey;

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final async = ref.watch(gitDiffProvider(diffKey));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 同上：重取期间保留上一次的增删行数，标题栏不该闪一下空值。
        _header(context, async.value),
        Expanded(
          child: switch (async) {
            AsyncValue(:final error?) => _hint(
              palette,
              error is ApiException ? error.userMessage : '$error',
              icon: Icons.error_outline_rounded,
              color: palette.status.danger,
            ),
            AsyncValue(:final value?) => _body(context, value),
            _ => const Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          },
        ),
      ],
    );
  }

  Widget _header(BuildContext context, GitDiffReport? report) {
    final palette = AppPalette.of(context);
    final commit = diffKey.commit;
    final label = commit == null
        ? diffKey.path
        : '提交 ${commit.length > 7 ? commit.substring(0, 7) : commit}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset - 4,
        0,
        kPaneContentInset,
        2,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '返回列表',
            onPressed: onBack,
            style: shellIconButtonStyle(
              minimumSize: const Size.square(kPaneHeaderButtonSize),
            ),
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              // 从末尾省略：文件名的前缀（目录）不重要，名字才重要。
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                fontWeight: AppWeight.medium,
                color: palette.text.primary,
              ),
            ),
          ),
          if (report != null && !report.binary) ...<Widget>[
            const SizedBox(width: 6),
            Text(
              '+${report.additions}',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                fontFamily: AppMono.family,
                fontFamilyFallback: AppMono.fallback,
                color: palette.status.success,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '-${report.deletions}',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                fontFamily: AppMono.family,
                fontFamilyFallback: AppMono.fallback,
                color: palette.status.danger,
              ),
            ),
          ],
          if (diffKey.staged && diffKey.commit == null) ...<Widget>[
            const SizedBox(width: 6),
            _Tag(text: '已暂存', color: palette.status.info),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, GitDiffReport report) {
    final palette = AppPalette.of(context);
    if (report.binary) {
      return _hint(palette, '二进制文件没有可显示的差异', icon: Icons.data_object_rounded);
    }
    if (report.text.trim().isEmpty) {
      return _hint(
        palette,
        '这个文件没有可显示的差异',
        icon: Icons.horizontal_rule_rounded,
      );
    }

    final lines = report.text.split('\n');
    // 去掉最后一个空行：diff 文本以 `\n` 结尾，多出来的一行会在底部留白。
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }

    // 横向宽度按"最长一行 × 等宽字宽"估：等宽字体每字宽度稳定，
    // 估宽只用于给横向滚动一个边界，行本身用 `softWrap: false` 保证绝不折行。
    var widest = 0;
    for (final line in lines) {
      if (line.length > widest) {
        widest = line.length;
      }
    }
    final width = widest * AppFontSize.md * 0.62 + 24;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: ListView.builder(
                  // 一次只建屏内的行：512 KB 的 diff 有几万行，
                  // 全建出来光是创建 Text 就够卡两秒。
                  itemCount: lines.length,
                  itemBuilder: (context, index) =>
                      _DiffLine(line: lines[index]),
                ),
              ),
            ),
          ),
        ),
        if (report.truncated)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: palette.status.warning.withValues(alpha: 0.12),
            child: Text(
              '差异过长，只显示前 512 KB',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                color: palette.text.secondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _hint(
    AppPalette palette,
    String message, {
    required IconData icon,
    Color? color,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          16,
          kPaneContentInset,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 24, color: color ?? palette.text.tertiary),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: palette.text.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppFontSize.xs,
          fontWeight: AppWeight.semiBold,
          color: color,
        ),
      ),
    );
  }
}

/// 一行 diff：增删着色、hunk 头单独一档颜色。
class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = _classify(line, palette);

    return Container(
      color: style.background,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        // 空行也要占位，否则 hunk 里删掉空行后行号对不上。
        line.isEmpty ? ' ' : line,
        softWrap: false,
        style: TextStyle(
          fontFamily: AppMono.family,
          fontFamilyFallback: AppMono.fallback,
          fontSize: AppFontSize.md,
          height: AppLineHeight.code,
          color: style.foreground,
        ),
      ),
    );
  }

  static ({Color foreground, Color? background}) _classify(
    String line,
    AppPalette palette,
  ) {
    // 文件头先判：`+++` / `---` 也以 +/- 开头，落到增删分支会被染成绿/红。
    if (line.startsWith('+++ ') ||
        line.startsWith('--- ') ||
        line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('new file') ||
        line.startsWith('deleted file') ||
        line.startsWith('old mode') ||
        line.startsWith('new mode') ||
        line.startsWith('similarity index') ||
        line.startsWith('rename ') ||
        line.startsWith('Binary files')) {
      return (foreground: palette.text.tertiary, background: null);
    }
    if (line.startsWith('@@')) {
      return (foreground: palette.status.info, background: null);
    }
    if (line.startsWith('+')) {
      return (
        foreground: palette.text.primary,
        background: palette.status.success.withValues(alpha: 0.12),
      );
    }
    if (line.startsWith('-')) {
      return (
        foreground: palette.text.primary,
        background: palette.status.danger.withValues(alpha: 0.12),
      );
    }
    return (foreground: palette.text.secondary, background: null);
  }
}
