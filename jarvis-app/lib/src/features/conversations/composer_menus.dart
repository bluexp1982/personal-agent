import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/model_providers.dart';
import '../../core/models.dart';
import '../../core/ui/agent_menu.dart';
import 'approval_mode.dart';
import 'composer_reasoning.dart';

/// 输入栏三个入口的 Key。文案会改，Key 不会——测试靠它定位。
const Key kComposerAttachButtonKey = Key('composer-attach-button');
const Key kComposerPermissionMenuKey = Key('composer-permission-menu');
const Key kComposerModelMenuKey = Key('composer-model-menu');

/// 模型一级浮层里两行各自的 Key：点开它们才会长出二级列表。
const Key kComposerModelSubmenuKey = Key('composer-model-submenu');
const Key kComposerReasoningSubmenuKey = Key('composer-reasoning-submenu');

/// 浮层宽度。
///
/// 都是定值而不是跟着触发器走：触发器只有几十 dp 宽，跟着它会长成一条
/// 放不下「中文名 + 英文别名 + 一句用途」的窄缝。参考图也是小胶囊、宽菜单。
const double kComposerAttachMenuWidth = 340;
const double kComposerPermissionMenuWidth = 300;
const double kComposerModelMenuWidth = 300;
const double kComposerModelSubmenuWidth = 260;

/// 模型胶囊触发器的最大宽度。
///
/// 模型名是外部数据（`model_name` 可以很长），不设上限时窗口一宽就整段铺开，
/// 把右侧的上下文环与发送按钮一路挤到边缘。220 放得下"深度求索 + 模型名"的
/// 有效前缀，又不会抢走控件行的呼吸；超出部分在胶囊内部省略。
const double kComposerModelPillMaxWidth = 220;

/// 权限菜单三枚行首图标的光学补偿系数，按审批值索引。
///
/// 声明尺寸统一（`AgentMenuStyle.iconSize` = 16）并不等于看起来一样大：
/// Material 字形的墨迹包围盒本来就不同。实测（16dp 字号、像素测量）：
/// 手掌 14.00×16.13、盾牌 12.25×14.88、闪电 6.75×12.13——闪电最小。
///
/// 因此以「完全放行」的闪电（1.0）为基准，把前两个**缩小**到同一视觉高度
/// （12.13dp）：手掌 12.13/16.13 ≈ 0.75、盾牌 12.13/14.88 ≈ 0.82。
/// 只改绘制、不改布局；宽度差来自字形本身（手掌横向更宽），不是"大小"差。
const Map<String, double> kComposerPermissionIconScale = <String, double>{
  ApprovalModes.request: 0.75,
  ApprovalModes.auto: 0.82,
  ApprovalModes.trust: 1.0,
};

/// `@` 技能候选的宽度。
///
/// 跟「+」菜单同宽：两者都是"名字 + 一句说明"的单行形态。
/// 候选面板与它们共用 [AgentMenuPanel]，宽度也就该是同一个量级。
const double kComposerSkillMenuWidth = kComposerAttachMenuWidth;

/// 输入栏入口的缺省值。
///
/// 「模型」与「推理等级」不再有假常量：前者读 `GET /api/models` 的生效配置，
/// 后者由页面按会话持有（见 `composer_reasoning.dart`）。这里只剩审批方式，
/// 它的默认值本身就是产品口径。
abstract final class ComposerDefaults {
  static const String permission = ApprovalModes.request;
}

