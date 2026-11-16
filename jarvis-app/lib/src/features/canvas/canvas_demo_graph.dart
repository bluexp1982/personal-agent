import 'package:flutter/material.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import 'canvas_node_data.dart';

/// 一棵现搭的演示图：节点列表 + 连线列表。
///
/// 单独抽出来是为了让页面只管"怎么摆"、不管"图里有什么"：以后要换成真实
/// 业务画布，替换的正是这个文件，页面与控制条都不用动。
class CanvasDemoGraph {
  const CanvasDemoGraph({required this.nodes, required this.connections});

  final List<Node<CanvasNodeData?>> nodes;
  final List<Connection<dynamic>> connections;
}

/// 构造演示图。
///
/// 分组框与便签的底色由调用方传入：`GroupNode` / `CommentNode` 的构造要一个
/// `Color`，而颜色只能从 `AppPalette` 取（本文件拿不到 `BuildContext`）。
///
/// 节点的 `T` 是可空的 `CanvasNodeData?`：分组与便签本身不携带业务数据，
/// 但它们同样要经过 `nodeBuilder`，让 `T` 非空就得给它们塞一个假数据对象。
CanvasDemoGraph buildCanvasDemoGraph({
  required Color groupColor,
  required Color noteColor,
}) {
  final nodes = <Node<CanvasNodeData?>>[
    // 分组在最底层（库把它放在 background 层），把"采集 → 处理"两枚圈起来。
    GroupNode<CanvasNodeData?>(
      id: 'group-collect',
      position: const Offset(64, 56),
      size: const Size(520, 208),
      title: '采集 → 处理',
      data: null,
      color: groupColor,
      nodeIds: const <String>{'trigger', 'agent'},
    ),
    Node<CanvasNodeData?>(
      id: 'trigger',
      type: 'trigger',
      position: const Offset(100, 120),
      size: const Size(190, 88),
      data: const TriggerNodeData(
        title: '新消息到达',
        subtitle: 'Telegram / 邮件 / 定时',
      ),
      ports: <Port>[
        Port(
          id: 'out',
          name: '事件',
          position: PortPosition.right,
          offset: const Offset(0, 44),
        ),
      ],
    ),
    Node<CanvasNodeData?>(
      id: 'agent',
      type: 'agent',
      position: const Offset(360, 96),
      size: const Size(210, 120),
      data: const AgentNodeData(title: '整理成待办', subtitle: '模型 + 记忆检索'),
      ports: <Port>[
        Port(
          id: 'in',
          name: '输入',
          position: PortPosition.left,
          offset: const Offset(0, 44),
        ),
        Port(
          id: 'context',
          name: '上下文',
          position: PortPosition.left,
          offset: const Offset(0, 88),
        ),
        Port(
          id: 'out',
          name: '结果',
          position: PortPosition.right,
          offset: const Offset(0, 60),
        ),
      ],
    ),
    Node<CanvasNodeData?>(
      id: 'branch',
      type: 'branch',
      position: const Offset(640, 88),
      size: const Size(190, 136),
      data: const BranchNodeData(title: '今天要处理吗', subtitle: '按截止时间判断'),
      ports: <Port>[
        Port(
          id: 'in',
          name: '输入',
          position: PortPosition.left,
          offset: const Offset(0, 68),
        ),
        Port(
          id: 'yes',
          name: '是',
          position: PortPosition.right,
          offset: const Offset(0, 48),
        ),
        // 底边端口：offset.dx 是端口中心在节点内的横坐标。
        Port(
          id: 'no',
          name: '否',
          position: PortPosition.bottom,
          offset: const Offset(128, 0),
        ),
      ],
    ),
    Node<CanvasNodeData?>(
      id: 'push',
      type: 'output',
      position: const Offset(900, 64),
      size: const Size(190, 88),
      data: const OutputNodeData(title: '推一条提醒', subtitle: '手机通知'),
      ports: <Port>[
        Port(
          id: 'in',
          name: '输入',
          position: PortPosition.left,
          offset: const Offset(0, 44),
        ),
      ],
    ),
    Node<CanvasNodeData?>(
      id: 'archive',
      type: 'output',
      position: const Offset(900, 232),
      size: const Size(190, 88),
      data: const OutputNodeData(title: '归档到今天', subtitle: '写进本地笔记'),
      ports: <Port>[
        Port(
          id: 'in',
          name: '输入',
          position: PortPosition.left,
          offset: const Offset(0, 44),
        ),
      ],
    ),
    // 便签在 foreground 层：它压在连线上方也不挡操作。
    CommentNode<CanvasNodeData?>(
      id: 'note',
      position: const Offset(640, 320),
      width: 330,
      height: 120,
      text:
          '这是一张演示画布：拖动节点、从端口拉线、框选多选、按 Delete 删除，'
          '右上角控制条切换连线样式与动效。所有内容只在内存里，重启即恢复初始图。',
      data: null,
      color: noteColor,
    ),
  ];

  final connections = <Connection<dynamic>>[
    Connection(
      id: 'c-trigger-agent',
      sourceNodeId: 'trigger',
      sourcePortId: 'out',
      targetNodeId: 'agent',
      targetPortId: 'in',
    ),
    Connection(
      id: 'c-agent-branch',
      sourceNodeId: 'agent',
      sourcePortId: 'out',
      targetNodeId: 'branch',
      targetPortId: 'in',
    ),
    Connection(
      id: 'c-branch-yes',
      sourceNodeId: 'branch',
      sourcePortId: 'yes',
      targetNodeId: 'push',
      targetPortId: 'in',
      label: ConnectionLabel(text: '通过'),
    ),
    Connection(
      id: 'c-branch-no',
      sourceNodeId: 'branch',
      sourcePortId: 'no',
      targetNodeId: 'archive',
      targetPortId: 'in',
      label: ConnectionLabel(text: '需重试'),
    ),
  ];

  return CanvasDemoGraph(nodes: nodes, connections: connections);
}
