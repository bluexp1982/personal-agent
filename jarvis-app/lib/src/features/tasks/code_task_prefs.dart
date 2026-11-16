// 编码任务「用哪个 CLI 干活」的本地偏好。
//
// 走 [SecretStore] 而不是另开一种存储：项目里所有"用户选过的东西"都在这一个
// 地方（主题、项目模式、SSH 凭据），多一种存储就多一处平台差异。这里存的
// 虽然不是凭据，但同样不该出现在日志或备份里。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/secret_store.dart';
import '../../core/session.dart';

/// 上次选的编码 CLI。
///
/// 键不按项目分组：用户对"谁来写代码"的偏好与具体仓库无关，按项目分组
/// 只会让每个仓库都要重新选一遍。
const String kCodeTaskProviderKey = 'code_task_provider';

/// 上次选的模型档位（`fast` / `strong`）。空表示"每次都按任务形态判"。
const String kCodeTaskTierKey = 'code_task_model_tier';

/// 一次"上次怎么选的"快照。两个字段都可能为空 = 交给服务端路由。
class CodeTaskChoice {
  const CodeTaskChoice({this.provider, this.modelTier});

  final String? provider;
  final String? modelTier;
}

class CodeTaskPrefs {
  const CodeTaskPrefs(this._store);

  final SecretStore _store;

  /// 读上次选择。
  ///
  /// 读不出来（钥匙串不可用、headless、脏值）一律当"没选过"处理：偏好是可选
  /// 增强，不该因为读不到就挡住派单，也不该把脏值当成一次真实的点名。
  Future<CodeTaskChoice> read() async {
    try {
      final provider = _clean(await _store.read(kCodeTaskProviderKey));
      final tier = _clean(await _store.read(kCodeTaskTierKey));
      return CodeTaskChoice(
        provider: provider,
        modelTier: tier == 'fast' || tier == 'strong' ? tier : null,
      );
    } on Exception {
      return const CodeTaskChoice();
    }
  }

  /// 记住所选 CLI。传 `null` 表示用户这次选了「自动」，要把旧值清掉——
  /// 留着旧值会让下次打开弹窗回填一个用户已经放弃的选择。
  Future<void> saveProvider(String? provider) =>
      _writeOrClear(kCodeTaskProviderKey, provider);

  Future<void> saveModelTier(String? tier) =>
      _writeOrClear(kCodeTaskTierKey, tier);

  Future<void> _writeOrClear(String key, String? value) async {
    try {
      final clean = _clean(value);
      if (clean == null) {
        await _store.delete(key);
      } else {
        await _store.write(key, clean);
      }
    } on Exception {
      // 落盘失败只影响"下次还记不记得"，本次派单已经带着选择出去了。
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

final Provider<CodeTaskPrefs> codeTaskPrefsProvider = Provider<CodeTaskPrefs>(
  (ref) => CodeTaskPrefs(ref.watch(secretStoreProvider)),
);
