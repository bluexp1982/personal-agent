import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'design/app_theme_spec.dart';
import 'models.dart';
import 'session.dart';
import 'theme_mode.dart';

/// 服务端已安装的主题包列表。
///
/// 只在拿到登录态客户端后拉取；未配对时返回空列表，设置页显示空态。
/// 安装/删除都把服务端回的最新列表整份替换进来——服务端是唯一真源，
/// 客户端自己 merge 迟早会和"同 id 覆盖安装"打架。
final AsyncNotifierProvider<ThemePacksController, ThemePage>
themePacksProvider = AsyncNotifierProvider<ThemePacksController, ThemePage>(
  ThemePacksController.new,
);

class ThemePacksController extends AsyncNotifier<ThemePage> {
  @override
  Future<ThemePage> build() async {
    final client = ref.watch(apiClientProvider);
    if (client == null) {
      return ThemePage.empty;
    }
    return client.listThemes();
  }

  /// 重新拉取。失败时保留旧数据（`AsyncValue` 会带着上次的值），
  /// 界面照常可用，只在设置页给一条"刷新失败"。
  Future<void> reload() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      state = const AsyncData<ThemePage>(ThemePage.empty);
      return;
    }
    state = await AsyncValue.guard(client.listThemes);
  }

  /// 安装（或覆盖安装）一个主题包。异常直接抛给调用方——
  /// 这是用户主动操作，必须看到失败原因。
  Future<ThemePage> install(List<int> bytes) async {
    final client = _requireClient();
    final page = await client.installTheme(bytes);
    state = AsyncData<ThemePage>(page);
    return page;
  }

  /// 删除主题包。
  Future<ThemePage> remove(String id) async {
    final client = _requireClient();
    final page = await client.deleteTheme(id);
    state = AsyncData<ThemePage>(page);
    return page;
  }

  ApiClient _requireClient() {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      throw StateError('未连接服务端：先完成配对再管理主题包');
    }
    return client;
  }
}

/// 当前生效的主题包。
///
/// 取"服务端列表里的那一份"优先，其次回落到本地缓存：
/// - 列表里有这个 id → 用服务端版本（重装同名主题后色值立即跟着变）；
/// - 列表还在加载、服务端不可达、或被别的设备删掉了 → 用缓存。
///   后两种情况宁可继续着色也不要突然换脸：设置页会把它标成「已失效」，
///   用户点删除时才真正回落到内置主题。
/// - 连缓存都没有（首次选包失败 / 清理过数据）→ null，界面用内置主题。
final Provider<AppThemeSpec?> activeThemeSpecProvider =
    Provider<AppThemeSpec?>((ref) {
      final selection = ref.watch(themeSelectionProvider);
      if (!selection.isCustom) {
        return null;
      }

      final page = ref.watch(themePacksProvider).asData?.value;
      return page?.byId(selection.themeId) ?? selection.spec;
    });
