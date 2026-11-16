import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'session.dart';

/// 编码 CLI 的能力清单缓存。
///
/// 拉一次就够：能力来自服务端配置与已安装的 CLI，任务进行中不会变。
/// 失败时返回空清单并保留错误——调用方按"拿不到就不显示高级入口"处理，
/// 不要因为一个可选接口把编码任务整体挡住。
final FutureProvider<CodeProvidersView> codeProvidersProvider =
    FutureProvider<CodeProvidersView>((ref) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw StateError('未连接服务端');
      }
      return client.codeProviders();
    });

/// 打开"选执行方式"之前真正取一次能力清单，失败返回 null。
///
/// 不能直接读 `.value`：这个 provider 没有预热的地方，首次读到的永远是
/// `AsyncLoading`，于是"第一次打开弹窗没有选择器、第二次才有"——看起来就像
/// 选择器时灵时不灵。失败只降级为"不显示高级入口"，不挡住派单。
Future<CodeProvidersView?> readCodeProviders(WidgetRef ref) async {
  try {
    return await ref.read(codeProvidersProvider.future);
  } catch (_) {
    return null;
  }
}
