import 'dart:convert';
import 'dart:typed_data';

/// What a pairing QR code carries.
///
/// Deliberately tiny and versioned. A QR code is scanned in bad light by
/// someone in a hurry; the less it holds, the smaller and more forgiving the
/// code, and the version prefix means a future field cannot be misread by an
/// older build as something it is not.
class PairingPayload {
  const PairingPayload({
    required this.identityKey,
    required this.noiseKey,
    required this.nostrKey,
    required this.nickname,
  });

  static const String scheme = 'relay';
  static const int version = 1;

  /// Ed25519 public key. This is what gets pinned.
  final Uint8List identityKey;

  /// X25519 static public key, so the first handshake can be checked against
  /// what was scanned rather than trusted blindly.
  final Uint8List noiseKey;

  /// secp256k1 x-only public key, hex. How this contact is reached over the
  /// internet relay when they are out of Bluetooth range. Empty when the
  /// contact has the relay turned off, which is a legitimate choice.
  final String nostrKey;

  final String nickname;

  /// `relay:1:<identity>:<noise>:<nostr>:<nickname>`, base64url unpadded.
  String encode() => [
    scheme,
    '$version',
    _b64(identityKey),
    _b64(noiseKey),
    nostrKey,
    _b64(Uint8List.fromList(utf8.encode(nickname))),
  ].join(':');

  /// Returns null for anything that is not one of our codes.
  ///
  /// Returning null rather than throwing is deliberate: a camera pointed at the
  /// world sees other people's QR codes constantly, and an exception per frame
  /// is not an error condition.
  static PairingPayload? decode(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 6) return null;
    if (parts[0] != scheme) return null;
    if (int.tryParse(parts[1]) != version) return null;

    try {
      final identity = _unb64(parts[2]);
      final noise = _unb64(parts[3]);
      if (identity.length != 32 || noise.length != 32) return null;

      final nostrKey = parts[4];
      if (nostrKey.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(nostrKey)) {
        return null;
      }

      return PairingPayload(
        identityKey: identity,
        noiseKey: noise,
        nostrKey: nostrKey,
        nickname: utf8.decode(_unb64(parts[5]), allowMalformed: true),
      );
    } on FormatException {
      return null;
    }
  }

  static String _b64(Uint8List bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _unb64(String value) {
    final padded = value.padRight((value.length + 3) & ~3, '=');
    return Uint8List.fromList(base64Url.decode(padded));
  }
}
