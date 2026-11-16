import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session.dart';

/// 上传开关的存储键。默认关闭：音频离开本机必须由用户显式同意。
const String kRecordingUploadEnabledKey = 'recording_upload_enabled';

/// 首次告知是否已读。
const String kRecordingDisclosureSeenKey = 'recording_disclosure_seen';

class RecordingPreferences {
  const RecordingPreferences({
    required this.uploadEnabled,
    required this.disclosureSeen,
  });

  const RecordingPreferences.defaults()
    : uploadEnabled = false,
      disclosureSeen = false;

  /// 是否允许把音频上传到服务端转写。
  final bool uploadEnabled;

  /// 是否已经看过"音频会发给模型厂商"的一次性说明。
  final bool disclosureSeen;

  RecordingPreferences copyWith({bool? uploadEnabled, bool? disclosureSeen}) =>
      RecordingPreferences(
        uploadEnabled: uploadEnabled ?? this.uploadEnabled,
        disclosureSeen: disclosureSeen ?? this.disclosureSeen,
      );
}

final AsyncNotifierProvider<
  RecordingPreferencesController,
  RecordingPreferences
>
recordingPreferencesProvider =
    AsyncNotifierProvider<RecordingPreferencesController, RecordingPreferences>(
      RecordingPreferencesController.new,
    );

class RecordingPreferencesController
    extends AsyncNotifier<RecordingPreferences> {
  @override
  Future<RecordingPreferences> build() async {
    final store = ref.watch(secretStoreProvider);
    try {
      return RecordingPreferences(
        uploadEnabled: await store.read(kRecordingUploadEnabledKey) == 'true',
        disclosureSeen: await store.read(kRecordingDisclosureSeenKey) == 'true',
      );
    } on Exception {
      // 钥匙串/回退目录不可用时退回默认值：宁可显示"仅本地"，
      // 也不要因为读不出偏好就默认开始上传。
      return const RecordingPreferences.defaults();
    }
  }

  Future<void> setUploadEnabled(bool enabled) async {
    final current = state.value ?? const RecordingPreferences.defaults();
    state = AsyncData(current.copyWith(uploadEnabled: enabled));
    try {
      await ref
          .read(secretStoreProvider)
          .write(kRecordingUploadEnabledKey, enabled ? 'true' : 'false');
    } on Exception {
      // 落盘失败只影响下次启动，本次开关已经生效。
    }
  }

  Future<void> markDisclosureSeen() async {
    final current = state.value ?? const RecordingPreferences.defaults();
    state = AsyncData(current.copyWith(disclosureSeen: true));
    try {
      await ref
          .read(secretStoreProvider)
          .write(kRecordingDisclosureSeenKey, 'true');
    } on Exception {
      // 同上：不因为写不进去就反复弹告知。
    }
  }
}
