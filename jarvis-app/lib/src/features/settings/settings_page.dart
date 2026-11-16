import 'package:flutter/material.dart';

import '../../core/design/app_text_styles.dart';
import '../../core/session.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'settings_section_page.dart';
import 'settings_sections.dart';
import 'settings_widgets.dart';

/// 窄屏设置的一级分类列表。
///
/// 宽屏没有这一页：设置是左栏账户菜单弹出的浮层（见 `settings_dialog.dart`）。
/// 窄屏从「我的」推入这里，再点某一项进二级整页——底部导航只停在「我的」那一层，
/// 深层页面盖住它，返回才逐层回来。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.session,
    this.bottomInset = 0,
    this.topInset = 0,
  });

  final SessionState session;

  /// 底部额外留白。
  ///
  /// 被推入时补系统安全区；如果将来又被当成一级标签用，调用方按底部导航
  /// 高度另传一段，列表最后一项才滚得到胶囊上方。
  final double bottomInset;

  /// 顶部额外留白：body 铺到页头之后（`frostTop`），首项要往下让出这一段。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    // 状态栏那一段只能在这里读：这一页是 push 上来的整页，不在骨架的 `SafeArea`
    // 里，而 `frostTop` 让 body 顶边就是窗口顶边（`extendBodyBehindAppBar` 会
    // 移除 body 的顶部 padding），页头自己再按 `padding.top` 下推——内容不让出
    // 这一段，首项就正好压在页头底下。
    //
    // 反过来，若将来把它当外壳内的一级标签页用，`SafeArea` 已把这里的
    // `padding.top` 清零，算式自然退回「16 + 工具条高度」，不会叠成两倍。
    final topSafe = MediaQuery.paddingOf(context).top;

    return AppPageScaffold(
      // 窄屏整页：body 铺到页头之后，列表才能从页头底下滚过并被糊掉。
      frostTop: topInset > 0,
      appBar: MobileAppBar(
        title: '设置',
        showBack: Navigator.of(context).canPop(),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16 + topInset + topSafe,
          16,
          16 + bottomInset,
        ),
        children: <Widget>[
          for (final group in _groups) ...<Widget>[
            Text(group.title, style: AppText.of(context).section),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: <Widget>[
                  for (var i = 0; i < group.sections.length; i++) ...<Widget>[
                    if (i > 0) const Divider(height: 1),
                    SettingsRow(
                      icon: group.sections[i].icon,
                      title: group.sections[i].title,
                      description: _hints[group.sections[i]],
                      onTap: () => openSettingsSectionPage(
                        context,
                        session: session,
                        section: group.sections[i],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          Text(
            '数据默认留在你的机器上；对话文本与语音在调用模型时会外发，'
            '其余内容（业务记录、凭据、运维数据）不出本机。',
            style: AppText.of(context).hint,
          ),
        ],
      ),
    );
  }
}

/// 一级列表的分组与顺序。
///
/// 分组只是窄屏的索引方式，条目与宽屏左栏的五项一一对应：同一栏在两个形态里
/// 叫同一个名字，别在这里另起一套叫法。记忆与无限画布不在设置里——窄屏的入口
/// 在「我的」页，宽屏在左栏账户菜单与动作行。
const List<_SettingsGroup> _groups = <_SettingsGroup>[
  _SettingsGroup('设置', <SettingsSection>[
    SettingsSection.connection,
    SettingsSection.appearance,
    SettingsSection.capability,
    SettingsSection.recording,
  ]),
  _SettingsGroup('关于', <SettingsSection>[
    SettingsSection.maintenance,
  ]),
];

/// 每栏一句说明：一级列表只给"这里有什么"，不展开细节。
const Map<SettingsSection, String> _hints = <SettingsSection, String>{
  SettingsSection.connection: '服务地址、指纹、SSH 与设备身份',
  SettingsSection.appearance: '主题与主题包',
  SettingsSection.capability: '模型配置与技能包',
  SettingsSection.recording: '上传转写、录音笔记与本地音频',
  SettingsSection.maintenance: '登录、版本与数据说明',
};

class _SettingsGroup {
  const _SettingsGroup(this.title, this.sections);

  final String title;
  final List<SettingsSection> sections;
}
