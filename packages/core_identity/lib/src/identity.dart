import 'dart:isolate';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:cryptography/cryptography.dart' hide CipherState;

final Ed25519 _ed25519 = Ed25519();

/// A device's long-lived signing identity.
///
/// The private key is held only in memory here; persisting it is the platform
/// keystore's job, so this class stays pure and testable.
class MeshIdentity {
  MeshIdentity._(this._keyPair, this.publicKey);

  static Future<MeshIdentity> generate() async {
    final pair = await _ed25519.newKeyPair();
    return MeshIdentity._(
      pair,
      Uint8List.fromList((await pair.extractPublicKey()).bytes),
    );
  }

  /// Restores an identity from its 32-byte seed.
  static Future<MeshIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
    }
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return MeshIdentity._(
      pair,
      Uint8List.fromList((await pair.extractPublicKey()).bytes),
    );
  }

  final SimpleKeyPair _keyPair;

  /// The Ed25519 public key others pin.
  final Uint8List publicKey;

  Future<Uint8List> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

Future<bool> verifySignature(
  List<int> message,
  Uint8List signature,
  Uint8List publicKey,
) => _ed25519.verify(
  message,
  signature: Signature(
    signature,
    publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
  ),
);

/// Derives the 4-byte routing hash advertised for a session key.
///
/// Zero is reserved for broadcast, so a key hashing to zero is nudged to 1
/// rather than being silently indistinguishable from "everyone".
Future<int> addressHashOf(Uint8List sessionPublicKey) async {
  final digest = await blake2s(<int>[
    ...'relay-addr-v1'.codeUnits,
    ...sessionPublicKey,
  ]);
  final value = ByteData.view(
    Uint8List.fromList(digest).buffer,
  ).getUint32(0, Endian.big);
  return value == 0 ? 1 : value;
}

/// A comparable fingerprint of two identities, for out-of-band verification.
///
/// Rendered as 60 digits in 12 groups of five, the pattern Signal uses. A word
/// list would be friendlier to read aloud in a loud crowd and can be swapped in
/// behind this same interface later; digits avoid shipping and localising a
/// 2048-entry list for now.
class SafetyCode {
  const SafetyCode(this.digits);

  /// Computes the shared code for a pair of identity keys.
  ///
  /// The inputs are sorted so both devices derive the same value without
  /// needing to agree on who is "first".
  static Future<SafetyCode> between(Uint8List a, Uint8List b) async {
    final ordered = _compare(a, b) <= 0 ? [a, b] : [b, a];
    final seed = Uint8List.fromList(<int>[
      ...'relay-safety-v1'.codeUnits,
      ...ordered[0],
      ...ordered[1],
    ]);

    // Off the calling isolate. The stretch below is thousands of hashes chained
    // by `await`, and an awaited chain of already-complete futures drains as
    // one run of the microtask queue — so on the UI isolate it blocks a frame
    // or two rather than yielding between steps. Spawning costs a millisecond
    // and this runs once, when a QR code is scanned.
    final digest = await Isolate.run(() => _stretch(seed));

    // Twelve 16-bit chunks, each printed as five digits. A chunk therefore
    // spans 00000-65535 rather than the full five-digit range: the groups are
    // not uniform over what they look like they cover. That is cosmetic — the
    // code carries 192 bits either way — and it is left alone deliberately.
    // Changing how these digits are rendered changes every safety code already
    // written down, which is indistinguishable from an attack to the person
    // comparing them.
    final view = ByteData.view(Uint8List.fromList(digest).buffer);
    final buffer = StringBuffer();
    for (var i = 0; i < 12; i++) {
      buffer.write(
        view.getUint16(i * 2, Endian.big).toString().padLeft(5, '0'),
      );
    }
    return SafetyCode(buffer.toString());
  }

  /// Iterated hashing, as Signal does, so producing a colliding code costs an
  /// attacker the full work factor rather than a single hash.
  ///
  /// The count is part of the code's definition: changing it changes every
  /// safety code already compared in person, which to the people comparing
  /// them is indistinguishable from an attack.
  static Future<Uint8List> _stretch(Uint8List seed) async {
    var digest = await blake2s(seed);
    for (var i = 0; i < 5200; i++) {
      digest = await blake2s(digest);
    }
    return digest;
  }

  static int _compare(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// 60 decimal digits.
  final String digits;

  /// The same code split into readable groups of five.
  String get formatted => [
    for (var i = 0; i < digits.length; i += 5) digits.substring(i, i + 5),
  ].join(' ');
}
