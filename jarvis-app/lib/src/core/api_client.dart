import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'models.dart';
import 'tls_pinning.dart';

/// `/api/*` 客户端：统一鉴权头、错误体解析与 SSE 事件流。
///
/// v1 走直连 HTTP；v1.1 接 DataChannel 时替换传输层即可，方法签名不变。
class ApiClient {
  ApiClient({required String baseUrl, this.token, http.Client? httpClient})
    : _baseUrl = _normalize(baseUrl),
      _http = httpClient ?? http.Client();

  final String _baseUrl;
  final String? token;
  final http.Client _http;

  String get baseUrl => _baseUrl;

  static String _normalize(String value) {
    final trimmed = value.trim();
    final withoutSlash = trimmed.replaceFirst(RegExp(r'/+$'), '');
    if (withoutSlash.startsWith('http://') ||
        withoutSlash.startsWith('https://')) {
      return withoutSlash;
    }
    return 'http://$withoutSlash';
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final parsed = Uri.parse('$_baseUrl$path');
    if (query == null || query.isEmpty) {
      return parsed;
    }
    return parsed.replace(queryParameters: query);
  }

  Map<String, String> _headers({bool json = true}) {
    return <String, String>{
      if (json) 'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.get(_uri(path, query), headers: _headers(json: false)),
    );
    return _decodeJson(response);
  }

  /// 读取 JSON 数组响应（如 `/api/skills`）。非数组时返回空列表。
  Future<List<Map<String, dynamic>>> getJsonArray(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.get(_uri(path, query), headers: _headers(json: false)),
    );
    if (response.statusCode >= 300) {
      throw ApiException.fromResponse(response.statusCode, response.body);
    }
    final body = response.body.trim();
    if (body.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    throw ApiException(
      code: 'internal_error',
      message: '响应不是 JSON 数组',
      retryable: false,
      hint: '服务返回了预期之外的数据',
      statusCode: response.statusCode,
    );
  }

  /// 编码 CLI 的能力清单。客户端启动时拉一次，之后按它决定入口是否显示。
  Future<CodeProvidersView> codeProviders() async {
    final json = await getJson('/api/code/providers');
    return CodeProvidersView.fromJson(json);
  }

  /// 已安装的技能包（含每个包提供的技能与支持状态）。
  Future<PluginPage> listPlugins() async {
    final json = await getJson('/api/plugins');
    return PluginPage.fromJson(json);
  }

  /// 安装一个 zip 技能包。
  ///
  /// 走二进制 body 而不是 multipart：与录音分段同一套上传方式，
  /// 少一层边界解析，也少一个"表单字段名拼错"的失败面。
  Future<PluginPage> installPlugin(List<int> bytes) async {
    final json = await postBytes(
      '/api/plugins',
      bytes,
      contentType: 'application/zip',
    );
    return PluginPage.fromJson(json);
  }

  /// 启用或停用插件。停用后其技能立即从新建任务下拉里消失。
  Future<PluginPage> setPluginEnabled(String id, bool enabled) async {
    final json = await patchJson('/api/plugins/$id', <String, dynamic>{
      'enabled': enabled,
    });
    return PluginPage.fromJson(json);
  }

  /// 卸载插件。
  Future<void> deletePlugin(String id) => delete('/api/plugins/$id');

  /// 已安装的主题包（含稀疏颜色覆盖）。
  Future<ThemePage> listThemes() async {
    final json = await getJson('/api/themes');
    return ThemePage.fromJson(json);
  }

  /// 安装一个 zip 主题包。同 id 即覆盖安装，返回最新列表。
  Future<ThemePage> installTheme(List<int> bytes) async {
    final json = await postBytes(
      '/api/themes',
      bytes,
      contentType: 'application/zip',
    );
    return ThemePage.fromJson(json);
  }

  /// 删除主题包，返回最新列表（客户端不必自己合并）。
  Future<ThemePage> deleteTheme(String id) async {
    final json = await deleteJson('/api/themes/$id');
    return ThemePage.fromJson(json);
  }

  /// 全部模型配置与当前生效项。
  Future<ModelListView> listModels() async {
    final json = await getJson('/api/models');
    return ModelListView.fromJson(json);
  }

  /// 新建一份模型配置。密钥只随请求上行，之后任何响应都不会回传它。
  Future<ModelProfileView> createModel({
    required String name,
    required String baseUrl,
    required String model,
    required String apiPath,
    String modelName = '',
    String? apiKey,
    bool vision = false,
    bool reasoning = false,
    int? contextWindow,
  }) async {
    final json = await postJson('/api/models', <String, dynamic>{
      'name': name,
      'base_url': baseUrl,
      'api_path': apiPath,
      'model': model,
      'model_name': modelName,
      'vision': vision,
      'reasoning': reasoning,
      'context_window': ?contextWindow,
      if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
    });
    return _modelOf(json);
  }

