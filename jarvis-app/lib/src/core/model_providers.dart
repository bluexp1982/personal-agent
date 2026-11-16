import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'session.dart';

/// 全部模型配置与当前生效项。
///
/// 设置页的模型卡片自己拉一份用于编辑，这个 provider 面向**只读的展示方**：
/// 新会话空态要知道"现在用的是哪个模型"，但它不该因为设置页里的一次改动
/// 就重新请求——所以改完模型配置后由改动方 [invalidateModels] 主动失效。
final modelProfilesProvider = FutureProvider<ModelListView>((ref) async {
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return ModelListView.empty;
  }
  return client.listModels();
});

/// 当前生效的配置；还没拉到或是空列表时为 null。
///
/// 单独抽一层是为了让"只想显示一个模型名"的地方不必关心 `AsyncValue`：
/// 失败与加载中都当作"暂时不知道"，不打断页面。
final activeModelProvider = Provider<ModelProfileView?>((ref) {
  return ref.watch(modelProfilesProvider).value?.active;
});

/// 模型配置变了：让所有只读展示方重新拉一次。
///
/// 只接受 `WidgetRef`：调用它的都是"改完之后通知外界"的界面代码，
/// provider 内部没有需要通知自己的场景。
void invalidateModels(WidgetRef ref) {
  ref.invalidate(modelProfilesProvider);
}
