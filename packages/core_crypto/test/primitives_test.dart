import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:test/test.dart';

Uint8List unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Directory repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (Directory('${dir.path}/testvectors').existsSync()) return dir;
    dir = dir.parent;
  }
  throw StateError('cannot find testvectors/ from ${Directory.current.path}');
}

Map<String, Object?> loadVectors() =>
    jsonDecode(
          File(
            '${repoRoot().path}/testvectors/crypto/noise_xx.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

void main() {
  final vectors = loadVectors();

  group('BLAKE2s', () {
    final kats = (vectors['blake2sHash']! as List).cast<Map<String, Object?>>();

    for (final (i, kat) in kats.indexed) {
      test('hash known-answer $i', () async {
        final digest = await blake2s(unhex(kat['inputHex']! as String));

        expect(hex(digest), kat['digestHex']);
      });
    }

    test('produces a 32-byte digest', () async {
      expect(await blake2s(Uint8List(0)), hasLength(32));
    });
  });

  group('HMAC-BLAKE2s', () {
    final kats = (vectors['hmacBlake2s']! as List).cast<Map<String, Object?>>();

    for (final (i, kat) in kats.indexed) {
      test('known-answer $i', () async {
        final mac = await hmacBlake2s(
          unhex(kat['keyHex']! as String),
          unhex(kat['dataHex']! as String),
        );

        expect(hex(mac), kat['macHex']);
      });
    }

    test('uses the RFC 7693 block size of 64 bytes', () {
      expect(
        blake2sBlockLength,
        64,
        reason:
            'the cryptography package reports 32 for Blake2s.blockLengthInBytes, '
            'which would silently produce a non-standard HMAC and break Noise HKDF',
      );
    });
  });

  group('Noise HKDF', () {
    test('derives two independent outputs', () async {
      final out = await hkdf2(Uint8List(32), Uint8List.fromList([1, 2, 3]));

      expect(out.$1, hasLength(32));
      expect(out.$2, hasLength(32));
      expect(hex(out.$1), isNot(hex(out.$2)));
    });

    test('derives three independent outputs', () async {
      final out = await hkdf3(Uint8List(32), Uint8List.fromList([1, 2, 3]));

      expect({hex(out.$1), hex(out.$2), hex(out.$3)}, hasLength(3));
    });

    test('is deterministic', () async {
      final a = await hkdf2(Uint8List(32), Uint8List.fromList([9]));
      final b = await hkdf2(Uint8List(32), Uint8List.fromList([9]));

      expect(hex(a.$1), hex(b.$1));
    });
  });

  group('CipherState', () {
    test('round-trips a payload', () async {
      final send = CipherState(Uint8List(32));
      final recv = CipherState(Uint8List(32));
      final plaintext = Uint8List.fromList('hello mesh'.codeUnits);

      final sealed = await send.encryptWithAd(Uint8List(0), plaintext);

      expect(await recv.decryptWithAd(Uint8List(0), sealed), plaintext);
    });

    test('appends a 16-byte authentication tag', () async {
      final state = CipherState(Uint8List(32));

      final sealed = await state.encryptWithAd(Uint8List(0), Uint8List(10));

      expect(sealed, hasLength(26));
    });

    test('advances the nonce on every message', () async {
      final send = CipherState(Uint8List(32));
      final recv = CipherState(Uint8List(32));
      final body = Uint8List.fromList([7, 7, 7]);

      final first = await send.encryptWithAd(Uint8List(0), body);
      final second = await send.encryptWithAd(Uint8List(0), body);

      expect(
        hex(first),
        isNot(hex(second)),
        reason: 'nonce reuse would be fatal',
      );
      expect(await recv.decryptWithAd(Uint8List(0), first), body);
      expect(await recv.decryptWithAd(Uint8List(0), second), body);
    });

    test('rejects a tampered ciphertext', () async {
      final send = CipherState(Uint8List(32));
      final recv = CipherState(Uint8List(32));
      final sealed = await send.encryptWithAd(Uint8List(0), Uint8List(8));
      sealed[3] ^= 0xFF;

      expect(
        () => recv.decryptWithAd(Uint8List(0), sealed),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('rejects a payload whose associated data does not match', () async {
      final send = CipherState(Uint8List(32));
      final recv = CipherState(Uint8List(32));
      final sealed = await send.encryptWithAd(
        Uint8List.fromList([1]),
        Uint8List(8),
      );

      expect(
        () => recv.decryptWithAd(Uint8List.fromList([2]), sealed),
        throwsA(isA<DecryptFailure>()),
      );
    });

    test('does not advance the nonce when decryption fails', () async {
      final send = CipherState(Uint8List(32));
      final recv = CipherState(Uint8List(32));
      final good = await send.encryptWithAd(Uint8List(0), Uint8List(4));
      final bad = Uint8List.fromList(good)..[0] ^= 0xFF;

      await expectLater(
        () => recv.decryptWithAd(Uint8List(0), bad),
        throwsA(isA<DecryptFailure>()),
      );

      expect(
        await recv.decryptWithAd(Uint8List(0), good),
        Uint8List(4),
        reason: 'a forged frame must not desynchronise a healthy session',
      );
    });

    test('refuses to continue past nonce exhaustion', () async {
      final state = CipherState(Uint8List(32), nonce: maxNonce);

      expect(
        () => state.encryptWithAd(Uint8List(0), Uint8List(1)),
        throwsA(isA<NonceExhausted>()),
      );
    });
  });
}
