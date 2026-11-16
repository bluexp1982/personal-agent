import 'dart:convert';
import 'dart:typed_data';

/// 一张真正的 1×1 RGBA PNG（已用 `file` / `sips` 校验过）。
///
/// 不用运行时 `Picture.toImage` 生成：那条路在 widget 测试里要 `runAsync`，
/// 拿不到真实光栅器时会一直挂着，测试会表现为"pumpAndSettle 不返回"。
final Uint8List testPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AEAAf/'
  'Af8DQm9KAAAAAElFTkSuQmCC',
);
