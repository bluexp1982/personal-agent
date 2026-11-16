import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_providers.dart';
import '../../core/recording/recording_settings.dart';
import '../../core/session.dart';
import '../../core/ssh/ssh_controller.dart';
import '../../version.dart';
import '../recordings/recording_privacy_sheet.dart';
import 'model_config_card.dart';
import 'plugin_manager_card.dart';
import 'settings_widgets.dart';
import 'ssh_login_card.dart';
import 'theme_picker.dart';

/// 设置的内栏：宽屏弹窗左栏的一项，窄屏「我的 → 设置」列表的一行。
///
/// 枚举只描述「有哪几栏、叫什么、配哪枚图标」；每栏装什么内容在
/// [SettingsSectionView] 里按 [SettingsSection] 分流。
/// 新增一栏时这两处一起改，别在弹窗与窄屏列表里各写一份。
enum SettingsSection {
  connection('连接与设备', Icons.devices_outlined),
  appearance('外观', Icons.palette_outlined),
  capability('能力', Icons.tune),
  recording('录音', Icons.mic_none_outlined),
  maintenance('维护与关于', Icons.info_outline);

  const SettingsSection(this.title, this.icon);

  /// 左栏标题，也是窄屏二级页的页头标题。
  final String title;

  final IconData icon;
}

