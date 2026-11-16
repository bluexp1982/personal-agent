// 配对码的输入归一化。
//
// 只依赖 dart core：Flutter 界面（配对页）与纯 Dart 脚本（tool/smoke_client.dart）
// 都要用同一套规则，放在这里避免两边各写一份。纯 Dart 也意味着 CLI 脚本
// 不需要为了这一个函数把 Flutter 运行时拖进来。

/// 配对码的有效长度：服务端生成 12 位字母数字。
const int kPairingCodeLength = 12;

/// 归一化用户输入的配对码。
///
/// `jarvis-service pair` 打印的是按 4 位分组、便于口头转述的形式
/// （如 `77JJ-VQ3F-2YZK`），粘贴进客户端时会带着连字符。服务端只做
/// trim + 大写后哈希，并不认分隔符，所以分隔符、空白必须在这一层剥掉，
/// 否则同一个码会因为格式差异哈希对不上。
String normalizePairingCode(String input) =>
    input.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();

/// 归一化后是否正好是 12 位字母数字。
bool isValidPairingCode(String input) =>
    normalizePairingCode(input).length == kPairingCodeLength;
