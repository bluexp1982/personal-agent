/// 项目内路径的换算。
///
/// 客户端与服务端可能不在同一个平台（macOS 客户端 + Windows 服务端），
/// 这里不依赖 `dart:io` 也不依赖 `package:path` 的平台上下文：
/// 全程只做字符串处理，分隔符统一成 `/`，大小写只在盘符路径上放宽。
library;

import 'package:flutter/foundation.dart';

/// 一次"从文件树引用某个文件 / 目录"的完整信息。
///
/// 拖拽载荷用它：相对路径在文件树那一侧就算好（那里知道项目根），
/// 输入栏只负责插入芯片，不需要再猜自己属于哪个项目——跨项目拖拽也不会算错。
/// 纯数据，不依赖任何 widget，文件树与输入栏都只依赖 core。
@immutable
class ProjectPathReference {
  const ProjectPathReference({
    required this.name,
    required this.relativePath,
    required this.absolutePath,
    required this.isDir,
  });

  /// 文件 / 目录名，芯片上显示的那一段。
  final String name;

  /// 以文件树项目根为基准的相对路径，也是发送时写进正文的文本。
  final String relativePath;

  /// 服务端绝对路径：芯片的悬停提示用它区分不同项目下的同名文件。
  final String absolutePath;

  final bool isDir;
}

/// 把服务端绝对路径换算成以 [projectRoot] 为根的项目相对路径。
///
/// - 分隔符统一为 `/`（Windows 服务端的 `\` 也能被吃掉）；
/// - [projectRoot] 尾部的分隔符有无都不影响匹配；
/// - Windows 盘符路径（`C:/...`）按大小写不敏感比较，截取仍用原串长度，
///   复制出来的相对路径不会被悄悄改小写；
/// - 根自身、以及不在 [projectRoot] 内的路径一律退化为 [absolutePath]：
///   复制出一个错得离谱的短路径，比给完整路径更难排查。
String projectRelativePath(String absolutePath, String projectRoot) {
  final path = absolutePath.replaceAll('\\', '/');
  if (path.isEmpty) {
    return absolutePath;
  }

  var root = projectRoot.replaceAll('\\', '/');
  // 保留单独一个 `/`：POSIX 根目录的尾部斜杠就是它自己。
  while (root.length > 1 && root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  if (root.isEmpty) {
    // 还没有根信息（列表尚未返回）：给归一化后的完整路径，不猜。
    return path;
  }

  final prefix = root.endsWith('/') ? root : '$root/';
  // 服务端若是 Windows，盘符与目录名的大小写都可能被用户改过；
  // 只看根是不是盘符形式，避免把 macOS 的大小写敏感路径也放宽。
  final windowsRoot = _driveLetter.hasMatch(root);
  final comparablePath = windowsRoot ? path.toLowerCase() : path;
  final comparablePrefix = windowsRoot ? prefix.toLowerCase() : prefix;
  if (!comparablePath.startsWith(comparablePrefix)) {
    return absolutePath;
  }

  var relative = path.substring(prefix.length);
  // 目录路径偶尔带尾斜杠：相对路径不该留着它。
  while (relative.length > 1 && relative.endsWith('/')) {
    relative = relative.substring(0, relative.length - 1);
  }
  if (relative.isEmpty) {
    return absolutePath;
  }
  return relative;
}

final RegExp _driveLetter = RegExp(r'^[a-zA-Z]:/');