/// 当前平台是不是"桌面三端"。
///
/// 它同时决定三件事，所以只在这里定义一次：
/// - 输入栏能不能接收系统文件拖放（只有桌面有）；
/// - 「+」菜单要不要给「粘贴图片」（桌面有 Cmd/Ctrl+V，移动端没有按键事件，
///   系统菜单的"粘贴"也只带得出文字）；
/// - 文件树的行按下就拖（桌面）还是长按才拖（触摸端，避免和滚动抢手势）。
///
/// 用 getter 而不是 `final`：`final` 会在首次读取时把平台缓存下来，
/// 测试里再改 `defaultTargetPlatform` 就不生效了；平台本来也不会在运行时变。
bool get composerDesktopPlatform =>
    !kIsWeb &&
    const <TargetPlatform>{
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

/// 「+」菜单的清单。
///
/// 只有「添加」与「指令」两组：权限与模型是输入栏上自己的胶囊，
/// 不再重复放进这里。`value` 是动作 id，按它分发。
const List<AgentMenuGroup<String>> kComposerAttachGroups =
    <AgentMenuGroup<String>>[
      AgentMenuGroup<String>(
        title: '添加',
        items: <AgentMenuItem<String>>[
          AgentMenuItem<String>(
            value: 'file',
            label: '文件',
            alias: 'file',
            icon: Icons.attach_file_rounded,
            description: '选择文件或图片，可多选',
          ),
          AgentMenuItem<String>(
            value: 'plan',
            label: '计划',
            alias: 'plan',
            icon: Icons.checklist_rounded,
            description: '进入或退出计划模式',
          ),
        ],
      ),
      AgentMenuGroup<String>(
        title: '指令',
        items: <AgentMenuItem<String>>[
          AgentMenuItem<String>(
            value: 'compact',
            label: '压缩',
            alias: 'compact',
            icon: Icons.compress_rounded,
            description: '压缩以上对话内容',
          ),
          AgentMenuItem<String>(
            value: 'export',
            label: '下载日志',
            alias: 'export',
            icon: Icons.download_rounded,
            description: '将当前会话内容导出为 ZIP',
          ),
        ],
      ),
    ];

/// 移动端的「添加」组：多一项「粘贴图片」。
///
/// 桌面端不给这一项：那里 Cmd/Ctrl+V 直接就能贴，菜单里再放一遍是重复入口。
/// 移动端反过来——系统粘贴面板只会把图片当文本处理，取不到字节。
List<AgentMenuGroup<String>> composerAttachGroups({required bool desktop}) {
  if (desktop) {
    return kComposerAttachGroups;
  }
  return <AgentMenuGroup<String>>[
    for (final group in kComposerAttachGroups)
      if (group.title == '添加')
        AgentMenuGroup<String>(
          title: group.title,
          items: <AgentMenuItem<String>>[
            ...group.items,
            const AgentMenuItem<String>(
              value: 'paste',
              label: '粘贴图片',
              alias: 'paste',
              icon: Icons.content_paste_rounded,
              description: '从剪贴板取一张图片',
            ),
          ],
        )
      else
        group,
  ];
}

/// 「权限」菜单的清单：三项，问的是"要不要人来批"。
///
/// 不带 `selected`：当前值由 [ComposerPermissionMenu.value] 决定，
/// 勾选在 build 时算——同一份清单一处定义、多处复用也不会串味。
///
/// 删掉了「仅可查看 / 完全权限」：这两个值从来没有后端语义，留着只会让人以为
/// 自己调了沙箱，实际上什么都没发生。
const List<AgentMenuItem<String>> kComposerPermissionItems =
    <AgentMenuItem<String>>[
      AgentMenuItem<String>(
        value: ApprovalModes.request,
        label: '请求审批',
        icon: Icons.pan_tool_outlined,
      ),
      AgentMenuItem<String>(
        value: ApprovalModes.auto,
        label: '帮我审批',
        icon: Icons.verified_user_outlined,
      ),
      AgentMenuItem<String>(
        value: ApprovalModes.trust,
        label: '完全放行',
        icon: Icons.bolt_outlined,
      ),
    ];

/// 一份配置提供的一个可选模型。
///
/// 现在服务端一份配置只有单个 `model`，所以 [modelsOf] 恒返回一条；将来
/// 一个供应商配置支持多个模型时，只改那个函数，菜单结构不用动。
class ComposerModelOption {
  const ComposerModelOption({required this.id, required this.label});

  /// 稳定标识（发给服务端的模型 ID）。
  final String id;

  /// 界面展示用的名字。
  final String label;
}

/// 当前生效配置提供的模型清单。顺序即展示顺序。
List<ComposerModelOption> modelsOf(ModelProfileView profile) {
  return <ComposerModelOption>[
    ComposerModelOption(id: profile.model, label: profile.displayModel),
  ];
}

// ---------------------------------------------------------------------------
// 三个入口
// ---------------------------------------------------------------------------
// 这里只剩"内容清单 + 触发器"，浮层长什么样、怎么开合、宽度怎么换算、
// 悬停与折角动画全部由 `core/ui/agent_menu.dart` 的 `AgentMenu` 负责。

/// 「+」：添加文件 / 计划，或调用指令。
class ComposerAttachButton extends StatelessWidget {
  const ComposerAttachButton({super.key, this.onSelected});

  /// 选中某一项（回传动作 id）。`file` 与 `paste` 已经接上真实动作，
  /// `plan` / `compact` / `export` 仍是占位：条目照样能点（收菜单），没有后续。
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    return AgentMenu<String>(
      width: kComposerAttachMenuWidth,
      tooltip: '添加文件或调用指令',
      groups: composerAttachGroups(desktop: composerDesktopPlatform),
      onSelected: (value) => onSelected?.call(value),
      builder: (context, controller, open, hovering) => AgentMenuIconTrigger(
        key: kComposerAttachButtonKey,
        icon: Icons.add_rounded,
        open: open,
        hovering: hovering,
      ),
    );
  }
}

