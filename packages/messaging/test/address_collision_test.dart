import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// What happens when two people share one 32-bit address hash.
///
/// `addressHashOf` truncates BLAKE2s to 32 bits, so collisions are certain at
/// scale and possible at any size. `docs/SECURITY.md` §4.7 listed the behaviour
/// as un-analysed. These tests establish what it actually is, because the
/// question that matters is not how likely a collision is but what it costs
/// when it happens.
///
/// The answer these pin down: a collision is a **denial of service between the
/// two colliding parties, and nothing worse**. Sessions are keyed by hash, so
/// the second party to arrive cannot open the first party's session — the
/// authentication tag fails, exactly as it would for an attacker. What must
/// never happen is that a message from one is silently attributed to the other,
/// and that is what the AEAD prevents: reachability degrades, confidentiality
/// does not.
///
/// The collision is applied at the interface rather than searched for. Finding
/// two keys that genuinely collide in 32 bits takes about 2^16 hashes by the
/// birthday bound — feasible, but it would make this file slow and
/// non-deterministic to prove something the caller can simply assert. To every
/// layer below the routing table, "two peers under one hash" is precisely this.
void main() {
  Uint8List seed(int fill) => Uint8List.fromList(List.filled(32, fill));
  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  /// Completes a handshake between [local] and a remote party, both of which
  /// address each other by [hash].
  Future<void> connect(
    SessionManager local,
    SessionManager remote,
    int hash,
  ) async {
    final m1 = await local.beginHandshake(hash);
    final m2 = await remote.receiveHandshake(hash, m1);
    final m3 = await local.receiveHandshake(hash, m2!);
    await remote.receiveHandshake(hash, m3!);
  }

  const collidingHash = 0x1234ABCD;

  late SessionManager us;
  late SessionManager first;
  late SessionManager second;

  setUp(() {
    us = SessionManager(staticPrivateKey: seed(1), localAddressHash: 0xFFFF);
    first = SessionManager(staticPrivateKey: seed(2), localAddressHash: 0x0001);
    second = SessionManager(
      staticPrivateKey: seed(3),
      localAddressHash: 0x0002,
    );
  });

  test('a message from the colliding stranger does not open', () async {
    await connect(us, first, collidingHash);

    // The second party seals something under a session we never agreed to.
    final other = SessionManager(
      staticPrivateKey: seed(9),
      localAddressHash: 0x0003,
    );
    await connect(other, second, collidingHash);
    final foreign = await second.encrypt(collidingHash, bytes('wrong person'));

    // It must fail, not decrypt to something, and not be attributed to the
    // person we do have a session with.
    await expectLater(
      us.decrypt(collidingHash, foreign),
      throwsA(isA<DecryptFailure>()),
    );
  });

  test('the genuine peer keeps working after the collision', () async {
    await connect(us, first, collidingHash);

    final other = SessionManager(
      staticPrivateKey: seed(9),
      localAddressHash: 0x0003,
    );
    await connect(other, second, collidingHash);
    final foreign = await second.encrypt(collidingHash, bytes('wrong person'));
    await expectLater(
      us.decrypt(collidingHash, foreign),
      throwsA(isA<DecryptFailure>()),
    );

    // A collision must not be a way to silence somebody. If a failed open
    // advanced the replay window or tore the session down, anyone able to
    // guess a hash could cut a conversation by sending one junk frame.
    final genuine = await first.encrypt(collidingHash, bytes('still here'));

    expect(
      String.fromCharCodes(await us.decrypt(collidingHash, genuine)),
      'still here',
    );
  });

  test('an opening message alone does not replace the session', () async {
    await connect(us, first, collidingHash);
    final established = us.remoteStaticKey(collidingHash);

    final intruder = SessionManager(
      staticPrivateKey: seed(4),
      localAddressHash: 0x0005,
    );
    await us.receiveHandshake(
      collidingHash,
      await intruder.beginHandshake(0xFFFF),
    );

    // Half a handshake changes nothing. See the test below for what a whole
    // one does, which is the part that matters.
    expect(us.remoteStaticKey(collidingHash), established);
  });

  test(
    'OPEN FINDING: a completed unsolicited handshake displaces the session',
    () async {
      // Documented rather than asserted-away. `docs/SECURITY.md` §4.7 carries
      // this as an open finding: a completed Noise XX handshake offered at an
      // established peer's address hash replaces that session, after which the
      // genuine peer's messages stop opening.
      //
      // Reachable by anyone in radio range, because the address hash is
      // broadcast in the clear in every presence beacon — it needs no collision
      // and no guessing. It is a denial of service, not a disclosure: the
      // intruder gets a session with us under their own key and cannot read
      // anything sealed to the old one.
      //
      // This test exists to fail loudly the moment the behaviour changes, so
      // that a fix is noticed and the finding is struck from the document.
      // It is not an endorsement of the behaviour.
      await connect(us, first, collidingHash);
      final established = us.remoteStaticKey(collidingHash);

      final intruder = SessionManager(
        staticPrivateKey: seed(7),
        localAddressHash: 0x0009,
      );
      final i1 = await intruder.beginHandshake(0xFFFF);
      final i2 = await us.receiveHandshake(collidingHash, i1);
      final i3 = await intruder.receiveHandshake(0xFFFF, i2!);
      await us.receiveHandshake(collidingHash, i3!);

      expect(
        us.remoteStaticKey(collidingHash),
        isNot(established),
        reason: 'if this now passes, the session survived — fix the doc',
      );

      final genuine = await first.encrypt(collidingHash, bytes('still here'));
      await expectLater(
        us.decrypt(collidingHash, genuine),
        throwsA(isA<DecryptFailure>()),
        reason: 'if this now opens, the finding is fixed — fix the doc',
      );
    },
  );

  test('forgetting one party clears the slot entirely', () async {
    // There is one slot per hash, so recovery from a collision is necessarily
    // all-or-nothing. Worth pinning so nobody assumes a partial forget exists.
    await connect(us, first, collidingHash);
    expect(us.stateFor(collidingHash), SessionState.established);

    us.forget(collidingHash);

    expect(us.stateFor(collidingHash), SessionState.none);
    expect(us.remoteStaticKey(collidingHash), isNull);
  });
}