  /// 修改一份模型配置。`apiKey` 留空表示不改动已有密钥。
  Future<ModelProfileView> updateModel(
    String id, {
    String? name,
    String? baseUrl,
    String? model,
    String? modelName,
    String? apiPath,
    String? apiKey,
    bool? vision,
    bool? reasoning,
    int? contextWindow,
    bool? enabled,
    bool clearApiKey = false,
  }) async {
    // 只把真正给了值的字段放进去：`null` 与"不改"是两件事，服务端的
    // PATCH 语义也一样（缺省即不改动，空串才表示清空密钥）。
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (baseUrl != null) body['base_url'] = baseUrl;
    if (model != null) body['model'] = model;
    if (modelName != null) body['model_name'] = modelName;
    if (apiPath != null) body['api_path'] = apiPath;
    if (apiKey != null && apiKey.isNotEmpty) body['api_key'] = apiKey;
    if (vision != null) body['vision'] = vision;
    if (reasoning != null) body['reasoning'] = reasoning;
    if (contextWindow != null) body['context_window'] = contextWindow;
    if (enabled != null) body['enabled'] = enabled;
    if (clearApiKey) body['clear_api_key'] = true;

    final json = await patchJson('/api/models/$id', body);
    return _modelOf(json);
  }

  /// 删除一份配置。删的是当前生效项时服务端会自动回落到默认档。
  Future<void> deleteModel(String id) => delete('/api/models/$id');

  /// 设为当前生效模型，返回切换后的视图（含 `available` 与不可用原因）。
  Future<ModelProfileView> activateModel(String id) async {
    final json = await postJson('/api/models/$id/activate', null);
    return _modelOf(json);
  }

  /// 测试连通性。失败也返回结果对象，不抛异常。
  Future<ModelTestResult> testModel({
    String? id,
    String? baseUrl,
    String? model,
    String? apiPath,
    String? apiKey,
    bool reasoning = false,
  }) async {
    final json = await postJson('/api/models/test', <String, dynamic>{
      if (id != null && id.isNotEmpty) 'id': id,
      if (baseUrl != null && baseUrl.isNotEmpty) 'base_url': baseUrl,
      if (model != null && model.isNotEmpty) 'model': model,
      if (apiPath != null && apiPath.isNotEmpty) 'api_path': apiPath,
      if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
      // 探测要按眼前的表单发请求：勾了能力位才会带 `reasoning_effort: none`。
      'reasoning': reasoning,
    });
    return ModelTestResult.fromJson(json);
  }

