import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';

/// Length of Noise XX message 1: a bare 32-byte ephemeral public key.
///
/// Message 2 carries an ephemeral key, an encrypted static key and a tag, so it
/// is 96 bytes. The difference is what tells an initiator awaiting message 2
/// apart from one that has just been handed a competing opening.
const int noiseFirstMessageLength = 32;

/// Where a peer is in the process of establishing a secure channel.
enum SessionState {
  /// Nothing yet. Sending requires a handshake first.
  none,

  /// A handshake is in flight. Messages must be queued, never sent in clear.
  handshaking,

  /// A transport session exists and messages can be encrypted.
  established,
}

/// Thrown when a caller tries to encrypt to a peer with no session.
///
/// Deliberately an exception rather than a fallback to plaintext. A silent
/// fallback would put a readable message on the air while the UI showed a lock,
/// which is worse than not sending at all.
class NoSessionException implements Exception {
  const NoSessionException(this.peerHash);

  final int peerHash;

  @override
  String toString() =>
      'NoSessionException: no established session with '
      '${peerHash.toRadixString(16)}';
}

/// Holds the Noise session for every peer this device talks to.
///
/// One instance per device. It knows nothing about frames, transports or
/// storage: callers hand it opaque bytes and get opaque bytes back, which keeps
/// the whole handshake state machine testable without a radio.
class SessionManager {
  SessionManager({
    required Uint8List staticPrivateKey,
    this.localAddressHash = 0,
    this.rekeyAfter = 100,
  }) : _staticPrivateKey = Uint8List.fromList(staticPrivateKey);

  final Uint8List _staticPrivateKey;

  /// This device's routing hash. Used only to break a simultaneous open; see
  /// [receiveHandshake].
  final int localAddressHash;

  /// Messages per direction before the key is rotated. Both peers must agree
  /// or they desynchronise at the boundary.
  final int rekeyAfter;

  final _handshakes = <int, NoiseHandshake>{};
  final _sessions = <int, NoiseSession>{};
  final _remoteKeys = <int, Uint8List>{};
  final _handshakeHashes = <int, Uint8List>{};

  Uint8List? _localStaticKey;

  /// This device's Noise static public key, once a handshake has produced it.
  Uint8List? get localStaticKey => _localStaticKey;

  SessionState stateFor(int peerHash) {
    if (_sessions.containsKey(peerHash)) return SessionState.established;
    if (_handshakes.containsKey(peerHash)) return SessionState.handshaking;
    return SessionState.none;
  }

  /// Everyone this device can encrypt to right now.
  List<int> get establishedPeers => _sessions.keys.toList();

  /// The peer's long-term public key, known only once the handshake completes.
  Uint8List? remoteStaticKey(int peerHash) => _remoteKeys[peerHash];

  /// Channel binding for the session. The safety code is computed over this.
  Uint8List? handshakeHash(int peerHash) => _handshakeHashes[peerHash];

  /// Starts a handshake and returns Noise message 1 to put on the wire.
  Future<Uint8List> beginHandshake(int peerHash) async {
    final handshake = await NoiseHandshake.initiator(
      staticPrivateKey: _staticPrivateKey,
    );
    _localStaticKey = handshake.localStaticKey;
    _handshakes[peerHash] = handshake;
    return handshake.writeMessage(const <int>[]);
  }

  /// Feeds an inbound handshake message.
  ///
  /// Returns the reply to send, or null when the handshake is finished and
  /// there is nothing further to say.
  Future<Uint8List?> receiveHandshake(int peerHash, Uint8List message) async {
    var handshake = _handshakes[peerHash];

    if (handshake == null) {
      handshake = await NoiseHandshake.responder(
        staticPrivateKey: _staticPrivateKey,
      );
      _localStaticKey = handshake.localStaticKey;
      _handshakes[peerHash] = handshake;
    } else if (_isAwaitingSecondMessage(handshake) &&
        message.length == noiseFirstMessageLength) {
      // A simultaneous open: both sides reached for each other at once, which
      // happens constantly in a crowd. Left alone it deadlocks — two initiators
      // each waiting for a responder that never appears.
      //
      // The lower address hash yields and becomes the responder. The rule has
      // to be decided from data both sides already have, and it has to give
      // opposite answers on the two devices; comparing hashes does both. The
      // other side ignores this message and goes on waiting for the reply to
      // its own opening, which is exactly what it will now receive.
      if (localAddressHash >= peerHash) return null;

      handshake = await NoiseHandshake.responder(
        staticPrivateKey: _staticPrivateKey,
      );
      _handshakes[peerHash] = handshake;
    }

    try {
      await handshake.readMessage(message);

      if (handshake.isComplete) {
        await _establish(peerHash, handshake);
        return null;
      }

      final reply = await handshake.writeMessage(const <int>[]);

      if (handshake.isComplete) {
        await _establish(peerHash, handshake);
      }
      return reply;
    } catch (_) {
      // A half-open handshake can never recover: every later message is fed
      // into a symmetric state that cannot make progress. Dropping it lets the
      // next attempt start cleanly.
      _handshakes.remove(peerHash);
      rethrow;
    }
  }

