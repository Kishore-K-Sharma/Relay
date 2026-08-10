import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

Uint8List seed(int fill) => Uint8List.fromList(List.filled(32, fill));

/// Runs a full XX handshake between two managers and returns them established.
Future<(SessionManager, SessionManager)> handshaken({
  int aliceHash = 0xAAAA1111,
  int bobHash = 0xBBBB2222,
}) async {
  final alice = SessionManager(
    staticPrivateKey: seed(1),
    localAddressHash: aliceHash,
  );
  final bob = SessionManager(
    staticPrivateKey: seed(2),
    localAddressHash: bobHash,
  );

  final msg1 = await alice.beginHandshake(bobHash);
  final msg2 = await bob.receiveHandshake(aliceHash, msg1);
  final msg3 = await alice.receiveHandshake(bobHash, msg2!);
  final none = await bob.receiveHandshake(aliceHash, msg3!);

  expect(none, isNull, reason: 'XX is three messages; there is no fourth');
  return (alice, bob);
}

void main() {
  group('handshake', () {
    test('a fresh peer has no session', () {
      final manager = SessionManager(staticPrivateKey: seed(1));

      expect(manager.stateFor(0x1234), SessionState.none);
    });

    test('beginning a handshake moves the peer to handshaking', () async {
      final manager = SessionManager(staticPrivateKey: seed(1));

      await manager.beginHandshake(0x1234);

      expect(manager.stateFor(0x1234), SessionState.handshaking);
    });

    test('three messages establish both sides', () async {
      final (alice, bob) = await handshaken();

      expect(alice.stateFor(0xBBBB2222), SessionState.established);
      expect(bob.stateFor(0xAAAA1111), SessionState.established);
    });

    test('each side learns the other\'s static key', () async {
      final (alice, bob) = await handshaken();

      // Pinning a contact is impossible without this, and pinning is what makes
      // an impersonation attempt visible later.
      expect(alice.remoteStaticKey(0xBBBB2222), isNotNull);
      expect(bob.remoteStaticKey(0xAAAA1111), isNotNull);
      expect(alice.remoteStaticKey(0xBBBB2222), isNot(alice.localStaticKey));
    });

    test('both sides derive the same handshake hash', () async {
      final (alice, bob) = await handshaken();

      // The safety code is computed over this. If the two sides disagreed, two
      // honest users would see different codes and conclude they were attacked.
      expect(
        alice.handshakeHash(0xBBBB2222),
        equals(bob.handshakeHash(0xAAAA1111)),
      );
    });

    test('a peer that opens with message 1 while we are mid-handshake is '
        'answered rather than dropped', () async {
      final alice = SessionManager(
        staticPrivateKey: seed(1),
        localAddressHash: 0xAAAA1111,
      );
      final bob = SessionManager(
        staticPrivateKey: seed(2),
        localAddressHash: 0xBBBB2222,
      );

      // Both reach for each other at once, which happens constantly in a crowd.
      final aliceOpening = await alice.beginHandshake(0xBBBB2222);
      final bobOpening = await bob.beginHandshake(0xAAAA1111);

      // Alice has the lower hash, so she yields and answers Bob's opening.
      final reply = await alice.receiveHandshake(0xBBBB2222, bobOpening);
      expect(reply, isNotNull);

      // Bob holds his ground: Alice's opening is ignored, not answered, or the
      // two would deadlock as mutual responders.
      expect(await bob.receiveHandshake(0xAAAA1111, aliceOpening), isNull);

      final finish = await bob.receiveHandshake(0xAAAA1111, reply!);
      await alice.receiveHandshake(0xBBBB2222, finish!);

      expect(alice.stateFor(0xBBBB2222), SessionState.established);
      expect(bob.stateFor(0xAAAA1111), SessionState.established);
    });

    test('garbage on the handshake channel tears the session down', () async {
      final manager = SessionManager(staticPrivateKey: seed(1));
      await manager.beginHandshake(0x1234);

      await expectLater(
        manager.receiveHandshake(0x1234, Uint8List.fromList([1, 2, 3])),
        throwsA(isA<Exception>()),
      );

      // Left half-open, the peer could never recover: every later attempt would
      // be fed into a symmetric state that can no longer make progress.
      expect(manager.stateFor(0x1234), SessionState.none);
    });
  });

  group('transport', () {
    test('a message encrypted by one side decrypts on the other', () async {
      final (alice, bob) = await handshaken();
      final plaintext = Uint8List.fromList('meet at the gate'.codeUnits);

      final sealed = await alice.encrypt(0xBBBB2222, plaintext);
      final opened = await bob.decrypt(0xAAAA1111, sealed);

      expect(opened, equals(plaintext));
    });

    test('ciphertext does not contain the plaintext', () async {
      final (alice, _) = await handshaken();
      final plaintext = Uint8List.fromList('meet at the gate'.codeUnits);

      final sealed = await alice.encrypt(0xBBBB2222, plaintext);

      expect(String.fromCharCodes(sealed), isNot(contains('gate')));
      // An 8-byte nonce rides along so a lost frame does not desynchronise
      // the stream, plus the 16-byte ChaCha20-Poly1305 tag.
      expect(sealed.length, plaintext.length + 8 + 16);
    });

    test('a tampered byte is rejected, not silently accepted', () async {
      final (alice, bob) = await handshaken();
      final sealed = await alice.encrypt(
        0xBBBB2222,
        Uint8List.fromList('hello'.codeUnits),
      );
      sealed[0] ^= 0xFF;

      await expectLater(
        bob.decrypt(0xAAAA1111, sealed),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('encrypting to a peer with no session is refused', () async {
      final manager = SessionManager(staticPrivateKey: seed(1));

      // Returning the plaintext, or a silent no-op, would be the worst possible
      // failure mode: the message would go out readable while the UI claimed
      // it was encrypted.
      await expectLater(
        manager.encrypt(0x1234, Uint8List.fromList([1])),
        throwsA(isA<NoSessionException>()),
      );
    });

    test('a long conversation keeps working', () async {
      final (alice, bob) = await handshaken();

      for (var i = 0; i < 205; i++) {
        final sealed = await alice.encrypt(
          0xBBBB2222,
          Uint8List.fromList('message $i'.codeUnits),
        );
        final opened = await bob.decrypt(0xAAAA1111, sealed);
        expect(String.fromCharCodes(opened), 'message $i');
      }
    });

    test('a dropped message does not break the ones after it', () async {
      final (alice, bob) = await handshaken();

      // The defining condition of a BLE mesh. If this failed, one lost frame
      // would end the conversation permanently.
      await alice.encrypt(0xBBBB2222, Uint8List.fromList('lost'.codeUnits));

      final next = await alice.encrypt(
        0xBBBB2222,
        Uint8List.fromList('arrives'.codeUnits),
      );

      expect(
        String.fromCharCodes(await bob.decrypt(0xAAAA1111, next)),
        'arrives',
      );
    });

    test('forgetting a peer removes the session', () async {
      final (alice, _) = await handshaken();

      alice.forget(0xBBBB2222);

      expect(alice.stateFor(0xBBBB2222), SessionState.none);
    });

    test('wiping removes every session', () async {
      final (alice, _) = await handshaken();

      alice.wipe();

      expect(alice.stateFor(0xBBBB2222), SessionState.none);
    });
  });

  group('rooms', () {
    test('a room message decrypts under the same key', () async {
      final key = seed(9);
      final cipher = RoomCipher(key);
      final plaintext = Uint8List.fromList(
        'everyone to the north exit'.codeUnits,
      );

      final sealed = await cipher.encrypt(plaintext);
      final opened = await RoomCipher(key).decrypt(sealed);

      expect(opened, equals(plaintext));
    });

    test('a different key cannot open it', () async {
      final sealed = await RoomCipher(
        seed(9),
      ).encrypt(Uint8List.fromList('hello'.codeUnits));

      await expectLater(
        RoomCipher(seed(8)).decrypt(sealed),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('two encryptions of the same text differ', () async {
      final cipher = RoomCipher(seed(9));
      final plaintext = Uint8List.fromList('same'.codeUnits);

      final a = await cipher.encrypt(plaintext);
      final b = await cipher.encrypt(plaintext);

      // A room key is long-lived and shared by everyone who was told the code.
      // A deterministic ciphertext would leak repeated messages to anyone
      // watching the air, without their needing the key at all.
      expect(a, isNot(equals(b)));
    });

    test('a truncated room message is rejected', () async {
      await expectLater(
        RoomCipher(seed(9)).decrypt(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<DecryptFailure>()),
      );
    });
  });
}