  /// 这些接口的 `model` 字段在三种响应里位置一致，取不到时给一个空视图兜底。
  ModelProfileView _modelOf(Map<String, dynamic> json) {
    final model = json['model'];
    if (model is Map<String, dynamic>) {
      return ModelProfileView.fromJson(model);
    }
    return const ModelProfileView(
      id: '',
      name: '',
      builtin: false,
      active: false,
      enabled: false,
      baseUrl: '',
      apiPath: '',
      model: '',
      vision: false,
      reasoning: false,
      available: false,
    );
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.post(
        _uri(path, query),
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decodeJson(response);
  }

  /// 把一枚会话产物另存进它所属项目的 `artifacts/` 目录。
  ///
  /// 只传文件名：落点、归属项目、越界检查都在服务端定，客户端无法指定路径。
  /// 返回项目内相对路径与字节数（失败时抛 [ApiException]，重名是 409）。
  Future<({String path, int bytes})> saveMediaToProject(
    String mediaId,
    String name,
  ) async {
    final json = await postJson(
      '/api/media/${Uri.encodeComponent(mediaId)}/save',
      <String, dynamic>{'name': name},
    );
    return (
      path: json['path'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// 部分更新（如重命名项目），返回更新后的对象。
  Future<Map<String, dynamic>> patchJson(
    String path,
    Object? body, {
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.patch(
        _uri(path, query),
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decodeJson(response);
  }

  /// 删除资源（会话、任务）。成功时服务端返回 204，没有响应体。
  ///
  /// 非 2xx 仍按统一错误体解析，调用方据 `userMessage` 给出提示。
  Future<void> delete(String path) async {
    final response = await _send(
      () => _http.delete(_uri(path), headers: _headers(json: false)),
    );
    _decodeJson(response);
  }

  /// 删除资源并读回响应体。
  ///
  /// 主题包删除后直接回最新列表，客户端拿到就能整份替换，不必再拉一次。
  Future<Map<String, dynamic>> deleteJson(String path) async {
    final response = await _send(
      () => _http.delete(_uri(path), headers: _headers(json: false)),
    );
    return _decodeJson(response);
  }

  /// 读取原始字节（产物下载 / 图片 / PDF）。
  ///
  /// 不走 JSON 解码：产物是文件，多一层编码只会让「另存为」写出损坏内容。
  /// 非 2xx 时响应体其实是统一错误体，仍按错误体解析以复用提示。
  ///
  /// 返回 `Uint8List` 而不是 `List<int>`：`bodyBytes` 本来就是它，
  /// 调用方要交给 `Image.memory` / pdfrx 时不必再整份复制一次——
  /// 一张 64 MB 的图多复制一遍就是实打实的两倍内存。
  Future<({Uint8List bytes, String? contentType})> getBytes(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.get(_uri(path, query), headers: _headers(json: false)),
    );
    if (response.statusCode >= 300) {
      throw ApiException.fromResponse(response.statusCode, response.body);
    }
    return (
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  /// 流式下载到本地文件（视频查看器用）。
  ///
  /// 与 [getBytes] 的分工：那个把整片字节交给内存里的渲染器（图片 / PDF），
  /// 这个交给播放器——几十 MB 的视频留在内存里没有意义，而且拖动进度
  /// 需要一个可随机读取的本地文件（服务端字节端点不支持 Range）。
  ///
  /// `target` 已存在且非空时直接复用：同一段视频反复点开不该重复下载。
  /// 先写 `<target>.part` 再改名：中途失败不会留下一个"能打开、播到一半断掉"
  /// 的文件，下次也就会重新下载而不是复用残缺字节。
  Future<File> downloadToFile(
    String path, {
    required File target,
    Map<String, String>? query,
  }) async {
    if (await target.exists() && await target.length() > 0) {
      return target;
    }
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');

    final http.StreamedResponse response;
    try {
      final request = http.Request('GET', _uri(path, query))
        ..headers.addAll(_headers(json: false));
      response = await _http.send(request);
    } catch (error) {
      throw _translate(error);
    }

    if (response.statusCode >= 300) {
      // 错误体是统一 JSON，读出来交给同一套解析，客户端只需处理一种错误形状。
      final text = await response.stream.bytesToString();
      throw ApiException.fromResponse(response.statusCode, text);
    }

    final sink = part.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
      }
      await sink.close();
      await part.rename(target.path);
      return target;
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {
        // 已经关了或关不掉都无所谓：下面会连文件一起删。
      }
      await _deleteQuietly(part);
      throw error is ApiException ? error : _translate(error);
    }
  }

  /// 删除临时文件；目标本就不在时视为成功。
  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 清理失败不该盖住真正要抛的错误。
    }
  }

  /// 发送原始字节（录音分段）。响应仍是统一 JSON。
  ///
  /// 不用 multipart：WAV 本身就是二进制，多一层边界只会让请求体变大；
  /// 端点用 `audio/wav` 声明类型，服务端按 `Bytes` 直接收。
  Future<Map<String, dynamic>> postBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    Map<String, String>? query,
  }) async {
    final response = await _send(
      () => _http.post(
        _uri(path, query),
        headers: <String, String>{
          ..._headers(json: false),
          'content-type': contentType,
        },
        body: bytes,
      ),
    );
    return _decodeJson(response);
  }

  /// 发送 POST 并读取 SSE 事件流。
  ///
  /// 每个事件是服务端 `StreamEvent` 的 JSON（`{ "type": ... }`）。
  Stream<Map<String, dynamic>> postSse(String path, Object? body) async* {
    final request = http.Request('POST', _uri(path))
      ..headers.addAll(_headers())
      ..body = body == null ? '' : jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (error) {
      throw _translate(error);
    }

    if (response.statusCode >= 300) {
      final text = await response.stream.bytesToString();
      throw ApiException.fromResponse(response.statusCode, text);
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    yield* decodeSse(lines);
  }

  void close() => _http.close();

  Future<http.Response> _send(Future<http.Response> Function() action) async {
    try {
      return await action();
    } catch (error) {
      throw _translate(error);
    }
  }

  /// 把传输层错误翻译成统一错误体。
  ///
  /// TLS 失败不能报成"网络不通"：用户据此会去查端口和进程，而真正要做的是
  /// 核对服务端证书指纹。两者是完全不同的处置动作。
  ApiException _translate(Object error) {
    if (isTlsFailure(error)) {
      return ApiException.tlsPinning();
    }
    return ApiException.network(error, baseUrl: _baseUrl);
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    if (response.statusCode >= 300) {
      throw ApiException.fromResponse(response.statusCode, response.body);
    }
    final body = response.body.trim();
    if (body.isEmpty) {
      return <String, dynamic>{};
    }

    final value = jsonDecode(body);
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw ApiException(
      code: 'internal_error',
      message: '响应不是 JSON 对象',
      retryable: false,
      hint: '服务返回了预期之外的数据',
      statusCode: response.statusCode,
    );
  }
}

/// 把 SSE 文本行解析成事件。
///
/// 规则：空行分隔事件，`data:` 行拼接负载，其余字段（`event:` / `id:` / 注释）忽略。
/// 独立成函数是为了能单测——网络路径不好测，解析逻辑必须单独可测。
Stream<Map<String, dynamic>> decodeSse(Stream<String> lines) async* {
  final buffer = StringBuffer();

  await for (final line in lines) {
    if (line.isEmpty) {
      final payload = buffer.toString();
      buffer.clear();
      if (payload.isEmpty) {
        continue;
      }
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        yield decoded;
      }
      continue;
    }

    if (line.startsWith(':')) {
      // 注释行（keep-alive）
      continue;
    }
    if (line.startsWith('data:')) {
      buffer.write(line.substring(5).trimLeft());
    }
  }

  if (buffer.isNotEmpty) {
    final decoded = jsonDecode(buffer.toString());
    if (decoded is Map<String, dynamic>) {
      yield decoded;
    }
  }
}