/// 「权限」：请求审批 / 帮我审批 / 完全放行。
///
/// 值是稳定 id（`request` / `auto`），不是中文文案：文案会改，id 要跟着任务
/// 一路传到 worker 的规则引擎里。
class ComposerPermissionMenu extends StatelessWidget {
  const ComposerPermissionMenu({
    super.key,
    this.value = ComposerDefaults.permission,
    this.onSelected,
  });

  final String value;

  /// 选中某一项。不传时条目照样能点（收菜单），只是没人接这个动作。
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final current = kComposerPermissionItems.firstWhere(
      (item) => item.value == value,
      orElse: () => kComposerPermissionItems.first,
    );

    return AgentMenu<String>(
      width: kComposerPermissionMenuWidth,
      tooltip: '切换审批方式',
      groups: <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          title: '应如何审批',
          items: <AgentMenuItem<String>>[
            for (final item in kComposerPermissionItems)
              AgentMenuItem<String>(
                value: item.value,
                label: item.label,
                icon: item.icon,
                // 两行形态：标题 + 一句用途。菜单行宽 300，放得下。
                subtitle: ApprovalModes.describe(
                  item.value ?? ApprovalModes.request,
                ),
                leading: _permissionIcon(context, item),
                selected: item.value == value,
              ),
          ],
        ),
      ],
      onSelected: (value) => onSelected?.call(value),
      builder: (context, controller, open, hovering) => AgentMenuPill(
        key: kComposerPermissionMenuKey,
        icon: current.icon,
        // 与菜单项同一套尺寸与补偿：触发器上的手掌/盾牌/闪电要和展开后
        // 那三行看起来一样大，否则开合之间像换了一套图标。
        iconSize: AgentMenuStyle.iconSize,
        iconScale: kComposerPermissionIconScale[current.value ?? ''] ?? 1,
        label: current.label,
        // 与模型胶囊同一档（11.5）：两个入口并排，一边大一边小会让中文那个
        // 看起来像主按钮，而它们只是同一行的两个并列设置。
        labelSize: AppFontSize.sm,
        open: open,
        hovering: hovering,
      ),
    );
  }

  /// 权限行的行首图标：固定占位框 + 声明尺寸统一 + 光学补偿。
  ///
  /// `Transform.scale` 不参与布局，所以三行的图标占位仍是同一块 18×18；
  /// 缩放后的墨迹也不会压到右侧文字（最大 1.0，框内仍有余量）。
  /// 占位框与触发器胶囊共用 [AgentMenuStyle.triggerIconBox]：来回开合菜单时
  /// 同一个图标不会因为容器尺寸不同而跳位。
  Widget _permissionIcon(BuildContext context, AgentMenuItem<String> item) {
    final scale = kComposerPermissionIconScale[item.value ?? ''] ?? 1;
    return SizedBox.square(
      key: ValueKey<String>('permission-icon-${item.value}'),
      dimension: AgentMenuStyle.triggerIconBox,
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: Icon(
            item.icon,
            size: AgentMenuStyle.iconSize,
            color: AppPalette.of(context).text.secondary,
          ),
        ),
      ),
    );
  }
}

/// 「模型」：一级浮层两行（模型 / 推理等级），各自向右再长一层。
///
/// 「模型」这一行只列**当前生效供应商配置**提供的模型：现在一份配置只有
/// 一个模型，所以二级里恒为一条；将来一份配置带多个模型时只改 [modelsOf]，
/// 交互与组件都不动。
class ComposerModelMenu extends ConsumerWidget {
  const ComposerModelMenu({
    super.key,
    this.reasoning = ReasoningLevels.fallback,
    this.onReasoningChanged,
  });

