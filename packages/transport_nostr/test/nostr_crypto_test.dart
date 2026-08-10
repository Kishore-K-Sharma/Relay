import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_nostr/src/chacha20.dart';
import 'package:transport_nostr/transport_nostr.dart';

/// The official NIP-44 v2 vectors, vendored at `testvectors/nostr/`.
///
/// They exist because an implementation that only ever talks to itself passes
/// every test it has while being unreadable by every real relay and client.
/// These are the only thing that proves otherwise.
Map<String, dynamic> loadVectors() {
  for (final candidate in [
    'testvectors/nostr/nip44.vectors.json',
    '../../testvectors/nostr/nip44.vectors.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return (jsonDecode(file.readAsStringSync()) as Map)['v2']
          as Map<String, dynamic>;
    }
  }
  throw StateError('NIP-44 vectors not found; run tests from the repo root');
}

void main() {
  final vectors = loadVectors();
  final valid = vectors['valid'] as Map<String, dynamic>;
  final invalid = vectors['invalid'] as Map<String, dynamic>;

  group('padding', () {
    for (final entry in valid['calc_padded_len'] as List) {
      final pair = entry as List;
      test('${pair[0]} pads to ${pair[1]}', () {
        expect(paddedLength(pair[0] as int), pair[1]);
      });
    }

    test('an empty plaintext is refused', () {
      expect(() => paddedLength(0), throwsA(isA<NostrCryptoException>()));
    });
  });

  group('conversation key', () {
    for (final (index, entry)
        in (valid['get_conversation_key'] as List).indexed) {
      final vector = entry as Map<String, dynamic>;
      test('vector $index matches byte for byte', () {
        expect(
          hex(
            conversationKey(vector['sec1'] as String, vector['pub2'] as String),
          ),
          vector['conversation_key'],
        );
      });
    }

    for (final (index, entry)
        in (invalid['get_conversation_key'] as List).indexed) {
      final vector = entry as Map<String, dynamic>;
      test('invalid vector $index is refused: ${vector['note']}', () {
        // A key off the curve, or zero, must be rejected rather than turned
        // into a shared secret an attacker chose.
        expect(
          () => conversationKey(
            vector['sec1'] as String,
            vector['pub2'] as String,
          ),
          throwsA(anything),
        );
      });
    }
  });

  group('message keys', () {
    final block = valid['get_message_keys'] as Map<String, dynamic>;
    final key = Uint8List.fromList(unhex(block['conversation_key'] as String));

    for (final (index, entry) in (block['keys'] as List).indexed) {
      final vector = entry as Map<String, dynamic>;
      test('vector $index derives the published keys', () {
        final derived = messageKeys(
          key,
          Uint8List.fromList(unhex(vector['nonce'] as String)),
        );

        expect(hex(derived.chachaKey), vector['chacha_key']);
        expect(hex(derived.chachaNonce), vector['chacha_nonce']);
        expect(hex(derived.hmacKey), vector['hmac_key']);
      });
    }
  });

  group('encrypt and decrypt', () {
    for (final (index, entry) in (valid['encrypt_decrypt'] as List).indexed) {
      final vector = entry as Map<String, dynamic>;
      final key = Uint8List.fromList(
        unhex(vector['conversation_key'] as String),
      );

      test('vector $index encrypts to the published payload', () {
        expect(
          nip44Encrypt(
            vector['plaintext'] as String,
            key,
            nonce: Uint8List.fromList(unhex(vector['nonce'] as String)),
          ),
          vector['payload'],
        );
      });

      test('vector $index decrypts back', () {
        expect(
          nip44Decrypt(vector['payload'] as String, key),
          vector['plaintext'],
        );
      });

      test('vector $index derives the published conversation key', () {
        expect(
          hex(
            conversationKey(
              vector['sec1'] as String,
              NostrKeyPair.fromPrivateHex(
                vector['sec2'] as String,
              ).publicKeyHex,
            ),
          ),
          vector['conversation_key'],
        );
      });
    }

    for (final (index, entry) in (invalid['decrypt'] as List).indexed) {
      final vector = entry as Map<String, dynamic>;
      test('invalid vector $index is refused: ${vector['note']}', () {
        expect(
          () => nip44Decrypt(
            vector['payload'] as String,
            Uint8List.fromList(unhex(vector['conversation_key'] as String)),
          ),
          throwsA(isA<NostrCryptoException>()),
        );
      });
    }
  });

  group('ChaCha20 against RFC 8439', () {
    test('section 2.4.2 test vector', () {
      // Proves the RFC layout — 32-bit counter, 12-byte nonce — rather than
      // the original DJB one, which is what most Dart libraries implement and
      // which produces a completely different keystream.
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final nonce = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0]);
      const plaintext =
          "Ladies and Gentlemen of the class of '99: If I could offer you "
          'only one tip for the future, sunscreen would be it.';

      final out = ChaCha20.apply(
        key: key,
        nonce: nonce,
        data: Uint8List.fromList(utf8.encode(plaintext)),
        counter: 1,
      );

      expect(hex(out).substring(0, 32), '6e2e359a2568f98041ba0728dd0d6981');
      expect(
        utf8.decode(
          ChaCha20.apply(key: key, nonce: nonce, data: out, counter: 1),
        ),
        plaintext,
      );
    });
  });

  group('round trip', () {
    late Uint8List key;

    setUp(() {
      final alice = NostrKeyPair.fromPrivateHex('0a' * 32);
      final bob = NostrKeyPair.fromPrivateHex('0b' * 32);
      key = conversationKey(alice.privateKeyHex, bob.publicKeyHex);
    });

    test('both sides derive the same key', () {
      final alice = NostrKeyPair.fromPrivateHex('0a' * 32);
      final bob = NostrKeyPair.fromPrivateHex('0b' * 32);

      expect(
        conversationKey(bob.privateKeyHex, alice.publicKeyHex),
        equals(key),
      );
    });

    test('round-trips a long message', () {
      final message = 'the north gate, ten minutes. ' * 40;

      expect(nip44Decrypt(nip44Encrypt(message, key), key), message);
    });

    test('round-trips text outside ASCII', () {
      const message = 'sortie nord — dix minutes 🚪';

      expect(nip44Decrypt(nip44Encrypt(message, key), key), message);
    });

    test('two encryptions of the same text differ', () {
      expect(nip44Encrypt('same', key), isNot(nip44Encrypt('same', key)));
    });

    test('the wrong key cannot open it', () {
      final other = conversationKey(
        '0c' * 32,
        NostrKeyPair.fromPrivateHex('0d' * 32).publicKeyHex,
      );

      expect(
        () => nip44Decrypt(nip44Encrypt('hello', key), other),
        throwsA(isA<NostrCryptoException>()),
      );
    });
  });

  group('events', () {
    test('a signed event verifies', () async {
      final event = await signEvent(
        keys: NostrKeyPair.fromPrivateHex('11' * 32),
        createdAt: 1700000000,
        kind: NostrEvent.kindGiftWrap,
        tags: [
          ['p', 'ab' * 32],
        ],
        content: 'sealed',
      );

      expect(verifyEvent(event), isTrue);
    });

    test('altering the content invalidates it', () async {
      final event = await signEvent(
        keys: NostrKeyPair.fromPrivateHex('11' * 32),
        createdAt: 1700000000,
        kind: 1,
        tags: const [],
        content: 'original',
      );

      final forged = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: 'altered',
        sig: event.sig,
      );

      // Checking the id as well as the signature is what catches this: the
      // signature is genuine, but it is a signature over other content.
      expect(verifyEvent(forged), isFalse);
    });

    test('an event survives JSON', () async {
      final event = await signEvent(
        keys: NostrKeyPair.fromPrivateHex('11' * 32),
        createdAt: 1700000000,
        kind: 1059,
        tags: [
          ['p', 'cd' * 32],
        ],
        content: 'x',
      );

      final decoded = NostrEvent.fromJson(
        jsonDecode(jsonEncode(event.toJson())),
      )!;

      expect(decoded.id, event.id);
      expect(verifyEvent(decoded), isTrue);
      expect(decoded.tag('p'), 'cd' * 32);
    });

    test('junk from a relay is ignored rather than crashing the client', () {
      expect(NostrEvent.fromJson('NOTICE'), isNull);
      expect(NostrEvent.fromJson({'id': 1}), isNull);
      expect(NostrEvent.fromJson(null), isNull);
    });

    test('every ephemeral keypair is different', () {
      final keys = List.generate(20, (_) => NostrKeyPair.ephemeral());

      // A reused wrapper key would let a relay operator link messages into a
      // conversation, which is the whole thing gift wrapping prevents.
      expect(keys.map((k) => k.publicKeyHex).toSet(), hasLength(20));
    });
  });
}
