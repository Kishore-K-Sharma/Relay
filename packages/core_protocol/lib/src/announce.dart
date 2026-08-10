import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

/// Who this device is, broadcast in the clear.
///
/// Plaintext by necessity: a stranger cannot discover us if they cannot read
/// it. It carries no secret — a nickname and two public keys — but it is the
/// only unencrypted thing this app transmits, so what goes in it is a decision
/// rather than a convenience.
///
/// The layout is deliberately parsed by *length* rather than by "the rest of
/// the payload", so a build that has learned a new field stays readable by one
/// that has not. That property is load-bearing: a device that cannot parse an
/// announce cannot see the person sending it, and there is no second channel
/// to fall back to.
///
/// ```
/// [0]              nickname length in bytes
/// [1 .. 1+n]       nickname, UTF-8
/// [1+n .. +32]     Ed25519 identity public key
/// [1+n+32 .. +32]  X25519 Noise static public key   (optional)
/// ```
@immutable
class Announce {
  Announce({
    required String nickname,
    required this.identityKey,
    this.noiseStaticKey,
  }) : nickname = _truncateUtf8(nickname, maxNicknameBytes);

  /// Length of both keys. Ed25519 and X25519 public keys are both 32 bytes,
  /// which is why the second one has to be positional rather than inferred.
  static const int keyLength = 32;

  /// Long enough for a name in any script, short enough that an announce still
  /// fits one frame with room to grow.
  static const int maxNicknameBytes = 32;

  /// Already truncated to [maxNicknameBytes] by the constructor.
  final String nickname;

  /// What a contact pins, and what a safety code is computed over.
  final Uint8List identityKey;

  /// What mail is sealed to when this person is out of reach.
  ///
  /// Null when the sender is a build that predates couriers, or chose not to
  /// publish it. Absent means "cannot be couriered to", never "use the
  /// identity key instead": reusing one key for signing and Diffie-Hellman
  /// weakens both.
  final Uint8List? noiseStaticKey;

  Uint8List encode() {
    final name = utf8.encode(nickname);
    final noise = noiseStaticKey;

    final out = BytesBuilder(copy: false)
      ..addByte(name.length)
      ..add(name)
      ..add(identityKey);
    if (noise != null && noise.length == keyLength) out.add(noise);

    return out.takeBytes();
  }

  /// Reads an announce back, or null if it is not one.
  ///
  /// Returns null rather than throwing. Malformed announces are ordinary in a
  /// crowd — another app, an older build, a corrupted write — and an exception
  /// on the inbound path would silence the device.
  static Announce? decode(Uint8List payload) {
    if (payload.isEmpty) return null;

    final nameLength = payload[0];
    final keyStart = 1 + nameLength;
    if (payload.length < keyStart + keyLength) return null;

    final noiseStart = keyStart + keyLength;
    final hasNoise = payload.length >= noiseStart + keyLength;

    return Announce(
      nickname: utf8.decode(
        Uint8List.sublistView(payload, 1, keyStart),
        allowMalformed: true,
      ),
      identityKey: Uint8List.sublistView(payload, keyStart, noiseStart),
      // Half a key is not a key. Better to see somebody and be unable to
      // courier to them than to seal mail to something that cannot open it.
      noiseStaticKey: hasNoise
          ? Uint8List.sublistView(payload, noiseStart, noiseStart + keyLength)
          : null,
    );
  }

  /// Drops whole characters until the UTF-8 encoding fits [maxBytes].
  ///
  /// Cutting the byte array instead would put a replacement glyph in
  /// somebody's name on every device in range.
  static String _truncateUtf8(String value, int maxBytes) {
    var candidate = value;
    while (utf8.encode(candidate).length > maxBytes) {
      candidate = candidate.characters.skipLast(1).toString();
    }
    return candidate;
  }
}
