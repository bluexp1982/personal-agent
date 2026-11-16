import 'package:flutter/material.dart';

import 'canvas_demo_page.dart';

/// 无限画布（整页）。
///
/// 只给窄屏用：宽屏左栏的「无限画布」走 `shellTargetProvider` 的
/// `CanvasTarget`，页面在中栏原地切换；窄屏没有中栏可占，才整页推入。
Future<void> openCanvasDemoPage(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const CanvasDemoPage()));
}