  /// True when this side sent Noise message 1 and is waiting for message 2.
  ///
  /// It is the initiator's only incomplete state in which it is not its turn to
  /// write, so no step counter needs exposing to detect it.
  static bool _isAwaitingSecondMessage(NoiseHandshake handshake) =>
      handshake.isInitiator && !handshake.isMyTurn && !handshake.isComplete;

  Future<void> _establish(int peerHash, NoiseHandshake handshake) async {
    _sessions[peerHash] = await handshake.split(rekeyAfterMessages: rekeyAfter);
    _remoteKeys[peerHash] = handshake.remoteStaticKey!;
    _handshakeHashes[peerHash] = handshake.handshakeHash;
    _handshakes.remove(peerHash);
  }

  // Both are `async` so a missing session surfaces as a rejected future rather
  // than a synchronous throw. A Future-returning method that sometimes throws
  // before returning is a trap: `catchError` on the result never sees it.

  /// Seals a message for [peerHash].
  ///
  /// Uses the framed path — nonce on the wire, replay window on receipt —
  /// because the mesh loses and reorders frames as a matter of course, and
  /// Noise's implicit counter cannot survive that.
  Future<Uint8List> encrypt(int peerHash, Uint8List plaintext) async {
    final session = _sessions[peerHash];
    if (session == null) throw NoSessionException(peerHash);
    return session.seal(plaintext);
  }

  Future<Uint8List> decrypt(int peerHash, Uint8List ciphertext) async {
    final session = _sessions[peerHash];
    if (session == null) throw NoSessionException(peerHash);
    return session.open(ciphertext);
  }

  /// Drops one peer's session, forcing a fresh handshake next time.
  void forget(int peerHash) {
    _sessions.remove(peerHash);
    _handshakes.remove(peerHash);
    _remoteKeys.remove(peerHash);
    _handshakeHashes.remove(peerHash);
  }

  /// Part of panic wipe. Irreversible.
  void wipe() {
    _sessions.clear();
    _handshakes.clear();
    _remoteKeys.clear();
    _handshakeHashes.clear();
  }
}

/// Symmetric encryption for a room, keyed by the shared room code.
///
/// Deliberately not a Noise session. Everyone who knows the code holds the same
/// key, so there is no pairwise handshake to run and no forward secrecy to be
/// had. The UI has to say so plainly rather than show a lock.
class RoomCipher {
  RoomCipher(Uint8List key, {Random? random})
    : _key = Uint8List.fromList(key),
      _random = random ?? Random.secure() {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
  }

  /// Random nonce prefix length. Twelve bytes is the ChaCha20-Poly1305 nonce
  /// size; four of them are the Noise counter field, so only eight are usable
  /// here and the counter portion is randomised too.
  static const int nonceLength = 8;

  final Uint8List _key;
  final Random _random;

  /// Seals [plaintext] with a fresh random nonce, prefixed to the output.
  ///
  /// The nonce is random rather than a counter because a room has no single
  /// sender to own the sequence: every member encrypts under the same key, and
  /// two members picking the same counter would destroy confidentiality for
  /// both messages.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final nonce = Uint8List.fromList(
      List<int>.generate(nonceLength, (_) => _random.nextInt(256)),
    );
    final sealed = await _stateFor(
      nonce,
    ).encryptWithAd(const <int>[], plaintext);

    final out = Uint8List(nonceLength + sealed.length);
    out.setRange(0, nonceLength, nonce);
    out.setRange(nonceLength, out.length, sealed);
    return out;
  }

  Future<Uint8List> decrypt(Uint8List sealed) async {
    if (sealed.length < nonceLength + 16) {
      throw const DecryptFailure('room message shorter than nonce and tag');
    }
    final nonce = Uint8List.sublistView(sealed, 0, nonceLength);
    final body = Uint8List.sublistView(sealed, nonceLength);
    return _stateFor(nonce).decryptWithAd(const <int>[], body);
  }

  /// Builds the cipher state positioned at the counter [nonce] encodes.
  ///
  /// [CipherState] stores the counter as a Dart integer, which is signed and
  /// must stay below [maxNonce], so the top two bits of the eight random bytes
  /// are discarded. Both sides do this to the same transmitted bytes and so
  /// reach the same state; 62 bits of randomness is far more than enough to
  /// make a collision under one room key implausible.
  CipherState _stateFor(Uint8List nonce) => CipherState(
    _key,
    nonce: ByteData.view(
      nonce.buffer,
      nonce.offsetInBytes,
      nonceLength,
    ).getUint64(0, Endian.little).toUnsigned(62),
  );
}