  /// 推理等级当前值（[ReasoningLevels] 里的字符串）。
  final String reasoning;

  /// 切换推理等级；不传就是只读展示。
  final ValueChanged<String>? onReasoningChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeModelProvider);
    final label = active?.displayModel ?? '';

    return AgentMenu<String>(
      width: kComposerModelMenuWidth,
      tooltip: '选择模型与推理等级',
      // 模型胶囊贴着窗口右沿：默认「从胶囊左上角向右长」会顶出窗口，
      // `MenuAnchor` 只能把面板夹到贴着窗口边——最外侧那 1px 描边和 16dp
      // 投影就都被裁掉，看着像「少一条边、没阴影」。
      // 所以锚到胶囊右下角，再把面板整个左移一个面板宽：面板右边缘正好压在
      // 胶囊右边缘上，既不越界，也和触发器是对齐的。
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(
        kComposerModelMenuWidth,
      ),
      groups: <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          items: <AgentMenuItem<String>>[
            AgentMenuItem<String>(
              key: kComposerModelSubmenuKey,
              label: '模型',
              submenuValue: label.isEmpty ? '未配置' : label,
              submenuWidth: kComposerModelSubmenuWidth,
              submenu: _modelGroups(active),
            ),
            // 当前配置不认 `reasoning_effort` 时整行不出现：留一个点了会被
            // 服务端拦下的入口，比没有入口更让人困惑。
            if (active?.reasoning ?? false)
              AgentMenuItem<String>(
                key: kComposerReasoningSubmenuKey,
                label: '推理等级',
                submenuValue: ReasoningLevels.labelOf(reasoning),
                submenuWidth: kComposerModelSubmenuWidth,
                submenu: <AgentMenuGroup<String>>[
                  AgentMenuGroup<String>(
                    items: <AgentMenuItem<String>>[
                      for (final level in ReasoningLevels.all)
                        AgentMenuItem<String>(
                          value: level,
                          label: ReasoningLevels.labelOf(level),
                          subtitle: ReasoningLevels.describe(level),
                          selected: level == reasoning,
                          onSelected: onReasoningChanged,
                        ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ],
      onSelected: (_) {},
      builder: (context, controller, open, hovering) => ConstrainedBox(
        // 模型名可能很长（`深度求索 deepseek-v4.1-flash-1017`）：给一个上限，
        // 让它在胶囊内部省略，而不是一路铺到上下文环、把右侧控件挤走。
        constraints: const BoxConstraints(maxWidth: kComposerModelPillMaxWidth),
        child: AgentMenuPill(
          key: kComposerModelMenuKey,
          label: label.isEmpty ? '未配置模型' : label,
          // 与权限胶囊同一档（11.5）：两个并列入口不该出现字号差；
          // 纯英文在这个档位上的视觉重量也正好，不会比中文更像标题。
          labelSize: AppFontSize.sm,
          open: open,
          hovering: hovering,
        ),
      ),
    );
  }
}

/// 二级里「当前配置的模型」那一组。
///
/// 一份配置都没有时给一条禁用说明，而不是空白浮层——菜单空着会让人以为
/// 点错了地方。
List<AgentMenuGroup<String>> _modelGroups(ModelProfileView? active) {
  if (active == null) {
    return <AgentMenuGroup<String>>[
      AgentMenuGroup<String>(
        items: <AgentMenuItem<String>>[
          AgentMenuItem<String>(
            value: '',
            label: '还没有可用的模型配置',
            subtitle: '去「设置 › 能力 › 模型」添加一份',
            enabled: false,
          ),
        ],
      ),
    ];
  }

  return <AgentMenuGroup<String>>[
    AgentMenuGroup<String>(
      title: active.name,
      items: <AgentMenuItem<String>>[
        for (final model in modelsOf(active))
          AgentMenuItem<String>(
            value: model.id,
            label: model.label,
            // 组里只有一个模型，它就是当前生效的那个。
            selected: true,
            enabled: active.available,
            // 原因走副标题而不是行尾说明：模型名 + 一句原因 + 勾在同一条窄行里
            // 会挤到溢出，两行富文本才放得下。
            subtitle: active.available ? null : active.reason,
          ),
      ],
    ),
  ];
}
