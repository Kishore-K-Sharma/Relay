import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:test/test.dart';

Uint8List key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i + seed) & 0xFF));

void main() {
  group('MeshIdentity', () {
    test('generates a 32-byte Ed25519 public key', () async {
      final identity = await MeshIdentity.generate();

      expect(identity.publicKey, hasLength(32));
    });

    test('two generated identities differ', () async {
      final a = await MeshIdentity.generate();
      final b = await MeshIdentity.generate();

      expect(a.publicKey, isNot(b.publicKey));
    });

    test('restores deterministically from a seed', () async {
      final a = await MeshIdentity.fromSeed(key(1));
      final b = await MeshIdentity.fromSeed(key(1));

      expect(a.publicKey, b.publicKey);
    });

    test('signs and verifies', () async {
      final identity = await MeshIdentity.fromSeed(key(2));
      final message = Uint8List.fromList('announce'.codeUnits);

      final signature = await identity.sign(message);

      expect(
        await verifySignature(message, signature, identity.publicKey),
        isTrue,
      );
    });

    test('rejects a signature from a different key', () async {
      final a = await MeshIdentity.fromSeed(key(3));
      final b = await MeshIdentity.fromSeed(key(4));
      final message = Uint8List.fromList('announce'.codeUnits);

      final signature = await a.sign(message);

      expect(await verifySignature(message, signature, b.publicKey), isFalse);
    });

    test('rejects a signature over different content', () async {
      final identity = await MeshIdentity.fromSeed(key(5));
      final signature = await identity.sign(Uint8List.fromList([1, 2, 3]));

      expect(
        await verifySignature(
          Uint8List.fromList([1, 2, 4]),
          signature,
          identity.publicKey,
        ),
        isFalse,
      );
    });
  });

  group('address hash', () {
    test('is 32 bits', () async {
      final hash = await addressHashOf(key(1));

      expect(hash, greaterThanOrEqualTo(0));
      expect(hash, lessThanOrEqualTo(0xFFFFFFFF));
    });

    test('is deterministic for a key', () async {
      expect(await addressHashOf(key(7)), await addressHashOf(key(7)));
    });

    test('differs between keys', () async {
      expect(await addressHashOf(key(7)), isNot(await addressHashOf(key(8))));
    });

    test('never collides with the broadcast address', () async {
      for (var i = 0; i < 50; i++) {
        expect(
          await addressHashOf(key(i)),
          isNot(0),
          reason: 'a zero hash would be indistinguishable from broadcast',
        );
      }
    });
  });

  group('SafetyCode', () {
    test('is identical regardless of which side computes it', () async {
      final a = key(1);
      final b = key(2);

      expect(
        (await SafetyCode.between(a, b)).digits,
        (await SafetyCode.between(b, a)).digits,
      );
    });

    test('differs for a different pair', () async {
      final one = await SafetyCode.between(key(1), key(2));
      final two = await SafetyCode.between(key(1), key(3));

      expect(one.digits, isNot(two.digits));
    });

    test('renders 60 digits in 12 groups of 5', () async {
      final code = await SafetyCode.between(key(1), key(2));

      expect(code.digits, hasLength(60));
      expect(code.digits, matches(RegExp(r'^\d{60}$')));
      expect(code.formatted.split(' '), hasLength(12));
      expect(code.formatted.split(' ').every((g) => g.length == 5), isTrue);
    });
  });

  group('ContactStore', () {
    late ContactStore store;

    setUp(() => store = ContactStore());

    test('starts empty', () {
      expect(store.contacts, isEmpty);
      expect(store.lookup(key(1)), isNull);
    });

    test('pins a scanned contact as verified', () async {
      await store.pin(publicKey: key(1), nickname: 'Sara');

      expect(store.lookup(key(1))!.trust, TrustState.verified);
      expect(store.lookup(key(1))!.nickname, 'Sara');
    });

    test('stores a safety code alongside a pinned contact', () async {
      await store.pin(publicKey: key(1), nickname: 'Sara', localKey: key(9));

      expect(store.lookup(key(1))!.safetyCode, isNotNull);
    });

    test('records an unverified peer seen over the air', () {
      store.observe(publicKey: key(2), nickname: 'bluejay_88');

      expect(store.lookup(key(2))!.trust, TrustState.unverified);
    });

    test(
      'observing a peer does not downgrade an existing verified contact',
      () async {
        await store.pin(publicKey: key(1), nickname: 'Sara');

        store.observe(publicKey: key(1), nickname: 'not-sara');

        final contact = store.lookup(key(1))!;
        expect(contact.trust, TrustState.verified);
        expect(
          contact.nickname,
          'Sara',
          reason:
              'a nickname broadcast over the air must not overwrite a '
              'verified contact name, or impersonation becomes trivial',
        );
      },
    );

    test('flags a verified contact whose key changed', () async {
      await store.pin(publicKey: key(1), nickname: 'Sara');

      final result = store.observe(
        publicKey: key(99),
        nickname: 'Sara',
        claimsToReplace: key(1),
      );

      expect(result, ObserveResult.keyChanged);
      expect(store.lookup(key(1))!.trust, TrustState.keyChanged);
    });

    test('a key-changed contact stays flagged until re-verified', () async {
      await store.pin(publicKey: key(1), nickname: 'Sara');
      store.observe(
        publicKey: key(99),
        nickname: 'Sara',
        claimsToReplace: key(1),
      );

      expect(store.lookup(key(1))!.trust, TrustState.keyChanged);

      await store.pin(publicKey: key(1), nickname: 'Sara');
      expect(store.lookup(key(1))!.trust, TrustState.verified);
    });

    test('forgets a contact on request', () async {
      await store.pin(publicKey: key(1), nickname: 'Sara');

      store.forget(key(1));

      expect(store.lookup(key(1)), isNull);
    });
  });

  group('RoomCode', () {
    test('normalises to upper case', () {
      expect(RoomCode.parse('fest24').value, 'FEST24');
    });

    test('accepts exactly six characters from the safe alphabet', () {
      expect(RoomCode.parse('FEST24').value, 'FEST24');
      expect(() => RoomCode.parse('FEST2'), throwsA(isA<FormatException>()));
      expect(() => RoomCode.parse('FEST245'), throwsA(isA<FormatException>()));
    });

    test('rejects visually ambiguous characters', () {
      for (final bad in ['FEST2O', 'FEST20', 'FEST2I', 'FEST21', 'FEST2L']) {
        expect(
          () => RoomCode.parse(bad),
          throwsA(isA<FormatException>()),
          reason: '$bad contains a glyph that is easy to misread aloud',
        );
      }
    });

    test('generates codes only from the safe alphabet', () {
      for (var i = 0; i < 100; i++) {
        final code = RoomCode.generate();
        expect(code.value, hasLength(6));
        expect(
          code.value.split('').every(roomCodeAlphabet.contains),
          isTrue,
          reason: '${code.value} left the safe alphabet',
        );
      }
    });

    test('reports its own entropy honestly', () {
      expect(RoomCode.entropyBits, closeTo(30.0, 1.5));
      expect(
        RoomCode.isStrongSecret,
        isFalse,
        reason: 'the UI must never present a room code as strong security',
      );
    });

    test('derives a stable 32-byte room key', () async {
      final a = await deriveRoomKey(RoomCode.parse('FEST24'));
      final b = await deriveRoomKey(RoomCode.parse('fest24'));

      expect(a.key, hasLength(32));
      expect(a.key, b.key);
    });

    test('derives different keys for different codes', () async {
      final a = await deriveRoomKey(RoomCode.parse('FEST24'));
      final b = await deriveRoomKey(RoomCode.parse('FEST25'));

      expect(a.key, isNot(b.key));
      expect(a.roomId, isNot(b.roomId));
    });

    test('derives a 4-byte room id usable as an address', () async {
      final room = await deriveRoomKey(RoomCode.parse('FEST24'));

      expect(room.roomId, greaterThan(0));
      expect(room.roomId, lessThanOrEqualTo(0xFFFFFFFF));
    });
  });
}
