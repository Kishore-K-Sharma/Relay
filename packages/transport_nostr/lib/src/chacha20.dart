import 'dart:typed_data';

/// ChaCha20 exactly as RFC 8439 defines it: a 12-byte nonce and a 32-bit
/// block counter.
///
/// Written out rather than taken from a library because the widely available
/// Dart implementation is the original DJB variant, which splits the state as a
/// 64-bit counter and an 8-byte nonce. NIP-44 specifies the RFC layout, and the
/// two produce completely different keystreams from the same inputs — a
/// mismatch that only shows up as "no Nostr client can read our messages",
/// which is exactly the kind of failure a test against our own code would miss.
class ChaCha20 {
  const ChaCha20._();

  static const int _blockLength = 64;

  /// Encrypts or decrypts [data]; ChaCha20 is its own inverse.
  static Uint8List apply({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List data,
    int counter = 0,
  }) {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
    if (nonce.length != 12) {
      throw ArgumentError.value(nonce.length, 'nonce', 'must be 12 bytes');
    }

    final out = Uint8List(data.length);
    final block = Uint8List(_blockLength);

    for (var offset = 0; offset < data.length; offset += _blockLength) {
      _block(key, nonce, counter + offset ~/ _blockLength, block);
      final end = offset + _blockLength > data.length
          ? data.length
          : offset + _blockLength;
      for (var i = offset; i < end; i++) {
        out[i] = data[i] ^ block[i - offset];
      }
    }
    return out;
  }

  /// Generates one 64-byte keystream block into [out].
  static void _block(
    Uint8List key,
    Uint8List nonce,
    int counter,
    Uint8List out,
  ) {
    final keyWords = Uint32List.view(
      Uint8List.fromList(key).buffer,
    ); // little-endian on every platform Dart targets
    final nonceWords = Uint32List.view(Uint8List.fromList(nonce).buffer);

    final state = Uint32List(16)
      // "expand 32-byte k"
      ..[0] = 0x61707865
      ..[1] = 0x3320646e
      ..[2] = 0x79622d32
      ..[3] = 0x6b206574
      ..setRange(4, 12, keyWords)
      ..[12] = counter & 0xFFFFFFFF
      ..setRange(13, 16, nonceWords);

    final working = Uint32List.fromList(state);

    for (var round = 0; round < 10; round++) {
      _quarterRound(working, 0, 4, 8, 12);
      _quarterRound(working, 1, 5, 9, 13);
      _quarterRound(working, 2, 6, 10, 14);
      _quarterRound(working, 3, 7, 11, 15);
      _quarterRound(working, 0, 5, 10, 15);
      _quarterRound(working, 1, 6, 11, 12);
      _quarterRound(working, 2, 7, 8, 13);
      _quarterRound(working, 3, 4, 9, 14);
    }

    final view = ByteData.view(out.buffer, out.offsetInBytes, _blockLength);
    for (var i = 0; i < 16; i++) {
      view.setUint32(
        i * 4,
        (working[i] + state[i]) & 0xFFFFFFFF,
        Endian.little,
      );
    }
  }

  static void _quarterRound(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = _rotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = _rotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = _rotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = _rotl(s[b] ^ s[c], 7);
  }

  static int _rotl(int value, int bits) =>
      ((value << bits) | (value >>> (32 - bits))) & 0xFFFFFFFF;
}
