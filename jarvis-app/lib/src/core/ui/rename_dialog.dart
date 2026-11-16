import 'package:flutter/material.dart';

/// 「重命名」对话框：会话标题与项目名共用这一份。
///
/// 返回用户确认后的原文（没 trim、没校验），调用方拿到后自行 trim 并交给服务端
/// 判定——会话标题与项目名对长度/空白的规则都在服务端那一套里，不在界面上分叉。
///
/// 输入框的 [TextEditingController] 由对话框自己持有、自己在 `dispose` 里释放。
/// 反面例子是在 `showDialog` 外面 new 一个、`await` 返回后立刻 `dispose()`：
/// `showDialog` 的 future 在**出栈那一刻**就完成，而对话框还要播完退场动画才真正
/// 从树里摘掉，这段时间里输入框仍会触碰那个已经销毁的 controller（真机表现为
/// 回车提交后整窗红屏，断言在 `framework.dart` 的 `_dependents.isEmpty`）。
Future<String?> showRenameDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String initialValue,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        _RenameDialog(title: title, label: label, initialValue: initialValue),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({
    required this.title,
    required this.label,
    required this.initialValue,
  });

  final String title;
  final String label;
  final String initialValue;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 提交：带着原文出栈。
  ///
  /// 回车走这里时，回调栈里还压着 `EditableText` 的 `onSubmitted`（输入法刚上屏
  /// 完，焦点还没落定）。同步 pop 等于在输入法收尾的同一个栈里拆路由，容易把
  /// 元素树拆出半截（真机红屏，断言 `_dependents.isEmpty`）；改成"这一轮回调跑完
  /// 再出栈"，用户感知不到差别，也不会和输入法抢同一帧。
  void _submit() {
    final value = _controller.text;
    Future<void>(() {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(value);
    });
  }

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(onPressed: _cancel, child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
