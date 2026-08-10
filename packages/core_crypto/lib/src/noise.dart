import 'dart:typed_data';

// `cryptography` exports its own unrelated CipherState; ours is the Noise one.
import 'package:cryptography/cryptography.dart' hide CipherState;

import 'primitives.dart';

/// The Noise protocol suite this implementation speaks.
const String noiseProtocolName = 'Noise_XX_25519_ChaChaPoly_BLAKE2s';

final X25519 _x25519 = X25519();

Future<SimpleKeyPair> _keyPairFromPrivate(Uint8List privateKey) =>
    _x25519.newKeyPairFromSeed(privateKey);

Future<Uint8List> _publicBytes(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

Future<Uint8List> _dh(SimpleKeyPair local, Uint8List remotePublic) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: local,
    remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

/// Noise SymmetricState: the running chaining key and transcript hash.
class _SymmetricState {
  _SymmetricState(this.chainingKey, this.hash);

  static Future<_SymmetricState> create(String protocolName) async {
    final name = Uint8List.fromList(protocolName.codeUnits);
    final Uint8List h;
    if (name.length <= blake2sHashLength) {
      h = Uint8List(blake2sHashLength)..setRange(0, name.length, name);
    } else {
      h = await blake2s(name);
    }
    return _SymmetricState(Uint8List.fromList(h), h);
  }

  Uint8List chainingKey;
  Uint8List hash;
  CipherState? cipher;

  bool get hasKey => cipher != null;

  Future<void> mixHash(List<int> data) async {
    hash = await blake2s(<int>[...hash, ...data]);
  }

  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final (ck, temp) = await hkdf2(chainingKey, inputKeyMaterial);
    chainingKey = ck;
    cipher = CipherState(temp);
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    if (!hasKey) {
      await mixHash(plaintext);
      return Uint8List.fromList(plaintext);
    }
    final sealed = await cipher!.encryptWithAd(hash, plaintext);
    await mixHash(sealed);
    return sealed;
  }

  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    if (!hasKey) {
      await mixHash(ciphertext);
      return Uint8List.fromList(ciphertext);
    }
    final plaintext = await cipher!.decryptWithAd(hash, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  Future<(CipherState, CipherState)> split() async {
    final (k1, k2) = await hkdf2(chainingKey, const <int>[]);
    return (CipherState(k1), CipherState(k2));
  }
}

/// One half of a completed Noise handshake: two independent AEAD directions.
///
/// Two ways to use it:
///
///  - [encrypt] and [decrypt] follow the Noise spec exactly: an implicit
///    counter on each side, advanced in lockstep. Correct over a reliable,
///    ordered transport, and used by the published test vectors.
///  - [seal] and [open] transmit the nonce alongside the ciphertext and add a
///    replay window. **This is what the mesh uses.** Over BLE, frames are lost
///    and reordered as a matter of course, and an implicit counter leaves the
///    receiver permanently a step behind — every message after the first loss
///    fails to open, forever.
///
/// Rekeying applies only to the implicit-counter path. It cannot apply to the
/// framed path: a rekey triggered by message count desynchronises the moment a
/// message is lost, which is precisely the condition the framed path exists to
/// survive. The framed path therefore keeps one key per direction for the life
/// of the session, and bounds exposure by tearing the session down when the
/// peer goes away rather than by rotating within it.
class NoiseSession {
  NoiseSession({
    required CipherState send,
    required CipherState receive,
    required this.handshakeHash,
    this.rekeyAfterMessages = 100,
  }) : _send = send,
       _receive = receive;

  CipherState _send;
  CipherState _receive;

  /// Transcript hash, safe to expose as a channel binding.
  final Uint8List handshakeHash;

  final int rekeyAfterMessages;

  int _sent = 0;
  int _received = 0;
  int _rekeys = 0;

  /// Times either direction has been rekeyed. Both peers must agree.
  int get rekeyCount => _rekeys;

  Future<Uint8List> encrypt(
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final sealed = await _send.encryptWithAd(aad, plaintext);
    _sent++;
    if (_sent % rekeyAfterMessages == 0) {
      _send = await _send.rekey();
      _rekeys++;
    }
    return sealed;
  }

  Future<Uint8List> decrypt(
    List<int> ciphertext, {
    List<int> aad = const [],
  }) async {
    final plaintext = await _receive.decryptWithAd(aad, ciphertext);
    _received++;
    if (_received % rekeyAfterMessages == 0) {
      _receive = await _receive.rekey();
      _rekeys++;
    }
    return plaintext;
  }

  // ------------------------------------------------------- framed, for a mesh

  /// Highest nonce accepted so far, and a bitmap of the window below it.
  int _highestSeen = -1;
  int _window = 0;

  int _sendNonce = 0;

  /// Seals [plaintext] with its nonce prefixed, so loss and reordering survive.
  ///
  /// The nonce is not secret. It is already implicit in any ordered protocol;
  /// sending it explicitly only tells an observer how many messages have gone
  /// in this direction, which the frame count reveals anyway.
  Future<Uint8List> seal(
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final nonce = _sendNonce++;
    _send.nonce = nonce;
    final sealed = await _send.encryptWithAd(aad, plaintext);

    final out = Uint8List(explicitNonceLength + sealed.length);
    ByteData.view(out.buffer).setUint64(0, nonce, Endian.big);
    out.setRange(explicitNonceLength, out.length, sealed);
    _sent++;
    return out;
  }

  /// Opens a message produced by [seal].
  ///
  /// Throws [ReplayedMessage] for a nonce already accepted or older than the
  /// window, and [DecryptFailure] for anything that fails authentication. The
  /// window is only updated once authentication succeeds, so a forged frame
  /// cannot burn a nonce the genuine message still needs.
  Future<Uint8List> open(List<int> framed, {List<int> aad = const []}) async {
    if (framed.length < explicitNonceLength + 16) {
      throw const DecryptFailure('message shorter than its nonce and tag');
    }

    final bytes = Uint8List.fromList(framed);
    final nonce = ByteData.view(bytes.buffer).getUint64(0, Endian.big);
    if (nonce < 0 || nonce >= maxNonce) {
      throw const DecryptFailure('nonce outside the usable range');
    }
    _checkReplay(nonce);

    _receive.nonce = nonce;
    final plaintext = await _receive.decryptWithAd(
      aad,
      Uint8List.sublistView(bytes, explicitNonceLength),
    );

    _acceptNonce(nonce);
    _received++;
    return plaintext;
  }

  void _checkReplay(int nonce) {
    if (nonce > _highestSeen) return;

    final age = _highestSeen - nonce;
    if (age >= replayWindowSize) throw ReplayedMessage(nonce);
    if (_window & (1 << age) != 0) throw ReplayedMessage(nonce);
  }

  void _acceptNonce(int nonce) {
    if (nonce > _highestSeen) {
      final shift = nonce - _highestSeen;
      // A jump past the window width clears it entirely; shifting by 64 or
      // more is undefined for a fixed-width mask and would leave stale bits.
      _window = shift >= replayWindowSize
          ? 1
          : ((_window << shift) | 1) & _windowMask;
      _highestSeen = nonce;
      return;
    }
    _window |= 1 << (_highestSeen - nonce);
  }

  static const int _windowMask = (1 << replayWindowSize) - 1;
}

/// The Noise XX handshake:
///
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se
/// ```
///
/// XX is used because neither side knows the other's static key in advance —
/// two strangers meeting in a crowd — and it still delivers mutual
/// authentication and forward secrecy.
class NoiseHandshake {
  NoiseHandshake._({
    required this.isInitiator,
    required _SymmetricState symmetric,
    required SimpleKeyPair staticKey,
    required SimpleKeyPair ephemeralKey,
    required this.localStaticKey,
    required Uint8List localEphemeralKey,
  }) : _symmetric = symmetric,
       _static = staticKey,
       _ephemeral = ephemeralKey,
       _localEphemeralPublic = localEphemeralKey;

  /// Creates the initiating side.
  ///
  /// [testEphemeralPrivateKey] exists solely to reproduce published test
  /// vectors. Production code must never supply it — a fixed ephemeral key
  /// destroys forward secrecy.
  static Future<NoiseHandshake> initiator({
    Uint8List? staticPrivateKey,
    Uint8List? prologue,
    Uint8List? testEphemeralPrivateKey,
  }) => _create(
    isInitiator: true,
    staticPrivateKey: staticPrivateKey,
    prologue: prologue,
    testEphemeralPrivateKey: testEphemeralPrivateKey,
  );

  /// Creates the responding side. See [initiator] for the test-only parameter.
  static Future<NoiseHandshake> responder({
    Uint8List? staticPrivateKey,
    Uint8List? prologue,
    Uint8List? testEphemeralPrivateKey,
  }) => _create(
    isInitiator: false,
    staticPrivateKey: staticPrivateKey,
    prologue: prologue,
    testEphemeralPrivateKey: testEphemeralPrivateKey,
  );

  static Future<NoiseHandshake> _create({
    required bool isInitiator,
    required Uint8List? staticPrivateKey,
    required Uint8List? prologue,
    required Uint8List? testEphemeralPrivateKey,
  }) async {
    final symmetric = await _SymmetricState.create(noiseProtocolName);
    await symmetric.mixHash(prologue ?? Uint8List(0));

    final staticKey = staticPrivateKey != null
        ? await _keyPairFromPrivate(staticPrivateKey)
        : await _x25519.newKeyPair();
    final ephemeralKey = testEphemeralPrivateKey != null
        ? await _keyPairFromPrivate(testEphemeralPrivateKey)
        : await _x25519.newKeyPair();

    return NoiseHandshake._(
      isInitiator: isInitiator,
      symmetric: symmetric,
      staticKey: staticKey,
      ephemeralKey: ephemeralKey,
      localStaticKey: await _publicBytes(staticKey),
      localEphemeralKey: await _publicBytes(ephemeralKey),
    );
  }

  final bool isInitiator;
  final _SymmetricState _symmetric;
  final SimpleKeyPair _static;
  final SimpleKeyPair _ephemeral;
  final Uint8List _localEphemeralPublic;

  /// This device's long-lived public key for this handshake.
  final Uint8List localStaticKey;

  Uint8List? _remoteStatic;
  Uint8List? _remoteEphemeral;
  int _step = 0;

  /// The peer's static public key, known only once message 2 (responder) or
  /// message 3 (initiator) has been processed.
  Uint8List? get remoteStaticKey => _remoteStatic;

  Uint8List get handshakeHash => _symmetric.hash;

  bool get isComplete => _step >= 3;

  /// Whether it is this side's turn to write.
  bool get isMyTurn => isInitiator ? _step.isEven : _step.isOdd;

  Future<Uint8List> writeMessage(List<int> payload) async {
    if (isComplete) throw StateError('handshake already complete');
    if (!isMyTurn) throw StateError('not this side\'s turn to write');

    final out = <int>[];

    switch (_step) {
      case 0: // -> e
        out.addAll(_localEphemeralPublic);
        await _symmetric.mixHash(_localEphemeralPublic);
        out.addAll(await _symmetric.encryptAndHash(payload));

      case 1: // <- e, ee, s, es
        out.addAll(_localEphemeralPublic);
        await _symmetric.mixHash(_localEphemeralPublic);
        await _symmetric.mixKey(await _dh(_ephemeral, _remoteEphemeral!));
        out.addAll(await _symmetric.encryptAndHash(localStaticKey));
        await _symmetric.mixKey(await _dh(_static, _remoteEphemeral!));
        out.addAll(await _symmetric.encryptAndHash(payload));

      case 2: // -> s, se
        out.addAll(await _symmetric.encryptAndHash(localStaticKey));
        await _symmetric.mixKey(await _dh(_static, _remoteEphemeral!));
        out.addAll(await _symmetric.encryptAndHash(payload));

      default:
        throw StateError('unreachable handshake step $_step');
    }

    _step++;
    return Uint8List.fromList(out);
  }

  Future<Uint8List> readMessage(List<int> message) async {
    if (isComplete) throw StateError('handshake already complete');
    if (isMyTurn) throw StateError('not this side\'s turn to read');

    var offset = 0;
    Uint8List take(int n) {
      if (offset + n > message.length) {
        throw const DecryptFailure('handshake message truncated');
      }
      final slice = Uint8List.fromList(message.sublist(offset, offset + n));
      offset += n;
      return slice;
    }

    // A static key field is encrypted (and so 16 bytes longer) once a key is
    // established.
    int keyFieldLength() => _symmetric.hasKey ? 48 : 32;

    final Uint8List payload;
    switch (_step) {
      case 0: // -> e
        _remoteEphemeral = take(32);
        await _symmetric.mixHash(_remoteEphemeral!);
        payload = await _symmetric.decryptAndHash(message.sublist(offset));

      case 1: // <- e, ee, s, es
        _remoteEphemeral = take(32);
        await _symmetric.mixHash(_remoteEphemeral!);
        await _symmetric.mixKey(await _dh(_ephemeral, _remoteEphemeral!));
        _remoteStatic = await _symmetric.decryptAndHash(take(keyFieldLength()));
        await _symmetric.mixKey(await _dh(_ephemeral, _remoteStatic!));
        payload = await _symmetric.decryptAndHash(message.sublist(offset));

      case 2: // -> s, se
        _remoteStatic = await _symmetric.decryptAndHash(take(keyFieldLength()));
        await _symmetric.mixKey(await _dh(_ephemeral, _remoteStatic!));
        payload = await _symmetric.decryptAndHash(message.sublist(offset));

      default:
        throw StateError('unreachable handshake step $_step');
    }

    _step++;
    return payload;
  }

  /// Produces the transport session. Only valid once the handshake completed.
  ///
  /// The initiator's first cipher state sends and the responder's receives, so
  /// the two peers agree on direction without exchanging anything further.
  Future<NoiseSession> split({int rekeyAfterMessages = 100}) async {
    if (!isComplete) {
      throw StateError('cannot split before the handshake completes');
    }
    final (c1, c2) = await _symmetric.split();
    return NoiseSession(
      send: isInitiator ? c1 : c2,
      receive: isInitiator ? c2 : c1,
      handshakeHash: _symmetric.hash,
      rekeyAfterMessages: rekeyAfterMessages,
    );
  }
}

/// The X25519 public key for a 32-byte private key.
///
/// Exposed because sealing an envelope needs the recipient's public key and
/// the caller holds only their own private one.
Future<Uint8List> publicKeyOf(Uint8List privateKey) async =>
    _publicBytes(await _keyPairFromPrivate(privateKey));

/// One-way Noise X: `-> e, es, s, ss`.
///
/// A single message, sealed to a recipient who is not present and never
/// replies. That is exactly the shape a courier envelope needs: the sender may
/// be gone by the time it is delivered, and the courier in between must learn
/// nothing.
///
/// What it provides: the recipient learns the sender's static key, encrypted,
/// and knows the message came from whoever holds it. What it does **not**
/// provide is forward secrecy — the sealed key is the recipient's long-term
/// static, so somebody who later obtains that key can open every envelope they
/// captured. A prekey variant would fix that and is not built; see
/// `docs/SECURITY.md`.
abstract final class NoiseX {
  static const String protocolName = 'Noise_X_25519_ChaChaPoly_BLAKE2s';

  /// Seals [payload] to [recipientStatic], authenticated as [senderPrivate].
  static Future<Uint8List> seal({
    required Uint8List senderPrivate,
    required Uint8List recipientStatic,
    required List<int> payload,
    List<int> prologue = const [],
  }) async {
    final symmetric = await _SymmetricState.create(protocolName);
    await symmetric.mixHash(prologue);
    // The responder's static key is known in advance, so it is a pre-message
    // and is mixed into the hash before anything is written.
    await symmetric.mixHash(recipientStatic);

    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await _publicBytes(ephemeral);
    final sender = await _keyPairFromPrivate(senderPrivate);

    final out = BytesBuilder()..add(ephemeralPublic);
    await symmetric.mixHash(ephemeralPublic);

    // es
    await symmetric.mixKey(await _dh(ephemeral, recipientStatic));
    out.add(await symmetric.encryptAndHash(await _publicBytes(sender)));

    // ss
    await symmetric.mixKey(await _dh(sender, recipientStatic));
    out.add(await symmetric.encryptAndHash(payload));

    return out.toBytes();
  }

  /// Opens a sealed envelope, returning the sender's static key and the
  /// payload, or null when it was not for us or has been tampered with.
  ///
  /// Null rather than an exception: a courier hands over everything it is
  /// carrying, so failing to open one is the normal case rather than an error.
  static Future<({Uint8List senderStatic, Uint8List payload})?> open({
    required Uint8List recipientPrivate,
    required Uint8List sealed,
    List<int> prologue = const [],
  }) async {
    // 32-byte ephemeral, 32+16 sealed static, and at least a 16-byte tag on
    // the payload.
    if (sealed.length < 32 + 48 + 16) return null;

    try {
      final recipient = await _keyPairFromPrivate(recipientPrivate);
      final recipientPublic = await _publicBytes(recipient);

      final symmetric = await _SymmetricState.create(protocolName);
      await symmetric.mixHash(prologue);
      await symmetric.mixHash(recipientPublic);

      final remoteEphemeral = Uint8List.sublistView(sealed, 0, 32);
      await symmetric.mixHash(remoteEphemeral);

      await symmetric.mixKey(await _dh(recipient, remoteEphemeral));
      final senderStatic = await symmetric.decryptAndHash(
        Uint8List.sublistView(sealed, 32, 80),
      );

      await symmetric.mixKey(await _dh(recipient, senderStatic));
      final payload = await symmetric.decryptAndHash(
        Uint8List.sublistView(sealed, 80),
      );

      return (senderStatic: senderStatic, payload: payload);
    } on Object {
      return null;
    }
  }
}
