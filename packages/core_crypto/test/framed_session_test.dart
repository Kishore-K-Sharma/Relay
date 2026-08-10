import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:test/test.dart';

Uint8List seed(int fill) => Uint8List.fromList(List.filled(32, fill));

Future<(NoiseSession, NoiseSession)> pair() async {
  final initiator = await NoiseHandshake.initiator(staticPrivateKey: seed(1));
  final responder = await NoiseHandshake.responder(staticPrivateKey: seed(2));

  final m1 = await initiator.writeMessage(const []);
  await responder.readMessage(m1);
  final m2 = await responder.writeMessage(const []);
  await initiator.readMessage(m2);
  final m3 = await initiator.writeMessage(const []);
  await responder.readMessage(m3);

  return (await initiator.split(), await responder.split());
}

Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late NoiseSession alice;
  late NoiseSession bob;

  setUp(() async => (alice, bob) = await pair());

  test('a framed message round-trips', () async {
    final sealed = await alice.seal(bytes('hello'));

    expect(String.fromCharCodes(await bob.open(sealed)), 'hello');
  });

  test('the nonce travels with the message', () async {
    final sealed = await alice.seal(bytes('hello'));

    expect(sealed.length, 'hello'.length + explicitNonceLength + 16);
  });

  test('a lost message does not break the ones after it', () async {
    // The whole reason explicit nonces exist here. A mesh drops frames
    // constantly; an implicit counter would leave the receiver permanently one
    // step behind and every later message would fail to open.
    await alice.seal(bytes('lost in the crowd'));

    final next = await alice.seal(bytes('this one arrives'));

    expect(String.fromCharCodes(await bob.open(next)), 'this one arrives');
  });

  test('messages that arrive out of order both open', () async {
    final first = await alice.seal(bytes('one'));
    final second = await alice.seal(bytes('two'));

    expect(String.fromCharCodes(await bob.open(second)), 'two');
    expect(String.fromCharCodes(await bob.open(first)), 'one');
  });

  test('a replayed message is rejected', () async {
    final sealed = await alice.seal(bytes('spend once'));
    await bob.open(sealed);

    // Without this, anyone who overhears a frame can make it appear to arrive
    // again — "meet me at the gate" repeated an hour later.
    await expectLater(bob.open(sealed), throwsA(isA<ReplayedMessage>()));
  });

  test('a message older than the replay window is rejected', () async {
    final ancient = await alice.seal(bytes('very old'));

    for (var i = 0; i < replayWindowSize + 10; i++) {
      await bob.open(await alice.seal(bytes('filler $i')));
    }

    await expectLater(bob.open(ancient), throwsA(isA<ReplayedMessage>()));
  });

  test(
    'a tampered message is rejected and does not consume its nonce',
    () async {
      final sealed = await alice.seal(bytes('hello'));
      final forged = Uint8List.fromList(sealed);
      forged[forged.length - 1] ^= 0xFF;

      await expectLater(bob.open(forged), throwsA(isA<DecryptFailure>()));

      // The genuine message must still open. Otherwise anyone nearby could
      // silence a conversation by injecting one corrupted frame per message.
      expect(String.fromCharCodes(await bob.open(sealed)), 'hello');
    },
  );

  test('a truncated message is rejected', () async {
    await expectLater(bob.open(Uint8List(4)), throwsA(isA<DecryptFailure>()));
  });

  test('both directions are independent', () async {
    final toBob = await alice.seal(bytes('to bob'));
    final toAlice = await bob.seal(bytes('to alice'));

    expect(String.fromCharCodes(await bob.open(toBob)), 'to bob');
    expect(String.fromCharCodes(await alice.open(toAlice)), 'to alice');
  });

  test('a long conversation keeps working', () async {
    for (var i = 0; i < 500; i++) {
      final sealed = await alice.seal(bytes('message $i'));
      expect(String.fromCharCodes(await bob.open(sealed)), 'message $i');
    }
  });
}
