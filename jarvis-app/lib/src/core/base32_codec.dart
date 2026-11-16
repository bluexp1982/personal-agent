import 'dart:typed_data';

/// RFC 4648 base32，无 padding、编码大写、解码大小写不敏感。
///
/// 服务端用 `base32` crate 的 `Alphabet::Rfc4648 { padding: false }`，两端必须一致：
/// 公钥、挑战、签名全部走这一套编码，差一个字符就验签失败。
const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

// 反查表：0-127 之外一律视为非法字符。
final Uint8List _reverse = _buildReverse();

Uint8List _buildReverse() {
  final table = Uint8List(128);
  for (var i = 0; i < table.length; i++) {
    table[i] = 0xFF;
  }
  for (var i = 0; i < _alphabet.length; i++) {
    final code = _alphabet.codeUnitAt(i);
    table[code] = i;
    if (code >= 65 && code <= 90) {
      // 小写映射到大写
      table[code + 32] = i;
    }
  }
  return table;
}

/// 编码。输入任意字节，输出不含 `=` 的字符串。
String base32Encode(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;

  for (final byte in bytes) {
    buffer = (buffer << 8) | (byte & 0xFF);
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_alphabet[(buffer >> bits) & 0x1F]);
    }
  }

  if (bits > 0) {
    out.write(_alphabet[(buffer << (5 - bits)) & 0x1F]);
  }
  return out.toString();
}

/// 解码。遇到非法字符或长度不合法时抛 [FormatException]。
Uint8List base32Decode(String input) {
  final trimmed = input.trim();
  final out = <int>[];
  var buffer = 0;
  var bits = 0;

  for (final code in trimmed.codeUnits) {
    if (code >= _reverse.length || _reverse[code] == 0xFF) {
      throw FormatException('非法 base32 字符: ${String.fromCharCode(code)}');
    }
    buffer = (buffer << 5) | _reverse[code];
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
    }
  }

  return Uint8List.fromList(out);
}
