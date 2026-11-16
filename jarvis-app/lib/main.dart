import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app.dart';
import 'src/core/ui/liquid_glass_nav.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 视频查看器用的是 media_kit（libmpv）：必须在任何 Player 之前初始化一次。
  // 放在这里而不是懒加载，是因为桌面端首次初始化会加载动态库，
  // 等到用户点开视频才做，那一秒的卡顿会被当成"视频打不开"。
  MediaKit.ensureInitialized();

  // 液态玻璃导航（编译期开关，默认关）：预热 shader 只是磁盘→内存 I/O，
  // 关掉时这一步直接跳过，启动路径与之前一致。
  await initLiquidGlassNav();

  // M5：密钥、令牌与连接状态在 ProviderScope 里按需加载，
  // 启动时由 RootGate 决定显示配对页还是主界面。
  runApp(
    wrapLiquidGlassNav(
      child: const ProviderScope(child: JarvisApp()),
    ),
  );
}
