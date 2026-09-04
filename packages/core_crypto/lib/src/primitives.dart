import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// BLAKE2s block size in bytes, per RFC 7693 section 2.1.
///
/// This constant exists because `package:cryptography` reports
/// `Blake2s().blockLengthInBytes == 32`, which is the *digest* size, not the
/// block size. Feeding that to a generic HMAC produces output that is not
/// HMAC-BLAKE2s, and Noise's HKDF is built entirely on HMAC — so the handshake
/// would still complete between two of our own devices while failing every
/// official test vector and quietly losing its security proofs.
const int blake2sBlockLength = 64;

/// BLAKE2s digest size in bytes.
const int blake2sHashLength = 32;

/// Largest nonce value before a cipher state must be retired.
///
/// Noise reserves 2^64-1 as the "exhausted" marker; reaching it means the
/// session must be torn down rather than wrapped around, because nonce reuse
/// under a repeated key destroys confidentiality entirely.
const int maxNonce = 0x7FFFFFFFFFFFFFFF;

/// Thrown when a ciphertext fails authentication.
class DecryptFailure implements Exception {
  const DecryptFailure([this.message = 'authentication failed']);
  final String message;

  @override
  String toString() => 'DecryptFailure: $message';
}

/// Number of bytes an explicitly transmitted nonce occupies on the wire.
const int explicitNonceLength = 8;

/// How far behind the newest message a late arrival may be and still be
/// accepted.
///
/// Wide enough that a mesh detour of several hops does not silently discard a
/// message; narrow enough that the tracking cost is a single 64-bit word per
/// direction per peer.
const int replayWindowSize = 64;

/// Thrown when a message's nonce has been seen before, or is so old that it can
/// no longer be distinguished from one that has.
class ReplayedMessage implements Exception {
  const ReplayedMessage(this.nonce);

  final int nonce;

  @override
  String toString() => 'ReplayedMessage: nonce $nonce was already accepted';
}

/// Thrown when a cipher state has used every nonce available to it.
class NonceExhausted implements Exception {
  const NonceExhausted();

  @override
  String toString() =>
      'NonceExhausted: the session must be rekeyed or torn down';
}

final Blake2s _blake2s = Blake2s();
final Cipher _aead = Chacha20.poly1305Aead();

/// BLAKE2s digest.
Future<Uint8List> blake2s(List<int> input) async =>
    Uint8List.fromList((await _blake2s.hash(input)).bytes);

/// HMAC-BLAKE2s, implemented directly against RFC 2104 with the correct
/// 64-byte block size.
Future<Uint8List> hmacBlake2s(List<int> key, List<int> data) async {
  final block = Uint8List(blake2sBlockLength);

  if (key.length > blake2sBlockLength) {
    block.setRange(0, blake2sHashLength, await blake2s(key));
  } else {
    block.setRange(0, key.length, key);
  }

  final inner = Uint8List(blake2sBlockLength + data.length);
  final outer = Uint8List(blake2sBlockLength + blake2sHashLength);

  for (var i = 0; i < blake2sBlockLength; i++) {
    inner[i] = block[i] ^ 0x36;
    outer[i] = block[i] ^ 0x5C;
  }
  inner.setRange(blake2sBlockLength, inner.length, data);

  outer.setRange(blake2sBlockLength, outer.length, await blake2s(inner));
  return blake2s(outer);
}

/// Noise HKDF producing two outputs. See Noise spec section 4.3.
Future<(Uint8List, Uint8List)> hkdf2(
  List<int> chainingKey,
  List<int> inputKeyMaterial,
) async {
  final temp = await hmacBlake2s(chainingKey, inputKeyMaterial);
  final o1 = await hmacBlake2s(temp, const [0x01]);
  final o2 = await hmacBlake2s(temp, <int>[...o1, 0x02]);
  return (o1, o2);
}

