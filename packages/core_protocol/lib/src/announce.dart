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
/// [1+n+64 .. +64]  Ed25519 signature over everything above   (optional)
/// ```
///
/// At the maximum nickname length that is 161 bytes, against a 165-byte
/// payload budget. A seventh field does not fit; adding one means fragmenting
/// the announce, and a fragmented announce is one a device can half-hear.
///
/// The signature is checked by whoever consumes this, not here — verifying it
/// needs Ed25519, and this package is deliberately free of a crypto
/// dependency so it stays a pure description of the wire. See
/// [signedRegionOf], which returns the exact bytes a signature covers.
@immutable
class Announce {
  Announce({
    required String nickname,
    required this.identityKey,
    this.noiseStaticKey,
    this.signature,
  }) : nickname = _truncateUtf8(nickname, maxNicknameBytes);

  /// Length of both keys. Ed25519 and X25519 public keys are both 32 bytes,
  /// which is why the second one has to be positional rather than inferred.
  static const int keyLength = 32;

  /// Length of an Ed25519 signature.
  static const int signatureLength = 64;

  /// Domain separator prepended before signing, so an announce signature can
  /// never be replayed as a signature this app makes over anything else.
  ///
  /// Frozen, and superseded rather than edited — see the note on the other
  /// separators in `brand/README.md`.
  static const String signatureContext = 'relay-announce-v1';

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

  /// Ed25519 signature by [identityKey] over [signatureContext] followed by
  /// every preceding byte of the payload.
  ///
  /// Null when the sender did not sign. That is not the same as invalid: an
  /// unsigned announce is readable and its *presence* is usable, but nothing
  /// it claims is attributable, so a consumer must not act on the keys in it.
  /// Verifying is the consumer's job; see [signedRegionOf].
  final Uint8List? signature;

  /// The same announce carrying [signature].
  ///
  /// Separate from the constructor because signing needs the encoded form,
  /// which needs the truncated nickname, which the constructor produces. Going
  /// back through the constructor with the already-truncated name is
  /// idempotent, and keeps one definition of what "the nickname" is.
  Announce withSignature(Uint8List signature) => Announce(
    nickname: nickname,
    identityKey: identityKey,
    noiseStaticKey: noiseStaticKey,
    signature: signature,
  );

  /// Everything a signature covers: the payload up to, but not including, the
  /// signature field.
  Uint8List encodeUnsigned() {
    final name = utf8.encode(nickname);
    final noise = noiseStaticKey;

    final out = BytesBuilder(copy: false)
      ..addByte(name.length)
      ..add(name)
      ..add(identityKey);
    if (noise != null && noise.length == keyLength) out.add(noise);

    return out.takeBytes();
  }

  Uint8List encode() {
    final unsigned = encodeUnsigned();
    final sig = signature;

    // The signature sits after the Noise key, so it can only be located by a
    // reader that found one. Signing without publishing a Noise key would put
    // 64 bytes on the wire that every decoder reads as a key plus rubbish.
    if (sig == null ||
        sig.length != signatureLength ||
        noiseStaticKey?.length != keyLength) {
      return unsigned;
    }

    return Uint8List(unsigned.length + signatureLength)
      ..setRange(0, unsigned.length, unsigned)
      ..setRange(unsigned.length, unsigned.length + signatureLength, sig);
  }

  /// The exact bytes an Ed25519 signature is computed over.
  ///
  /// [signatureContext] is prepended so a signature made here can never be
  /// replayed as one this app makes over anything else.
  static Uint8List signingInput(Uint8List unsignedRegion) => Uint8List.fromList(
    <int>[...signatureContext.codeUnits, ...unsignedRegion],
  );

  /// The signed region of a *received* payload, or null when it carries no
  /// signature.
  ///
  /// Read back out of the received bytes rather than re-encoding what was
  /// parsed. A verifier that re-serialises its own parse accepts anything
  /// whose canonical form happens to match, which is a different — and
  /// weaker — statement than "these bytes were signed".
  static Uint8List? signedRegionOf(Uint8List payload) {
    if (payload.isEmpty) return null;

    final noiseStart = 1 + payload[0] + keyLength;
    if (payload.length < noiseStart + keyLength + signatureLength) return null;

    return Uint8List.sublistView(payload, 0, noiseStart + keyLength);
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
    final signatureStart = noiseStart + keyLength;
    // Only locatable behind a Noise key, which is why [encode] refuses to
    // write one without the other.
    final hasSignature =
        hasNoise && payload.length >= signatureStart + signatureLength;

    return Announce(
      nickname: utf8.decode(
        Uint8List.sublistView(payload, 1, keyStart),
        allowMalformed: true,
      ),
      identityKey: Uint8List.sublistView(payload, keyStart, noiseStart),
      // Half a key is not a key. Better to see somebody and be unable to
      // courier to them than to seal mail to something that cannot open it.
      noiseStaticKey: hasNoise
          ? Uint8List.sublistView(payload, noiseStart, signatureStart)
          : null,
      signature: hasSignature
          ? Uint8List.sublistView(
              payload,
              signatureStart,
              signatureStart + signatureLength,
            )
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
