import 'package:flutter/material.dart';

import '../artifact_naming.dart';

/// 「保存产物」命名框：预填自动名，允许改成手动名。
///
/// 与 [showRenameDialog] 的差别只有两点，但都很关键：
/// 1. 提交是**异步**的（要打服务端 / 弹系统保存框），失败原因必须留在框里，
///    而不是关掉再弹一个 SnackBar 让用户重新输一遍；
/// 2. 名字有本地校验（空、非法字符、超长），不等一次网络往返才告诉用户。
///
/// `onSubmit` 返回 null 表示成功（框自行关闭），返回字符串表示失败原因。
Future<void> showSaveMediaDialog(
  BuildContext context, {
  required String title,
  required String initialName,
  required Future<String?> Function(String name) onSubmit,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SaveMediaDialog(
      title: title,
      initialName: initialName,
      onSubmit: onSubmit,
    ),
  );
}

class _SaveMediaDialog extends StatefulWidget {
  const _SaveMediaDialog({
    required this.title,
    required this.initialName,
    required this.onSubmit,
  });

  final String title;
  final String initialName;
  final Future<String?> Function(String name) onSubmit;

  @override
  State<_SaveMediaDialog> createState() => _SaveMediaDialogState();
}

class _SaveMediaDialogState extends State<_SaveMediaDialog> {
  /// controller 由对话框自己持有并释放：`showDialog` 的 future 在出栈那一刻
  /// 就完成，外面拿到结果立刻 dispose 会让退场动画里的输入框碰到已销毁的 controller。
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    final name = _controller.text.trim();
    final invalid = validateArtifactName(name);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final error = await widget.onSubmit(name);
    if (!mounted) {
      return;
    }
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }

    // 与重命名框同一个理由：回车提交时回调栈里还压着输入法的收尾，
    // 同步 pop 容易把元素树拆出半截；延后一帧出栈，用户感知不到差别。
    Future<void>(() {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '文件名',
                border: const OutlineInputBorder(),
                // 自动名就在框里，规则只说一遍，避免用户以为要自己拼时间戳。
                helperText: '默认按「会话标题_工具名_时间戳」命名，可直接改名',
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}