/// Noise HKDF producing three outputs.
Future<(Uint8List, Uint8List, Uint8List)> hkdf3(
  List<int> chainingKey,
  List<int> inputKeyMaterial,
) async {
  final temp = await hmacBlake2s(chainingKey, inputKeyMaterial);
  final o1 = await hmacBlake2s(temp, const [0x01]);
  final o2 = await hmacBlake2s(temp, <int>[...o1, 0x02]);
  final o3 = await hmacBlake2s(temp, <int>[...o2, 0x03]);
  return (o1, o2, o3);
}

/// A one-directional AEAD channel with a strictly increasing nonce.
///
/// Noise mandates a 12-byte ChaCha20-Poly1305 nonce laid out as four zero bytes
/// followed by the counter in **little-endian** order.
class CipherState {
  CipherState(Uint8List key, {int nonce = 0})
    : _key = SecretKey(key),
      _nonce = nonce {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
  }

  final SecretKey _key;
  int _nonce;

  int get nonce => _nonce;

  /// Moves the counter.
  ///
  /// Needed because a mesh cannot rely on an implicit, in-step counter: frames
  /// are lost and reordered routinely, so the sender's nonce travels with the
  /// message and the receiver positions itself before opening it. Callers are
  /// responsible for replay protection — see [NoiseSession.open].
  set nonce(int value) {
    if (value < 0 || value >= maxNonce) {
      throw ArgumentError.value(value, 'nonce', 'outside the usable range');
    }
    _nonce = value;
  }

  Uint8List _nonceBytes() {
    final out = Uint8List(12);
    ByteData.view(out.buffer).setUint64(4, _nonce, Endian.little);
    return out;
  }

  Future<Uint8List> encryptWithAd(
    List<int> associatedData,
    List<int> plaintext,
  ) async {
    if (_nonce >= maxNonce) throw const NonceExhausted();

    final box = await _aead.encrypt(
      plaintext,
      secretKey: _key,
      nonce: _nonceBytes(),
      aad: associatedData,
    );
    _nonce++;

    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypts, advancing the nonce **only on success**.
  ///
  /// A forged or corrupted frame must not desynchronise the session, otherwise
  /// any nearby device could break a conversation by injecting garbage.
  Future<Uint8List> decryptWithAd(
    List<int> associatedData,
    List<int> ciphertext,
  ) async {
    if (_nonce >= maxNonce) throw const NonceExhausted();
    if (ciphertext.length < 16) {
      throw const DecryptFailure(
        'ciphertext shorter than the authentication tag',
      );
    }

    final split = ciphertext.length - 16;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: _nonceBytes(),
      mac: Mac(ciphertext.sublist(split)),
    );

    final List<int> plaintext;
    try {
      plaintext = await _aead.decrypt(
        box,
        secretKey: _key,
        aad: associatedData,
      );
    } on SecretBoxAuthenticationError {
      throw const DecryptFailure();
    }

    _nonce++;
    return Uint8List.fromList(plaintext);
  }

  /// Noise REKEY: replace the key with an encryption of 32 zero bytes under the
  /// maximum nonce, leaving the counter untouched.
  ///
  /// One deliberate deviation from the spec, which says 2^64-1: Dart integers
  /// are signed, so the largest nonce this can express is [maxNonce] and the
  /// rekey uses `maxNonce - 1`. Both sides of a Relay session derive the same
  /// key, so it is self-consistent — but a Noise implementation from anywhere
  /// else will not interoperate past the first rekey. That is tolerable only
  /// because rekeying belongs to the implicit-counter path, which the mesh
  /// does not use; [NoiseSession.seal] and `open` never call this.
  Future<CipherState> rekey() async {
    final scratch = CipherState(
      Uint8List.fromList(await _key.extractBytes()),
      nonce: maxNonce - 1,
    );
    final out = await scratch.encryptWithAd(Uint8List(0), Uint8List(32));
    return CipherState(Uint8List.sublistView(out, 0, 32), nonce: _nonce);
  }
}
