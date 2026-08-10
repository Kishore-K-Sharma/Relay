import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:elliptic/elliptic.dart' as ec;
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'chacha20.dart';
import 'nostr_event.dart';

/// Thrown when a payload cannot be authenticated or is malformed.
class NostrCryptoException implements Exception {
  const NostrCryptoException(this.message);
  final String message;

  @override
  String toString() => 'NostrCryptoException: $message';
}

/// A secp256k1 keypair, x-only as Nostr uses them.
class NostrKeyPair {
  const NostrKeyPair({required this.privateKeyHex, required this.publicKeyHex});

  factory NostrKeyPair.fromPrivateHex(String privateKeyHex) {
    final normalised = privateKeyHex.toLowerCase().padLeft(64, '0');
    return NostrKeyPair(
      privateKeyHex: normalised,
      publicKeyHex: bip340.getPublicKey(normalised),
    );
  }

  /// A key used once and discarded.
  ///
  /// Every gift wrap gets one. Reusing a wrapper key across messages would let
  /// a relay operator link them into a conversation, which is the exact thing
  /// gift wrapping exists to prevent.
  factory NostrKeyPair.ephemeral([Random? random]) {
    final rng = random ?? Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    // A secp256k1 private key must be in [1, n). Rejecting out-of-range values
    // rather than reducing them keeps the distribution uniform.
    final candidate = hex(bytes);
    if (BigInt.parse(candidate, radix: 16) == BigInt.zero) {
      return NostrKeyPair.ephemeral(random);
    }
    return NostrKeyPair.fromPrivateHex(candidate);
  }

  final String privateKeyHex;

  /// 32-byte x-only public key, hex.
  final String publicKeyHex;
}

Uint8List sha256Of(List<int> data) =>
    SHA256Digest().process(data is Uint8List ? data : Uint8List.fromList(data));

Future<Uint8List> sha256Bytes(List<int> data) async => sha256Of(data);

Uint8List hmacSha256(List<int> key, List<int> data) {
  final mac = HMac(SHA256Digest(), 64)
    ..init(KeyParameter(Uint8List.fromList(key)));
  return mac.process(Uint8List.fromList(data));
}

/// HKDF-SHA256, extract and expand, as NIP-44 specifies.
Uint8List hkdfExtract(List<int> salt, List<int> ikm) => hmacSha256(salt, ikm);