/// 一栏设置的内容。
///
/// 由宿主负责「摆在哪」：宽屏弹窗的右栏、窄屏的二级整页共用这一份实现，
/// 差别只有 [padding]。外壳（栏头、返回、底栏）不在这里，避免两套代码漂移。
class SettingsSectionView extends ConsumerWidget {
  const SettingsSectionView({
    super.key,
    required this.session,
    required this.section,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 16),
  });

  final SessionState session;
  final SettingsSection section;

  /// 内容内边距由宿主决定：弹窗右栏、窄屏二级页各有一套边距。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(padding: padding, children: _children(context, ref));
  }

  List<Widget> _children(BuildContext context, WidgetRef ref) {
    return switch (section) {
      SettingsSection.connection => _connection(context),
      SettingsSection.appearance => _appearance(),
      SettingsSection.capability => _capability(),
      SettingsSection.recording => _recording(context, ref),
      SettingsSection.maintenance => _maintenance(context, ref),
    };
  }

  /// 连接与设备：服务地址、指纹、SSH 凭据与设备身份。
  ///
  /// SSH 跟着「连接」走：它登录的正是上面这个服务地址对应的那台机器；
  /// 设备名 / 设备 ID 也放这里——它们和地址、指纹是同一族「这台机器是谁」。
  List<Widget> _connection(BuildContext context) {
    return <Widget>[
      Card(
        child: Column(
          children: <Widget>[
            SettingsRow(
              icon: Icons.dns_outlined,
              title: '服务地址',
              value: session.serverUrl,
            ),
            const Divider(height: 1),
            SettingsRow(
              icon: Icons.fingerprint,
              title: '服务端指纹',
              value: session.serverFingerprint ?? '未记录（重新配对后可获取）',
              valueMono: true,
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      SshLoginCard(session: session),
      const SizedBox(height: 20),
      Card(
        child: Column(
          children: <Widget>[
            SettingsRow(
              icon: Icons.devices_outlined,
              title: '设备名',
              value: session.deviceName.isEmpty ? '未命名' : session.deviceName,
            ),
            const Divider(height: 1),
            SettingsRow(
              icon: Icons.badge_outlined,
              title: '设备 ID',
              value: session.deviceId ?? '-',
              valueMono: true,
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _appearance() {
    return const <Widget>[
      Card(
        child: Column(
          children: <Widget>[
            SettingsCardHeader(
              icon: Icons.palette_outlined,
              title: '主题',
              subtitle: SettingsDescription('跟随系统时随操作系统外观切换；也可以装自己的主题包'),
            ),
            Divider(height: 1),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: ThemePicker(),
            ),
          ],
        ),
      ),
    ];
  }

  /// 能力：模型决定"这台机器用什么脑子"，技能包决定"能做什么"。
  List<Widget> _capability() {
    return const <Widget>[
      ModelConfigCard(),
      SizedBox(height: 12),
      PluginManagerCard(),
    ];
  }

  List<Widget> _recording(BuildContext context, WidgetRef ref) {
    final recordingPrefs = ref.watch(recordingPreferencesProvider).value;
    final recordingInfo = ref.watch(recordingInfoProvider).value;

    return <Widget>[
      Card(
        child: Column(
          children: <Widget>[
            SettingsSwitchRow(
              icon: Icons.cloud_upload_outlined,
              title: '允许上传转写',
              description: recordingPrefs?.uploadEnabled == true
                  ? (recordingInfo?.asrAvailable == true
                        ? '已开启：音频经服务端转写，转写稿存在服务端'
                        : '已开启，但服务端还没配置转写：音频只归档、不出文字')
                  : '关闭时只录不传，音频留在本机，界面标记「仅本地」',
              value: recordingPrefs?.uploadEnabled == true,
              onChanged: (value) async {
                await ref
                    .read(recordingPreferencesProvider.notifier)
                    .setUploadEnabled(value);
                ref.invalidate(recordingInfoProvider);
                if (value) {
                  await ref
                      .read(recordingControllerProvider.notifier)
                      .syncPending();
                }
              },
            ),
            const Divider(height: 1),
            SettingsRow(
              icon: Icons.privacy_tip_outlined,
              title: '音频去向',
              description: '音频先存本地；开启上传后会经服务端发给模型厂商转写',
              onTap: () => showRecordingPrivacySheet(context, ref),
            ),
            const Divider(height: 1),
            SettingsRow(
              icon: Icons.storage_outlined,
              title: '本地音频占用',
              subtitle: FutureBuilder<int>(
                future: ref.watch(recordingStoreProvider).value?.diskUsage(),
                builder: (context, snapshot) {
                  final usage = snapshot.data;
                  return Text(
                    usage == null ? '读取中…' : formatBytes(usage),
                    style: AppText.of(context).meta.copyWith(
                      color: AppPalette.of(context).text.secondary,
                    ),
                  );
                },
              ),
              trailing: TextButton(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('清理已上传的本地音频？'),
                      content: const Text(
                        '只删除已经完整上传到服务端的本地音频；服务端归档与转写稿保留。'
                        '之后播放会改为按需下载。',
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(dialogContext).pop(true),
                          child: const Text('清理'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) {
                    return;
                  }
                  final removed = await ref
                      .read(recordingControllerProvider.notifier)
                      .clearUploadedAudio();
                  if (!context.mounted) {
                    return;
                  }
                  ref.invalidate(recordingsLibraryProvider);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        removed == 0
                            ? '没有可清理的本地音频'
                            : '已清理 $removed 条录音的本地音频',
                      ),
                    ),
                  );
                },
                child: const Text('清理'),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// 维护与关于：会话维护、版本与数据去向。
  List<Widget> _maintenance(BuildContext context, WidgetRef ref) {
    return <Widget>[
      Card(
        child: Column(
          children: <Widget>[
            SettingsRow(
              icon: Icons.login,
              title: '重新登录',
              description: '用本机密钥重新换取会话令牌，不需要重新配对',
              onTap: () async {
                await ref.read(sessionProvider.notifier).retryLogin();
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已尝试重新登录')));
              },
            ),
            const Divider(height: 1),
            SettingsRow(
              icon: Icons.link_off,
              title: '解除配对',
              description: '清除本机密钥与令牌，需要重新配对才能连接',
              destructive: true,
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('解除配对？'),
                    content: const Text('本机保存的密钥与令牌会被删除。之后需要重新生成配对码并配对。'),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('解除'),
                      ),
                    ],
                  ),
                );
                if (confirmed ?? false) {
                  // 先断终端并清掉 SSH 凭据与主机指纹：解除配对等于"不再信任
                  // 那台机器"，留着 shell 会话与密码是最不该留的残留。
                  await ref.read(sshControllerProvider.notifier).forgetSaved();
                  await ref.read(sessionProvider.notifier).forgetDevice();
                }
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Card(
        child: Column(
          children: <Widget>[
            SettingsRow(
              icon: Icons.info_outline,
              title: '客户端版本',
              // 版本来自安装包：加载中与读取失败都给一句可读的话，不留空白。
              value: ref
                  .watch(appBuildInfoProvider)
                  .when(
                    data: (info) => info.display,
                    loading: () => '读取中…',
                    error: (error, stackTrace) => '未知（读取失败）',
                  ),
            ),
            const Divider(height: 1),
            const SettingsRow(icon: Icons.api, title: '接口版本', value: apiVersion),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const SettingsDescription(
        '数据默认留在你的机器上；对话文本与语音在调用模型时会外发，'
        '其余内容（业务记录、凭据、运维数据）不出本机。',
      ),
    ];
  }
}
