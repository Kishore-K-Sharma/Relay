import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// The 32-byte shortcut that tells a competing opening from an expected reply.
///
/// `SessionManager.receiveHandshake` distinguishes "you are also trying to open
/// a session with me" from "this is the message 2 I was waiting for" by length
/// alone: 32 bytes means message 1. `docs/SECURITY.md` §3.2 flagged this as the
/// sort of shortcut that works until somebody sends a 32-byte message 2, and
/// said plainly that we had not proved that impossible.
///
/// It is provable, and this file is the proof. Noise XX message 2 is
/// `e, ee, s, es`: an unencrypted ephemeral public key, then the static key
/// encrypted under a key agreed during that same message, then the payload.
/// The floor is 32 + (32 + 16) + 16 = 96 bytes with nothing carried at all —
/// three times the length of message 1, and it cannot shrink, because every
/// term in that sum is fixed by the pattern rather than by what is being sent.
///
/// The reason this needs a test rather than a comment: the bound holds for
/// *this* handshake pattern. Someone changing the pattern, the curve or the
/// AEAD tag length would be changing the arithmetic above without necessarily
/// looking at the line in `receiveHandshake` that depends on it.
void main() {
  Uint8List seed(int fill) => Uint8List.fromList(List.filled(32, fill));

  /// Runs a handshake far enough to produce message 2 for a given payload.
  Future<Uint8List> secondMessage(List<int> payload) async {
    final initiator = await NoiseHandshake.initiator(staticPrivateKey: seed(1));
    final responder = await NoiseHandshake.responder(staticPrivateKey: seed(2));

    await responder.readMessage(await initiator.writeMessage(const []));
    return responder.writeMessage(payload);
  }

  test('message 1 is exactly the length the shortcut assumes', () async {
    final initiator = await NoiseHandshake.initiator(staticPrivateKey: seed(1));

    expect(
      (await initiator.writeMessage(const [])).length,
      noiseFirstMessageLength,
    );
  });

  test('message 2 is never 32 bytes, whatever it carries', () async {
    // Zero first, because that is the only case where a "shorter message"
    // argument could plausibly reach 32 — and then a range, because a payload
    // can only ever make it longer.
    for (final size in [0, 1, 15, 16, 17, 64, 200]) {
      final message = await secondMessage(List<int>.filled(size, 0xAB));

      expect(
        message.length,
        isNot(noiseFirstMessageLength),
        reason:
            'a $size-byte payload produced a message 2 that message 1 '
            'cannot be told apart from',
      );
      expect(
        message.length,
        greaterThan(noiseFirstMessageLength),
        reason:
            'message 2 got shorter than message 1, which breaks the '
            'ordering the shortcut relies on',
      );
    }
  });

  test('message 2 has room to spare, not one byte', () async {
    // Stated as a floor rather than an exact length so that adding a payload
    // field does not fail this test spuriously. What matters is the margin: if
    // this ever drops towards 32, the shortcut is one protocol change away from
    // being wrong and `receiveHandshake` needs an explicit type byte instead.
    expect((await secondMessage(const [])).length, greaterThanOrEqualTo(96));
  });
}
