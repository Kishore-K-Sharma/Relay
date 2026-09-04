import 'dart:convert';
import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/domain/announce_trust.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// The one frame this app puts on the air in the clear, and the only thing
/// standing behind everything it claims.
///
/// An announce says "this nickname, this identity key, and this is the X25519
/// key to seal my mail to". Every one of those is acted on: the nickname names
/// a conversation, the identity key decides whether somebody is trusted enough
/// to be handed other people's mail, and the Noise key is what a courier
/// envelope is sealed to. Unsigned, all three are assertions by whoever happens
/// to be holding a radio.
void main() {
  late FakeLanNetwork network;

  setUp(() => network = FakeLanNetwork());

  group('what a device puts on the air', () {
    test('the beacon native rebroadcasts is the frame Dart sends', () async {
      // The regression this exists for: native holds its own copy of the
      // beacon and rebroadcasts it on a timer with no Dart alive, so it is the
      // announce a peer met later actually hears. It used to be handed the
      // identity key alone — no Noise key, no signature — so the periodic
      // beacon and the Dart announce were two different frames, and couriering
      // only worked for a peer who happened to be in range during one of the
      // four moments Dart announced by itself.
      //
      // Native supplies the length-prefixed nickname and appends the blob
      // verbatim. That reassembly has to parse as a complete announce, or the
      // two sides have drifted again.
      final alice = await Device.create('Alice', network);
      addTearDown(alice.dispose);

      final beacon = await alice.runtime.presenceBeacon();
      final name = utf8.encode(beacon.nickname);
      final assembled = Uint8List.fromList([
        name.length,
        ...name,
        ...beacon.keyBlob,
      ]);

      final decoded = Announce.decode(assembled)!;
      expect(decoded.nickname, 'Alice');
      expect(decoded.noiseStaticKey, isNotNull, reason: 'no key to courier to');
      expect(decoded.signature, isNotNull, reason: 'nothing to verify it with');
      expect(
        await checkAnnounce(decoded, assembled),
        AnnounceTrust.signed,
        reason: 'native would broadcast a beacon nobody will believe',
      );
    });

    test('the nickname is cut before it is signed, not after', () async {
      // Native appends the blob to a nickname it does not re-cut, because the
      // signature covers those exact bytes. So the truncation has to have
      // happened by the time the name is handed over — and it has to be on a
      // character boundary, or the name arrives with a replacement glyph in it
      // on every device in range.
      final device = await Device.create('ज़' * 40, network);
      addTearDown(device.dispose);

      final beacon = await device.runtime.presenceBeacon();

      expect(beacon.nickname.length, lessThan(('ज़' * 40).length));
      expect(beacon.nickname, isNot(contains('�')));
    });
  });

  group('what a device believes', () {
    /// Alice's genuine announce, and the bytes it arrived as.
    Future<({Announce announce, Uint8List payload})> honest(
      Device device,
    ) async {
      final beacon = await device.runtime.presenceBeacon();
      final name = utf8.encode(beacon.nickname);
      final payload = Uint8List.fromList([
        name.length,
        ...name,
        ...beacon.keyBlob,
      ]);
      return (announce: Announce.decode(payload)!, payload: payload);
    }

    test('a genuine announce verifies', () async {
      final alice = await Device.create('Alice', network);
      addTearDown(alice.dispose);

      final it = await honest(alice);
      expect(
        await checkAnnounce(it.announce, it.payload),
        AnnounceTrust.signed,
      );
    });

    test('a Noise key swapped under a real identity is forged', () async {
      // The attack the signature exists for. An identity key is public, so
      // Mallory can rebroadcast Alice's beside her *own* X25519 key; anyone who
      // believed it would seal Alice's mail to Mallory. Verification does not
      // help on its own — it covers the identity key, and nothing binds the
      // Noise key to it except this signature.
      final alice = await Device.create('Alice', network);
      final mallory = await Device.create('Mallory', network);
      addTearDown(alice.dispose);
      addTearDown(mallory.dispose);

      final hers = await honest(alice);
      final theirs = await honest(mallory);

      final swapped = Announce(
        nickname: hers.announce.nickname,
        identityKey: hers.announce.identityKey,
        noiseStaticKey: theirs.announce.noiseStaticKey,
        // Alice's real signature, over Alice's real keys — but no longer over
        // the bytes it is now attached to.
        signature: hers.announce.signature,
      );

      expect(
        await checkAnnounce(swapped, swapped.encode()),
        AnnounceTrust.forged,
      );
    });

    test('a signature by the wrong key is forged', () async {
      final alice = await Device.create('Alice', network);
      addTearDown(alice.dispose);

      final hers = await honest(alice);
      final impostor = await MeshIdentity.generate();

      final forged = hers.announce.withSignature(
        await impostor.sign(
          Announce.signingInput(hers.announce.encodeUnsigned()),
        ),
      );

      expect(
        await checkAnnounce(forged, forged.encode()),
        AnnounceTrust.forged,
      );
    });

    test('an unsigned announce is unattributable, not hostile', () async {
      // Not an attack — a build that predates the field, or another program on
      // the same radio. It still says something true, that a device is in
      // range, so it is not dropped. It just cannot support a claim about who.
      final alice = await Device.create('Alice', network);
      addTearDown(alice.dispose);

      final hers = await honest(alice);
      final unsigned = Announce(
        nickname: hers.announce.nickname,
        identityKey: hers.announce.identityKey,
        noiseStaticKey: hers.announce.noiseStaticKey,
      );

      expect(
        await checkAnnounce(unsigned, unsigned.encode()),
        AnnounceTrust.unsigned,
      );
    });
  });
}
