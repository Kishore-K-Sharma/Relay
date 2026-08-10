import 'dart:convert';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// Compression happens inside the envelope, under the encryption.
///
/// Two reasons, and the second is the one that decided it. Compressing after
/// encryption is pointless — ciphertext is incompressible by construction. And
/// putting the "this was compressed" marker in the frame header, where the
/// protocol already has a spare flag bit, would publish to every relay in
/// earshot whether a given message was repetitive enough to shrink. That is a
/// small leak, but it is free to avoid.
void main() {
  Uint8List body(String text) => Uint8List.fromList(utf8.encode(text));

  AppEnvelope build(Uint8List payload, {int? voiceDurationMs}) =>
      AppEnvelope.build(
        senderKey: Uint8List.fromList([1, 2, 3, 4]),
        sequence: 9,
        body: payload,
        voiceDurationMs: voiceDurationMs,
      );

  test('a compressed body comes back byte for byte', () {
    final original = body('north gate at nine. ' * 40);

    final decoded = AppEnvelope.decode(build(original).encode());

    expect(decoded!.body, original);
  });

  test('a repetitive body really does travel smaller', () {
    final original = body('north gate at nine. ' * 40);

    final encoded = build(original).encode();

    expect(encoded.length, lessThan(original.length));
  });

  test('a short body is left alone', () {
    // Below the threshold the CPU cost and the risk of expansion outweigh a
    // saving of a few bytes.
    final original = body('on my way');

    final encoded = build(original).encode();

    expect(encoded.length, AppEnvelope.headerLength + original.length);
  });

  test('an incompressible body is not sent larger', () {
    final original = Uint8List.fromList(
      List.generate(600, (i) => (i * 37 + i * i) & 0xFF),
    );

    final encoded = build(original).encode();

    expect(
      encoded.length,
      lessThanOrEqualTo(AppEnvelope.headerLength + original.length),
    );
    expect(AppEnvelope.decode(encoded)!.body, original);
  });

  test('a voice note is not compressed a second time', () {
    // Opus output is already compressed. A second pass burns battery on a
    // phone and usually makes the payload bigger.
    final audio = Uint8List.fromList(
      List.generate(600, (i) => (i * 91) & 0xFF),
    );

    final envelope = build(audio, voiceDurationMs: 3000);

    expect(envelope.compressed, isFalse);
    expect(AppEnvelope.decode(envelope.encode())!.body, audio);
  });

  test('the sender key, sequence and duration survive compression', () {
    final envelope = build(body('x' * 500), voiceDurationMs: null);

    final decoded = AppEnvelope.decode(envelope.encode())!;

    expect(decoded.senderKey, [1, 2, 3, 4]);
    expect(decoded.sequence, 9);
    expect(decoded.voiceDurationMs, isNull);
  });

  test('a truncated envelope decodes to nothing rather than throwing', () {
    expect(AppEnvelope.decode(Uint8List(3)), isNull);
  });

  test('an envelope claiming compression it does not have is refused', () {
    // Reached only by a peer that is lying or corrupt. Returning null drops the
    // message; throwing here would take down the inbound chain.
    final encoded = build(body('on my way')).encode();
    encoded[AppEnvelope.headerLength - 1] = 1; // set the compressed flag

    expect(AppEnvelope.decode(encoded), isNull);
  });

  test('every body length from 0 to 400 round trips', () {
    for (var length = 0; length <= 400; length++) {
      final original = Uint8List.fromList(
        List.generate(length, (i) => 0x41 + (i % 5)),
      );

      expect(
        AppEnvelope.decode(build(original).encode())!.body,
        original,
        reason: 'length $length',
      );
    }
  });

  test('the frame header flag is not used to signal compression', () {
    // If this ever becomes true, the leak described at the top of this file is
    // back and every relay can see which messages were compressible.
    const flags = FrameFlags(encrypted: true);

    expect(flags.compressed, isFalse);
  });

  group('padding', () {
    const policy = PaddingPolicy();

    test('two messages of very different lengths look the same size', () {
      // The claim the whole feature rests on. Encryption hides what was said;
      // only this hides how much.
      final short = policy.pad(build(body('ok')).encode());
      final longer = policy.pad(
        build(body('on my way, see you there')).encode(),
      );

      expect(short.length, longer.length);
    });

    test('a padded envelope still decodes', () {
      final original = body('north gate at nine');

      final decoded = AppEnvelope.decode(
        policy.strip(policy.pad(build(original).encode())),
      );

      expect(decoded!.body, original);
    });

    test('compression happens before padding, not after', () {
      // The other order would pad first and then compress the filler away,
      // which restores exactly the length signal padding exists to remove.
      final repetitive = body('north gate at nine. ' * 40);
      final random = Uint8List.fromList(
        List.generate(800, (i) => (i * 2654435761) & 0xFF),
      );

      final compressible = policy.pad(build(repetitive).encode());
      final incompressible = policy.pad(build(random).encode());

      expect(compressible.length, lessThan(incompressible.length));
    });
  });
}
