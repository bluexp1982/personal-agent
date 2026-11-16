import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base32_codec.dart';

/// 客户端长期身份：Ed25519 密钥对。
///
/// 私钥只在配对时生成一次，之后用于每次登录的 challenge 签名。
/// 丢失即重新配对——与「配对与信任」的决策一致，不做密钥备份。
class DeviceIdentity {
  DeviceIdentity._(this._keyPair);

  final SimpleKeyPair _keyPair;

  static final Ed25519 _algorithm = Ed25519();

  /// 首次使用时生成。种子长度 32 字节。
  static Future<DeviceIdentity> generate() async {
    return DeviceIdentity._(await _algorithm.newKeyPair());
  }

  /// 从持久化的种子恢复。
  static Future<DeviceIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ed25519 种子必须是 32 字节，实际 ${seed.length}');
    }
    return DeviceIdentity._(await _algorithm.newKeyPairFromSeed(seed));
  }

  /// 导出种子（用于写入本地存储，base32 编码后保存）。
  Future<Uint8List> exportSeed() async {
    return Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());
  }

  /// 公钥的 base32 编码，与服务端 `client_pubkey` 字段一致。
  Future<String> publicKeyBase32() async {
    final publicKey = await _keyPair.extractPublicKey();
    return base32Encode(publicKey.bytes);
  }

  /// 对原始字节签名（不是对 base32 字符串签名）。
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}
