import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';

/// 设置页的排版与标签唯一实现处。
///
/// 改造前这一页混着两套口径：`ListTile` 默认的 16 / 14（服务地址、设备名…），
/// 与模型 / 技能卡片手写的 14 / 11.5；「已保存」是 11.5 的胶囊，主题卡的
/// 「深色 / 浅色」又是 10.5 的另一枚，底色还有 0.10 与 0.12 两种写法。
/// 同一角色在四处各写一套，加一个设置项就要先猜一遍历史。
///
/// 现在收成四层：分组标题 16 / w500（`AppText.section`）→ 卡片标题 16 / w600
/// 加说明 11.5（[SettingsCardHeader]）→ 条目行 14 / w500 加值 11.5
/// （[SettingsRow] / [SettingsSwitchRow]）→ 标签 10.5 / w600（[SettingsTag]）。
/// 五个块都只从 `core/design` 取色与字号，页面与各卡片只负责摆内容。

/// 设置页的卡片头：图标 + 标题 + 一句说明。
///
/// 与条目行刻意不同档：卡片头是「这一组是什么」，条目行是「这一项怎么设」。
/// 副标题用 [SettingsDescription] 包一句说明；需要状态圆点之类的自绘内容时
/// 直接把整块作为 `subtitle` 传进来，样式仍从 `AppText` 取。
class SettingsCardHeader extends StatelessWidget {
  const SettingsCardHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 为假时标题与图标降一档灰（点不动但仍然要看得见）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final tone = enabled ? palette.text.primary : palette.text.secondary;

    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: enabled ? palette.text.secondary : palette.text.tertiary,
      ),
      title: Text(title, style: text.cardTitle.copyWith(color: tone)),
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// 卡片头 / 条目行下面那句说明：11.5 / 1.5 / tertiary。
class SettingsDescription extends StatelessWidget {
  const SettingsDescription(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(message, style: AppText.of(context).hint);
  }
}

/// 设置页的条目行：图标 + 标题 + 说明或值 +（可选）尾部控件。
///
/// 标题固定 14 / w500；[description] 是解释性文字（11.5 / tertiary），
/// [value] 是要被读出来的内容（地址、版本、设备 ID，用 secondary 稍亮一档）。
/// 两者只填一个：一行里同时塞解释与值会把它挤成两段，改版时又会长出第三档灰。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.value,
    this.subtitle,
    this.valueMono = false,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? value;

  /// 需要自绘副行（异步读数之类）时用它，样式由调用方从 `AppText` 取。
  final Widget? subtitle;

  /// 值是等宽的（路径、指纹、ID）：字形要对齐，才看得出手打错没有。
  final bool valueMono;

  final Widget? trailing;
  final VoidCallback? onTap;

  /// 危险动作（解除配对这类）：图标与标题走状态红。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final tone = destructive ? palette.status.danger : palette.text.primary;

    return ListTile(
      leading: Icon(
        icon,
        size: 20,
        color: destructive ? palette.status.danger : palette.text.secondary,
      ),
      title: Text(
        title,
        style: text.row.copyWith(
          fontWeight: AppWeight.medium,
          color: tone,
        ),
      ),
      subtitle: _subtitle(palette, text),
      trailing:
          trailing ??
          (onTap == null
              ? null
              : Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: destructive
                      ? palette.status.danger
                      : palette.text.tertiary,
                )),
      onTap: onTap,
    );
  }

  Widget? _subtitle(AppPalette palette, AppText text) {
    if (subtitle != null) {
      return subtitle;
    }
    if (value != null) {
      return Text(
        value!,
        style: valueMono
            ? text.mono(
                size: AppFontSize.sm,
                height: AppLineHeight.normal,
                color: palette.text.secondary,
              )
            : text.meta.copyWith(color: palette.text.secondary),
      );
    }
    if (description != null) {
      return Text(description!, style: text.hint);
    }
    return null;
  }
}

/// 设置页的开关行：与 [SettingsRow] 同一套文字，行为交给 `SwitchListTile`。
///
/// 不用 `SwitchListTile.adaptive`：macOS / iOS 上它会落成 `CupertinoSwitch`，
/// 激活色是系统的绿色，整页只有它不跟主题走。普通构造取 `scheme.primary`，
/// 与其它三个开关同源。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    required this.value,
    required this.onChanged,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 图标自带语义色时（如「已启用」的信封图标）由调用方传；默认走二级灰。
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final enabled = onChanged != null;

    return SwitchListTile(
      secondary: Icon(
        icon,
        size: 20,
        color: iconColor ??
            (enabled ? palette.text.secondary : palette.text.tertiary),
      ),
      title: Text(
        title,
        style: text.row.copyWith(
          fontWeight: AppWeight.medium,
          color: enabled ? palette.text.primary : palette.text.secondary,
        ),
      ),
      subtitle: description == null
          ? null
          : Text(description!, style: text.hint),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 设置页里的状态标签：10.5 / w600，胶囊底与描边由同一个状态色派生。
///
/// 尺寸取「外观 → 主题」卡片上那枚「深色 / 浅色」：这一页所有标签（已保存、
/// 当前、已停用、只读、可用…）都按它对齐，避免 11.5 与 10.5 两代标签并排出现。
class SettingsTag extends StatelessWidget {
  const SettingsTag({super.key, required this.label, required this.color});

  final String label;

  /// 传 `palette.status.*` / `scheme.primary`：底 12%、描边 35% 都由它派生。
  final Color color;

  @override
  Widget build(BuildContext context) {
    final status = AppPalette.of(context).status;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: status.borderOf(color)),
      ),
      child: Text(
        label,
        style: AppText.of(context).badge.copyWith(
          letterSpacing: AppLetterSpacing.tight,
          color: color,
        ),
      ),
    );
  }
}

/// 卡片内的状态横幅：琥珀「还没轮到它」、红「这一步失败了」。
///
/// [boxed] 为真时是一块独立圆角块（主题包面板里的失效 / 加载失败提示），
/// 为假时铺满卡片宽度、夹在两条分隔线之间（模型与技能卡片的横幅）。
class SettingsBanner extends StatelessWidget {
  const SettingsBanner({
    super.key,
    required this.icon,
    required this.message,
    required this.color,
    this.boxed = false,
  });

  final IconData icon;
  final String message;
  final Color color;
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final status = AppPalette.of(context).status;
    final body = Row(
      children: <Widget>[
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            style: AppText.of(context).meta.copyWith(color: color),
          ),
        ),
      ],
    );

    if (!boxed) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: status.surfaceOf(color),
        child: body,
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: status.borderOf(color)),
      ),
      child: body,
    );
  }
}
