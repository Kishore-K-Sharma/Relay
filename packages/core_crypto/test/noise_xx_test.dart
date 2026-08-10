import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:test/test.dart';

import 'primitives_test.dart' show hex, loadVectors, unhex;

void main() {
  final vectors = loadVectors();
  final xx = vectors['noiseXX']! as Map<String, Object?>;
  final messages = (xx['messages']! as List).cast<Map<String, Object?>>();

  Future<(NoiseHandshake, NoiseHandshake)> buildPair() async {
    final initiator = await NoiseHandshake.initiator(
      staticPrivateKey: unhex(xx['initStatic']! as String),
      prologue: unhex(xx['initPrologue']! as String),
      testEphemeralPrivateKey: unhex(xx['initEphemeral']! as String),
    );
    final responder = await NoiseHandshake.responder(
      staticPrivateKey: unhex(xx['respStatic']! as String),
      prologue: unhex(xx['respPrologue']! as String),
      testEphemeralPrivateKey: unhex(xx['respEphemeral']! as String),
    );
    return (initiator, responder);
  }

  group('Noise XX against the official cacophony vector', () {
    test('protocol name matches the implemented suite', () {
      expect(xx['protocolName'], noiseProtocolName);
      expect(noiseProtocolName, 'Noise_XX_25519_ChaChaPoly_BLAKE2s');
    });

    test('handshake message 1 (-> e) matches byte for byte', () async {
      final (initiator, _) = await buildPair();

      final out = await initiator.writeMessage(
        unhex(messages[0]['payloadHex']! as String),
      );

      expect(hex(out), messages[0]['ciphertextHex']);
    });

    test(
      'handshake message 2 (<- e, ee, s, es) matches byte for byte',
      () async {
        final (initiator, responder) = await buildPair();

        await responder.readMessage(
          await initiator.writeMessage(
            unhex(messages[0]['payloadHex']! as String),
          ),
        );
        final out = await responder.writeMessage(
          unhex(messages[1]['payloadHex']! as String),
        );

        expect(hex(out), messages[1]['ciphertextHex']);
      },
    );

    test('handshake message 3 (-> s, se) matches byte for byte', () async {
      final (initiator, responder) = await buildPair();

      final m1 = await initiator.writeMessage(
        unhex(messages[0]['payloadHex']! as String),
      );
      await responder.readMessage(m1);
      final m2 = await responder.writeMessage(
        unhex(messages[1]['payloadHex']! as String),
      );
      await initiator.readMessage(m2);
      final m3 = await initiator.writeMessage(
        unhex(messages[2]['payloadHex']! as String),
      );

      expect(hex(m3), messages[2]['ciphertextHex']);
    });

    test('both sides derive the documented handshake hash', () async {
      final (initiator, responder) = await buildPair();

      final m1 = await initiator.writeMessage(
        unhex(messages[0]['payloadHex']! as String),
      );
      await responder.readMessage(m1);
      final m2 = await responder.writeMessage(
        unhex(messages[1]['payloadHex']! as String),
      );
      await initiator.readMessage(m2);
      final m3 = await initiator.writeMessage(
        unhex(messages[2]['payloadHex']! as String),
      );
      await responder.readMessage(m3);

      expect(hex(initiator.handshakeHash), xx['handshakeHash']);
      expect(hex(responder.handshakeHash), xx['handshakeHash']);
    });

    test('transport messages after the handshake match the vector', () async {
      final (initiator, responder) = await buildPair();

      final m1 = await initiator.writeMessage(
        unhex(messages[0]['payloadHex']! as String),
      );
      await responder.readMessage(m1);
      final m2 = await responder.writeMessage(
        unhex(messages[1]['payloadHex']! as String),
      );
      await initiator.readMessage(m2);
      final m3 = await initiator.writeMessage(
        unhex(messages[2]['payloadHex']! as String),
      );
      await responder.readMessage(m3);

      final initSession = await initiator.split();
      final respSession = await responder.split();

      // Alternation continues unbroken from message 0, so the first transport
      // message (index 3) travels responder -> initiator.
      for (var i = 3; i < messages.length; i++) {
        final payload = unhex(messages[i]['payloadHex']! as String);
        final expected = messages[i]['ciphertextHex']! as String;
        final fromInitiator = i.isEven;

        final sender = fromInitiator ? initSession : respSession;
        final receiver = fromInitiator ? respSession : initSession;

        final sealed = await sender.encrypt(payload);
        expect(hex(sealed), expected, reason: 'transport message $i mismatch');
        expect(await receiver.decrypt(sealed), payload);
      }
    });
  });

  group('Noise XX session behaviour', () {
    test('two freshly generated peers complete a handshake', () async {
      final initiator = await NoiseHandshake.initiator();
      final responder = await NoiseHandshake.responder();

      await responder.readMessage(await initiator.writeMessage(Uint8List(0)));
      await initiator.readMessage(await responder.writeMessage(Uint8List(0)));
      await responder.readMessage(await initiator.writeMessage(Uint8List(0)));

      expect(initiator.isComplete, isTrue);
      expect(responder.isComplete, isTrue);
      expect(hex(initiator.handshakeHash), hex(responder.handshakeHash));
    });

    test('each side learns the other static public key', () async {
      final initiator = await NoiseHandshake.initiator();
      final responder = await NoiseHandshake.responder();

      await responder.readMessage(await initiator.writeMessage(Uint8List(0)));
      await initiator.readMessage(await responder.writeMessage(Uint8List(0)));
      await responder.readMessage(await initiator.writeMessage(Uint8List(0)));

      expect(hex(initiator.remoteStaticKey!), hex(responder.localStaticKey));
      expect(hex(responder.remoteStaticKey!), hex(initiator.localStaticKey));
    });

    test('a session encrypts in both directions independently', () async {
      final (a, b) = await _completedPair();
      final up = Uint8List.fromList('to responder'.codeUnits);
      final down = Uint8List.fromList('to initiator'.codeUnits);

      expect(await b.decrypt(await a.encrypt(up)), up);
      expect(await a.decrypt(await b.encrypt(down)), down);
    });

    test('rejects a forged transport frame', () async {
      final (a, b) = await _completedPair();
      final sealed = await a.encrypt(Uint8List.fromList([1, 2, 3]));
      sealed[2] ^= 0xFF;

      expect(() => b.decrypt(sealed), throwsA(isA<DecryptFailure>()));
    });

    test('a handshake cannot be read out of order', () async {
      final initiator = await NoiseHandshake.initiator();

      await expectLater(
        () => initiator.readMessage(Uint8List(32)),
        throwsA(isA<StateError>()),
      );
    });

    test('split is refused before the handshake completes', () async {
      final initiator = await NoiseHandshake.initiator();

      await expectLater(() => initiator.split(), throwsA(isA<StateError>()));
    });

    test('rekeys after the configured message count', () async {
      final (a, b) = await _completedPair(rekeyAfterMessages: 3);

      for (var i = 0; i < 7; i++) {
        final body = Uint8List.fromList([i]);
        expect(await b.decrypt(await a.encrypt(body)), body);
      }

      expect(a.rekeyCount, greaterThan(0));
      expect(a.rekeyCount, b.rekeyCount);
    });
  });
}

Future<(NoiseSession, NoiseSession)> _completedPair({
  int rekeyAfterMessages = 100,
}) async {
  final initiator = await NoiseHandshake.initiator();
  final responder = await NoiseHandshake.responder();

  await responder.readMessage(await initiator.writeMessage(Uint8List(0)));
  await initiator.readMessage(await responder.writeMessage(Uint8List(0)));
  await responder.readMessage(await initiator.writeMessage(Uint8List(0)));

  return (
    await initiator.split(rekeyAfterMessages: rekeyAfterMessages),
    await responder.split(rekeyAfterMessages: rekeyAfterMessages),
  );
}
