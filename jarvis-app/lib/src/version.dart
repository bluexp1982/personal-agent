/// 对外 HTTP 契约版本，与 `crates/protocol` 的 `API_VERSION` 一致。
///
/// 客户端自身的版本不在这里：那是构建产物的属性，运行时由
/// `core/app_info.dart` 的 `PackageInfo` 读取，源头上只有 `pubspec.yaml`
/// 一处（`scripts/check-versions.py` 仍校验 Cargo / pubspec / openapi 三处）。
const String apiVersion = 'v1';
