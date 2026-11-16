import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/design/app_palette.dart';
import '../../core/models.dart';
import 'composer_chip.dart';

/// 输入栏里的一枚技能标签（quill 的 embed 节点）。
///
/// 为什么存 JSON 而不是只存技能名：`EmbedBuilder` 只拿得到节点本身，
/// 悬停要展示的说明、来源与风险都在 [SkillInfo] 上。把这些一起塞进 `data`，
/// 渲染时就不必再回头查一次技能列表——查不到时标签会退化成只有名字。
///
/// `data` 用字符串而不是 Map：Delta 是"一次插入一个值"的扁平结构，
/// 嵌套 map 在序列化/反序列化时容易与 quill 自己的约定打架。
class SkillEmbed extends Embeddable {
  SkillEmbed({required SkillInfo skill})
    : skillName = skill.name,
      description = skill.description,
      source = skill.source,
      pluginName = skill.pluginName,
      riskLevel = skill.riskLevel,
      super(skillEmbedType, jsonEncode(_payload(skill)));

  /// 节点类型。带前缀避免与 quill 内置的 image/video 撞名。
  static const String skillEmbedType = 'personal-agent-skill';

  final String skillName;
  final String description;
  final String source;
  final String pluginName;
  final String riskLevel;

  static Map<String, dynamic> _payload(SkillInfo skill) {
    return <String, dynamic>{
      'name': skill.name,
      if (skill.description.isNotEmpty) 'description': skill.description,
      'source': skill.source,
      if (skill.pluginName.isNotEmpty) 'plugin_name': skill.pluginName,
      'risk_level': skill.riskLevel,
    };
  }

  /// 从节点反解；`data` 不是我们写入的 JSON 时返回 null。
  static SkillEmbed? fromNode(Embed node) {
    if (node.value.type != skillEmbedType) {
      return null;
    }
    final data = node.value.data;
    if (data is! String) {
      return null;
    }

    try {
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic>) {
        return null;
      }
      return SkillEmbed.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// 只在解析与测试里用：字段缺失时退化成"只有名字"。
  factory SkillEmbed.fromJson(Map<String, dynamic> json) {
    return SkillEmbed._raw(
      skillName: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      source: '${json['source'] ?? 'builtin'}',
      pluginName: '${json['plugin_name'] ?? ''}',
      riskLevel: '${json['risk_level'] ?? 'read'}',
    );
  }

  SkillEmbed._raw({
    required this.skillName,
    required this.description,
    required this.source,
    required this.pluginName,
    required this.riskLevel,
  }) : super(skillEmbedType, jsonEncode(<String, dynamic>{
         'name': skillName,
         if (description.isNotEmpty) 'description': description,
         'source': source,
         if (pluginName.isNotEmpty) 'plugin_name': pluginName,
         'risk_level': riskLevel,
       }));
}

/// 让 quill 把 [SkillEmbed] 渲染成一枚 pill。
///
/// 删除由标签自己的 X 完成：`EmbedContext` 直接给了 controller 与节点，
/// 算出绝对偏移后删掉这一个字符即可，不需要回调到输入栏。
class SkillEmbedBuilder extends EmbedBuilder {
  const SkillEmbedBuilder();

  @override
  String get key => SkillEmbed.skillEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final node = embedContext.node;
    final embed = SkillEmbed.fromNode(node);
    if (embed == null) {
      return const SizedBox.shrink();
    }

    return SkillChip(
      embed: embed,
      onRemove: () {
        final offset = node.documentOffset;
        embedContext.controller.replaceText(
          offset,
          1,
          '',
          TextSelection.collapsed(offset: offset),
        );
      },
    );
  }
}

/// 标签本体：图标 + 技能名 + X，悬停给出"这个技能会动什么"。
///
/// 外观壳交给 [ComposerChipFrame]：附件芯片与它必须长得一模一样，
/// 只换左侧图标与文字内容。
class SkillChip extends StatelessWidget {
  const SkillChip({super.key, required this.embed, required this.onRemove});

  final SkillEmbed embed;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return ComposerChipFrame(
      // 悬停内容：装了插件之后，这是分辨"这个技能会动什么"的唯一地方。
      tooltip: _tooltipText(),
      leading: Icon(
        Icons.auto_awesome_outlined,
        size: 11,
        color: palette.text.tertiary,
      ),
      label: Text(embed.skillName, style: chipLabelStyle(context)),
      onRemove: onRemove,
    );
  }

  String _tooltipText() {
    final lines = <String>[embed.skillName];

    if (embed.description.isNotEmpty) {
      lines.add(embed.description);
    }

    final origin = embed.source == 'third_party'
        ? (embed.pluginName.isEmpty ? '来自插件' : '来自插件 ${embed.pluginName}')
        : '内置技能';
    lines.add('$origin · ${_riskLabel(embed.riskLevel)}');

    return lines.join('\n');
  }

  static String _riskLabel(String riskLevel) => switch (riskLevel) {
    'irreversible_write' => '不可逆写入',
    'reversible_write' => '可撤销写入',
    _ => '只读',
  };
}