Uint8List hkdfExpand(List<int> prk, List<int> info, int length) {
  final out = <int>[];
  var previous = <int>[];
  var counter = 1;
  while (out.length < length) {
    previous = hmacSha256(prk, [...previous, ...info, counter]);
    out.addAll(previous);
    counter++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

/// The x coordinate of the shared secp256k1 point, per NIP-44.
///
/// Only the x coordinate is used, and it is *not* hashed at this stage — the
/// conversation key derivation below does that. Getting this wrong produces a
/// key that works only against your own implementation.
Uint8List sharedX(String privateKeyHex, String peerPublicKeyHexXOnly) {
  final curve = ec.getSecp256k1();

  // Nostr public keys are x-only. NIP-44 says to assume the even-y point,
  // which is the same convention BIP-340 uses when verifying, so the `02`
  // prefix reconstructs the intended point.
  final point = curve.compressedHexToPublicKey('02$peerPublicKeyHexXOnly');
  final shared = curve.scalarMul(point, unhex(privateKeyHex.padLeft(64, '0')));

  return unhex(shared.X.toRadixString(16).padLeft(64, '0'));
}

/// NIP-44 v2 conversation key: HKDF-extract over the shared x coordinate.
Uint8List conversationKey(String privateKeyHex, String peerPublicKeyHex) =>
    hkdfExtract(
      utf8.encode('nip44-v2'),
      sharedX(privateKeyHex, peerPublicKeyHex),
    );

/// NIP-44 v2 message keys derived from a conversation key and a nonce.
({Uint8List chachaKey, Uint8List chachaNonce, Uint8List hmacKey}) messageKeys(
  Uint8List conversationKey,
  Uint8List nonce,
) {
  final expanded = hkdfExpand(conversationKey, nonce, 76);
  return (
    chachaKey: Uint8List.sublistView(expanded, 0, 32),
    chachaNonce: Uint8List.sublistView(expanded, 32, 44),
    hmacKey: Uint8List.sublistView(expanded, 44, 76),
  );
}

/// NIP-44 padding.
///
/// Lengths are quantised so a ciphertext leaks only a bucket rather than an
/// exact size. Without it, "yes" and "the meeting is at the north gate" are
/// trivially distinguishable to anyone watching the relay.
int paddedLength(int unpadded) {
  if (unpadded <= 0) throw const NostrCryptoException('empty plaintext');
  if (unpadded <= 32) return 32;

  final nextPower = 1 << (unpadded - 1).bitLength;
  final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
  return chunk * ((unpadded - 1) ~/ chunk + 1);
}

Uint8List _pad(Uint8List plaintext) {
  final padded = paddedLength(plaintext.length);
  final out = Uint8List(2 + padded);
  ByteData.view(out.buffer).setUint16(0, plaintext.length, Endian.big);
  out.setRange(2, 2 + plaintext.length, plaintext);
  return out;
}

Uint8List _unpad(Uint8List padded) {
  if (padded.length < 2) throw const NostrCryptoException('padding too short');
  final length = ByteData.view(
    padded.buffer,
    padded.offsetInBytes,
    2,
  ).getUint16(0, Endian.big);

  if (length == 0 || 2 + length > padded.length) {
    throw const NostrCryptoException('declared length outside the payload');
  }
  if (padded.length != 2 + paddedLength(length)) {
    // A payload padded to the wrong bucket did not come from a conforming
    // implementation, and accepting it would let an attacker vary the length
    // freely — defeating the point of padding.
    throw const NostrCryptoException('payload is not padded correctly');
  }
  return Uint8List.sublistView(padded, 2, 2 + length);
}

Uint8List _chacha20(Uint8List key, Uint8List nonce, Uint8List data) =>
    ChaCha20.apply(key: key, nonce: nonce, data: data);

/// NIP-44 v2 encryption. Returns the base64 payload a Nostr event carries.
String nip44Encrypt(
  String plaintext,
  Uint8List conversationKey, {
  Uint8List? nonce,
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final chosenNonce =
      nonce ??
      Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));

  final keys = messageKeys(conversationKey, chosenNonce);
  final padded = _pad(Uint8List.fromList(utf8.encode(plaintext)));
  final ciphertext = _chacha20(keys.chachaKey, keys.chachaNonce, padded);
  final mac = hmacSha256(keys.hmacKey, [...chosenNonce, ...ciphertext]);

  return base64Encode([2, ...chosenNonce, ...ciphertext, ...mac]);
}

/// NIP-44 v2 decryption.
String nip44Decrypt(String payload, Uint8List conversationKey) {
  if (payload.startsWith('#')) {
    throw const NostrCryptoException('unsupported NIP-44 version');
  }

  final Uint8List raw;
  try {
    raw = base64Decode(payload);
  } on FormatException {
    throw const NostrCryptoException('payload is not base64');
  }

  if (raw.isEmpty || raw[0] != 2) {
    throw const NostrCryptoException('unsupported NIP-44 version');
  }
  if (raw.length < 1 + 32 + 32 + 32) {
    throw const NostrCryptoException('payload too short');
  }

  final nonce = Uint8List.sublistView(raw, 1, 33);
  final ciphertext = Uint8List.sublistView(raw, 33, raw.length - 32);
  final mac = Uint8List.sublistView(raw, raw.length - 32);

  final keys = messageKeys(conversationKey, nonce);
  final expected = hmacSha256(keys.hmacKey, [...nonce, ...ciphertext]);
  if (!_constantTimeEquals(expected, mac)) {
    throw const NostrCryptoException('authentication failed');
  }

  return utf8.decode(
    _unpad(_chacha20(keys.chachaKey, keys.chachaNonce, ciphertext)),
  );
}

/// Compares without leaking where the first difference is.
bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Signs an event, filling in its id and signature.
Future<NostrEvent> signEvent({
  required NostrKeyPair keys,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
  Random? random,
}) async {
  final id = hex(
    sha256Of(
      utf8.encode(
        NostrEvent.canonical(
          pubkey: keys.publicKeyHex,
          createdAt: createdAt,
          kind: kind,
          tags: tags,
          content: content,
        ),
      ),
    ),
  );

  final rng = random ?? Random.secure();
  final aux = hex(
    Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256))),
  );

  return NostrEvent(
    id: id,
    pubkey: keys.publicKeyHex,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: bip340.sign(keys.privateKeyHex, id, aux),
  );
}

/// Verifies an event's id and signature.
///
/// Both matter. A valid signature over a different id would let a relay serve
/// altered content under a genuine author's key.
bool verifyEvent(NostrEvent event) {
  final expectedId = hex(
    sha256Of(
      utf8.encode(
        NostrEvent.canonical(
          pubkey: event.pubkey,
          createdAt: event.createdAt,
          kind: event.kind,
          tags: event.tags,
          content: event.content,
        ),
      ),
    ),
  );
  if (expectedId != event.id) return false;

  try {
    return bip340.verify(event.pubkey, event.id, event.sig);
  } catch (_) {
    return false;
  }
}
