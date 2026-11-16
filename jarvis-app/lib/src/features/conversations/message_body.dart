/// 组装 `POST /api/conversations/{id}/messages` 的请求体。
///
/// 抽成纯函数只为一件事：加了「推理等级」这个**可选**字段之后，请求形状本身
/// 要能被单测直接断言。内联在 `_send` 里时，验证"没选档位就不带这个键"只能
/// 靠起一整套 SSE 环境。
///
/// `reasoningEffort` 为空串或 null 时，返回的 map 与加这个字段之前逐字相同。
Map<String, Object> chatMessageBody({
  required String content,
  required String clientMessageId,
  List<String> attachments = const <String>[],
  String? reasoningEffort,
}) {
  final effort = reasoningEffort?.trim() ?? '';
  return <String, Object>{
    'content': content,
    'client_msg_id': clientMessageId,
    // 只传 id：文件名、类型、字节数都以服务端登记的那份为准。
    if (attachments.isNotEmpty) 'attachments': attachments,
    // 档位只作用于这一轮，服务端不落库。
    if (effort.isNotEmpty) 'reasoning_effort': effort,
  };
}
