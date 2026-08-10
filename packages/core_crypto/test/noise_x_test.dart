import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:test/test.dart';

/// One-way Noise X, used to seal a message for somebody who is not there.
void main() {
  Uint8List secret(int fill) => Uint8List.fromList(List.filled(32, fill));

  late Uint8List recipientPrivate;
  late Uint8List recipientPublic;
  late Uint8List senderPrivate;
  late Uint8List senderPublic;

  setUp(() async {
    recipientPrivate = secret(7);
    senderPrivate = secret(9);
    recipientPublic = await publicKeyOf(recipientPrivate);
    senderPublic = await publicKeyOf(senderPrivate);
  });

  final message = Uint8List.fromList('meet me at the gate'.codeUnits);

  test('the recipient can open it', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    final opened = await NoiseX.open(
      recipientPrivate: recipientPrivate,
      sealed: sealed,
    );

    expect(opened!.payload, message);
  });

  test('the recipient learns who sent it', () async {
    // The sender may be long gone. Their identity has to ride inside the
    // envelope, or a delivered message is from nobody.
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    final opened = await NoiseX.open(
      recipientPrivate: recipientPrivate,
      sealed: sealed,
    );

    expect(opened!.senderStatic, senderPublic);
  });

  test('the sender\'s identity is not in the clear', () async {
    // A courier carrying this must not be able to see who wrote it.
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    expect(sealed, isNot(containsAllInOrder(senderPublic)));
  });

  test('nobody else can open it', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    expect(
      await NoiseX.open(recipientPrivate: secret(3), sealed: sealed),
      isNull,
    );
  });

  test('a courier cannot read what it carries', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    expect(sealed, isNot(containsAllInOrder(message)));
  });

  test('tampering is detected', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );
    sealed[sealed.length - 1] ^= 0xFF;

    expect(
      await NoiseX.open(recipientPrivate: recipientPrivate, sealed: sealed),
      isNull,
    );
  });

  test('a flipped bit anywhere is detected', () async {
    for (final index in [0, 20, 40, 70, 90]) {
      final sealed = await NoiseX.seal(
        senderPrivate: senderPrivate,
        recipientStatic: recipientPublic,
        payload: message,
      );
      if (index >= sealed.length) continue;
      sealed[index] ^= 0x01;

      expect(
        await NoiseX.open(recipientPrivate: recipientPrivate, sealed: sealed),
        isNull,
        reason: 'byte $index',
      );
    }
  });

  test('two seals of the same message differ', () async {
    // A fresh ephemeral every time. Identical ciphertext would let an observer
    // recognise a message being re-sent, and would break the store's use of
    // the ciphertext as an identity.
    final first = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );
    final second = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
    );

    expect(first, isNot(second));
  });

  test('rubbish is refused rather than throwing', () async {
    // A courier hands over everything it holds, so failing to open one is
    // routine, not exceptional.
    expect(
      await NoiseX.open(
        recipientPrivate: recipientPrivate,
        sealed: Uint8List(0),
      ),
      isNull,
    );
    expect(
      await NoiseX.open(
        recipientPrivate: recipientPrivate,
        sealed: Uint8List(50),
      ),
      isNull,
    );
    expect(
      await NoiseX.open(
        recipientPrivate: recipientPrivate,
        sealed: Uint8List.fromList(List.generate(200, (i) => i)),
      ),
      isNull,
    );
  });

  test('an empty payload still seals and opens', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: const [],
    );

    expect(
      (await NoiseX.open(
        recipientPrivate: recipientPrivate,
        sealed: sealed,
      ))!.payload,
      isEmpty,
    );
  });

  test('a different prologue does not open', () async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderPrivate,
      recipientStatic: recipientPublic,
      payload: message,
      prologue: const [1, 2, 3],
    );

    expect(
      await NoiseX.open(recipientPrivate: recipientPrivate, sealed: sealed),
      isNull,
    );
    expect(
      await NoiseX.open(
        recipientPrivate: recipientPrivate,
        sealed: sealed,
        prologue: const [1, 2, 3],
      ),
      isNotNull,
    );
  });
}
