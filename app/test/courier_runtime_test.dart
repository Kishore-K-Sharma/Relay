import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_identity/core_identity.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart' as db;
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:transport_wifi/testing.dart';

import 'package:relay_app/src/runtime/runtime.dart';

import 'support/mesh_devices.dart';

/// Carrying somebody else's message to them.
///
/// A courier moves a message the mesh could not: the sender and the recipient
/// are never in the same place, so a third device holds the sealed envelope
/// until it meets them. That device can read none of it, and — because
/// carrying mail costs storage and battery, and every phone in range can ask —
/// most of the rules here are about refusing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLanNetwork network;
  late Device alice;
  late Device bob;

  /// The sender whose mail gets carried. Never a party to a handover here —
  /// that is the point of a courier.
  late Device carol;

  setUp(() async {
    network = FakeLanNetwork();
    alice = await Device.create('alice', network);
    bob = await Device.create('bob', network);
    carol = await Device.create('carol', network);
    await until(
      () => alice.wifi.linkCount == 2 && bob.wifi.linkCount == 2,
      'the devices to link',
    );
    // Everyone announces, because everything here turns on having heard the
    // other side's Noise key — which only an announce carries.
    await alice.runtime.announcePresence();
    await bob.runtime.announcePresence();
    await carol.runtime.announcePresence();
    await conversationOnceAnnounced(alice);
    await conversationOnceAnnounced(bob);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  /// An envelope from Carol to Bob, which only Alice will ever touch.
  Future<CourierEnvelope> carolToBob({int copies = 1}) async =>
      CourierSeal.build(
        senderNoisePrivate: carol.noiseKey,
        recipientNoiseStatic: await bob.runtime.noiseStaticPublicKey,
        payload: AppEnvelope.build(
          senderKey: Uint8List.sublistView(
            carol.runtime.identity.publicKey,
            0,
            4,
          ),
          sequence: 1,
          body: Uint8List.fromList('bring water'.codeUnits),
        ).encode(),
        now: DateTime.now(),
        copies: copies,
      );

  /// Mail from Carol to somebody who is not here, so a device that receives it
  /// can only carry it — never open it, never deliver it.
  Future<CourierEnvelope> carolToAbsent({int copies = 1}) async =>
      CourierSeal.build(
        senderNoisePrivate: carol.noiseKey,
        recipientNoiseStatic: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
        payload: AppEnvelope.build(
          senderKey: Uint8List.sublistView(
            carol.runtime.identity.publicKey,
            0,
            4,
          ),
          sequence: 1,
          body: Uint8List.fromList('meet at the gate'.codeUnits),
        ).encode(),
        now: DateTime.now(),
        copies: copies,
      );

  group('publishing a Noise key', () {
    test('an announce carries it', () async {
      // Without this nothing can be sealed for somebody out of reach, because
      // the key mail is encrypted to would never have been transmitted.
      await until(
        () => alice.store.noiseKeyFor(bob.runtime.identity.publicKey) != null,
        'bob\'s Noise key to arrive',
      );

      expect(
        alice.store.noiseKeyFor(bob.runtime.identity.publicKey),
        await bob.runtime.noiseStaticPublicKey,
      );
    });

    test('it is not the identity key', () async {
      await until(
        () => alice.store.noiseKeyFor(bob.runtime.identity.publicKey) != null,
        'bob\'s Noise key to arrive',
      );

      expect(
        alice.store.noiseKeyFor(bob.runtime.identity.publicKey),
        isNot(bob.runtime.identity.publicKey),
      );
    });

    test('overhearing one does not make somebody a contact', () async {
      await until(
        () => alice.store.noiseKeyFor(bob.runtime.identity.publicKey) != null,
        'bob\'s Noise key to arrive',
      );

      expect(alice.store.contacts(), isEmpty);
    });
  });

  group('delivering', () {
    test('mail is handed over when its recipient appears', () async {
      // Carol gave Alice this envelope. Alice has now met Bob, who is the one
      // it is for.
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(
        () => _bodies(bob).contains('bring water'),
        'the message to reach bob',
      );
    });

    test('a delivered envelope is no longer carried', () async {
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );
      expect(alice.runtime.couriers.count, 1);

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(
        () => alice.runtime.couriers.count == 0,
        'alice to let go of the delivered envelope',
      );
    });

    test('the carrier never sees what it delivered', () async {
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(
        () => _bodies(bob).contains('bring water'),
        'the message to reach bob',
      );

      expect(_bodies(alice), isNot(contains('bring water')));
    });

    test('it is marked as having been carried', () async {
      // A message that waited hours in somebody's pocket and one that crossed
      // the room in 40 milliseconds look identical once the envelope is open.
      // The reader is entitled to know which one they are answering.
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(
        () => _bodies(bob).contains('bring water'),
        'the message to reach bob',
      );

      final carried = [
        for (final conversation in bob.store.conversations())
          for (final message in bob.store.messages(conversation.id))
            if (message.body == 'bring water') message,
      ].single;
      expect(carried.viaCourier, isTrue);
    });

    test('an ordinary radio message is not marked as carried', () async {
      // Guards the label's meaning. If everything is flagged, the flag says
      // nothing and the user learns to ignore it.
      final conversation = await conversationOnceAnnounced(alice);
      await alice.runtime.sendText(conversation, 'straight over the air');

      await until(
        () => _bodies(bob).contains('straight over the air'),
        'the direct message to arrive',
      );

      final direct = [
        for (final c in bob.store.conversations())
          for (final message in bob.store.messages(c.id))
            if (message.body == 'straight over the air') message,
      ].single;
      expect(direct.viaCourier, isFalse);
    });

    test('it is filed under the sender, not the carrier', () async {
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(
        () => _bodies(bob).contains('bring water'),
        'the message to reach bob',
      );

      final expected = bob.runtime.conversationIdForAddress(
        await addressHashOf(carol.runtime.identity.publicKey),
      );
      expect([
        for (final message in bob.store.messages(expected)) message.body,
      ], contains('bring water'));
    });

    test('mail from somebody never heard of is dropped', () async {
      // The envelope names its sender by a Noise key. With no announce ever
      // received there is nobody to attribute it to, and showing a message
      // from nobody is worse than showing nothing.
      await alice.runtime.carryMail(
        await CourierSeal.build(
          senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
          recipientNoiseStatic: await bob.runtime.noiseStaticPublicKey,
          payload: AppEnvelope.build(
            senderKey: Uint8List.fromList([7, 7, 7, 7]),
            sequence: 1,
            body: Uint8List.fromList('from a ghost'.codeUnits),
          ).encode(),
          now: DateTime.now(),
        ),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await settle();

      expect(_bodies(bob), isNot(contains('from a ghost')));
    });
  });

  group('originating', () {
    test('a message for someone out of reach is given to a carrier', () async {
      // Alice writes to Dave, who is nowhere. Bob is here, and the two have
      // each chosen the other, so Bob agrees to take it.
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      final dave = Uint8List.fromList(List.filled(32, 5));
      alice.store.saveNoiseKey(
        publicKey: dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );

      final carriers = await alice.runtime.depositWithCouriers(
        recipientIdentityKey: dave,
        body: 'meet at the gate',
      );

      expect(carriers, 1);
      await until(
        () => bob.runtime.couriers.count == 1,
        'bob to take the envelope',
      );
    });

    test('nothing is sent for somebody whose Noise key is unknown', () async {
      // Sealing needs their key. Guessing, or falling back to the signing key,
      // would produce mail nobody can ever open.
      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      expect(
        await alice.runtime.depositWithCouriers(
          recipientIdentityKey: Uint8List.fromList(List.filled(32, 5)),
          body: 'meet at the gate',
        ),
        0,
      );
    });

    test('a stranger is not asked to carry anything', () async {
      // Bob is neither favourited nor verified. Handing mail to whoever is
      // nearby would tell every passer-by that this device is talking to
      // somebody, and how often.
      final dave = Uint8List.fromList(List.filled(32, 5));
      alice.store.saveNoiseKey(
        publicKey: dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );

      expect(
        await alice.runtime.depositWithCouriers(
          recipientIdentityKey: dave,
          body: 'meet at the gate',
        ),
        0,
      );
    });
  });

  group('accepting other people\'s mail', () {
    test('a favourite\'s mail is carried', () async {
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      final dave = Uint8List.fromList(List.filled(32, 5));
      alice.store.saveNoiseKey(
        publicKey: dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );
      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      await alice.runtime.depositWithCouriers(
        recipientIdentityKey: dave,
        body: 'meet at the gate',
      );

      await until(() => bob.runtime.couriers.count == 1, 'bob to carry it');
    });

    test('a stranger\'s mail is refused', () async {
      // Alice is nothing to Bob. Carrying for anyone in range is a free
      // disk-filling attack on every phone in a crowd.
      final dave = Uint8List.fromList(List.filled(32, 5));
      alice.store.saveNoiseKey(
        publicKey: dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );
      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      await alice.runtime.depositWithCouriers(
        recipientIdentityKey: dave,
        body: 'meet at the gate',
      );

      await settle();
      expect(bob.runtime.couriers.count, 0);
    });

    test('a verified peer\'s mail is carried on the smaller tier', () async {
      bob.store.saveContact(
        publicKey: alice.runtime.identity.publicKey,
        nickname: 'alice',
        trust: db.TrustState.verified,
      );
      final dave = Uint8List.fromList(List.filled(32, 5));
      alice.store.saveNoiseKey(
        publicKey: dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );
      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      await alice.runtime.depositWithCouriers(
        recipientIdentityKey: dave,
        body: 'meet at the gate',
      );

      await until(() => bob.runtime.couriers.count == 1, 'bob to carry it');
      expect(bob.store.couriered().single.tier, CourierTier.verified.name);
    });
  });

  group('spraying', () {
    test('a copy goes to a favourite carrier, halving the budget', () async {
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await alice.runtime.carryMail(
        await CourierSeal.build(
          senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
          recipientNoiseStatic: await publicKeyOf(
            Uint8List.fromList(List.filled(32, 6)),
          ),
          payload: Uint8List.fromList('bring water'.codeUnits),
          now: DateTime.now(),
          copies: 4,
        ),
        depositor: Uint8List.fromList(List.filled(32, 7)),
        tier: CourierTier.favourite,
      );

      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.offerMail(await _peerIdFor(alice, bob));

      await until(() => bob.runtime.couriers.count == 1, 'bob to take a copy');
      expect(bob.store.couriered().single.copies, 2);
      expect(alice.store.couriered().single.copies, 2);
    });

    test('a carry-only envelope is never sprayed', () async {
      // One copy means "carry this to them", not "hand it around". Splitting
      // it would leave two devices each believing they hold the last copy.
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.carryMail(
        await CourierSeal.build(
          senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
          recipientNoiseStatic: await publicKeyOf(
            Uint8List.fromList(List.filled(32, 6)),
          ),
          payload: Uint8List.fromList('bring water'.codeUnits),
          now: DateTime.now(),
        ),
        depositor: Uint8List.fromList(List.filled(32, 7)),
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await settle();

      expect(bob.runtime.couriers.count, 0);
      expect(alice.store.couriered().single.copies, 1);
    });

    test('meeting the same carrier twice does not spray twice', () async {
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.carryMail(
        await CourierSeal.build(
          senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
          recipientNoiseStatic: await publicKeyOf(
            Uint8List.fromList(List.filled(32, 6)),
          ),
          payload: Uint8List.fromList('bring water'.codeUnits),
          now: DateTime.now(),
          copies: 4,
        ),
        depositor: Uint8List.fromList(List.filled(32, 7)),
        tier: CourierTier.favourite,
      );

      final peerId = await _peerIdFor(alice, bob);
      await alice.runtime.offerMail(peerId);
      await until(() => bob.runtime.couriers.count == 1, 'the first spray');

      await alice.runtime.offerMail(peerId);
      await settle();

      expect(
        alice.store.couriered().single.copies,
        2,
        reason: 'a second encounter must not drain the budget again',
      );
    });

    test('mail is never sprayed back to the person who deposited it', () async {
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.carryMail(
        await CourierSeal.build(
          senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
          recipientNoiseStatic: await publicKeyOf(
            Uint8List.fromList(List.filled(32, 6)),
          ),
          payload: Uint8List.fromList('bring water'.codeUnits),
          now: DateTime.now(),
          copies: 4,
        ),
        depositor: bob.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await settle();

      expect(bob.runtime.couriers.count, 0);
    });
  });

  test('stealth mode carries and offers nothing', () async {
    // Stealth means this device is not transmitting. Handing mail over is
    // transmitting, and doing it anyway would make the setting a lie.
    await alice.runtime.favourite(bob.runtime.identity.publicKey);
    await bob.runtime.favourite(alice.runtime.identity.publicKey);
    await alice.runtime.carryMail(
      await CourierSeal.build(
        senderNoisePrivate: Uint8List.fromList(List.filled(32, 7)),
        recipientNoiseStatic: await bob.runtime.noiseStaticPublicKey,
        payload: Uint8List.fromList('bring water'.codeUnits),
        now: DateTime.now(),
        copies: 4,
      ),
      depositor: Uint8List.fromList(List.filled(32, 7)),
      tier: CourierTier.favourite,
    );

    await alice.runtime.setStealth(true);
    await alice.runtime.offerMail(await _peerIdFor(alice, bob));
    await settle();

    expect(_bodies(bob), isNot(contains('bring water')));
    expect(alice.runtime.couriers.count, 1);
  });

  /// The path the user actually takes: a message that has not got through, and
  /// a button offering to have somebody walk it there.
  ///
  /// Everything below `depositWithCouriers` was reachable only from tests until
  /// this existed. A feature that cannot be invoked from the product is not a
  /// feature.
  group('sending by courier from a conversation', () {
    test('a direct message is handed to a nearby carrier', () async {
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      alice.store.saveNoiseKey(
        publicKey: _dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );
      alice.store.upsertConversation(
        id: 'dave',
        kind: db.ConversationKind.direct,
        title: 'Dave',
        peerKey: _dave,
      );

      final result = await alice.runtime.sendByCourier(
        conversationId: 'dave',
        body: 'meet at the gate',
      );

      expect(result.refusal, isNull);
      expect(result.carriers, 1);
    });

    test('a room says so rather than failing vaguely', () async {
      // An envelope is sealed to exactly one recipient's key.
      alice.store.upsertConversation(
        id: 'r1',
        kind: db.ConversationKind.room,
        title: 'Rooftop',
      );

      final result = await alice.runtime.sendByCourier(
        conversationId: 'r1',
        body: 'meet at the gate',
      );

      expect(result.refusal, CourierRefusal.notADirectMessage);
    });

    test('somebody never met is named as the reason', () async {
      // Without their announce there is no X25519 key to seal to, and no
      // fallback: a guess produces mail nobody can ever open.
      alice.store.upsertConversation(
        id: 'stranger',
        kind: db.ConversationKind.direct,
        title: 'Stranger',
        peerKey: Uint8List.fromList(List.filled(32, 9)),
      );

      final result = await alice.runtime.sendByCourier(
        conversationId: 'stranger',
        body: 'meet at the gate',
      );

      expect(result.refusal, CourierRefusal.recipientKeyUnknown);
    });

    test(
      'nobody trusted nearby is distinguished from nobody to seal to',
      () async {
        // Different situations, different next moves: one resolves by walking
        // near a friend, the other only by meeting the recipient once.
        alice.store.saveNoiseKey(
          publicKey: _dave,
          noiseStaticKey: await publicKeyOf(
            Uint8List.fromList(List.filled(32, 6)),
          ),
        );
        alice.store.upsertConversation(
          id: 'dave',
          kind: db.ConversationKind.direct,
          title: 'Dave',
          peerKey: _dave,
        );

        final result = await alice.runtime.sendByCourier(
          conversationId: 'dave',
          body: 'meet at the gate',
        );

        expect(result.refusal, CourierRefusal.noCarriers);
      },
    );

    test('stealth mode refuses out loud', () async {
      await alice.runtime.setStealth(true);
      alice.store.upsertConversation(
        id: 'dave',
        kind: db.ConversationKind.direct,
        title: 'Dave',
        peerKey: _dave,
      );

      final result = await alice.runtime.sendByCourier(
        conversationId: 'dave',
        body: 'meet at the gate',
      );

      expect(result.refusal, CourierRefusal.stealth);
    });
  });

  /// Carrying other people's mail costs this device storage and battery, and
  /// the user never asked for it. So it has an off switch, and the switch has
  /// to mean something more specific than "stop".
  group('turning carrying off', () {
    test('no new mail is accepted', () async {
      await bob.runtime.setCarryForOthers(false);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      await alice.runtime.carryMail(
        await carolToAbsent(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );
      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await settle();

      expect(bob.runtime.couriers.count, 0);
    });

    test('mail already held is still delivered', () async {
      // Refusing to hand over a message to the person it is addressed to would
      // be pure loss: the copy is already on this device, delivering it costs
      // one transmission, and it is the only way that message ever arrives.
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );
      await alice.runtime.setCarryForOthers(false);

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await until(() => _bodies(bob).contains('bring water'), 'delivery');
    });

    test('nothing is sprayed onward', () async {
      await alice.runtime.carryMail(
        await carolToAbsent(copies: 4),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      await alice.runtime.setCarryForOthers(false);

      await alice.runtime.offerMail(await _peerIdFor(alice, bob));
      await settle();

      expect(bob.runtime.couriers.count, 0);
    });

    test('this device can still post its own mail', () async {
      // The switch is about carrying for other people. Refusing to let the
      // user send their own message by courier would be a different setting,
      // and a surprising one to find under this label.
      await alice.runtime.setCarryForOthers(false);
      await bob.runtime.favourite(alice.runtime.identity.publicKey);
      await alice.runtime.favourite(bob.runtime.identity.publicKey);
      alice.store.saveNoiseKey(
        publicKey: _dave,
        noiseStaticKey: await publicKeyOf(
          Uint8List.fromList(List.filled(32, 6)),
        ),
      );

      final carriers = await alice.runtime.depositWithCouriers(
        recipientIdentityKey: _dave,
        body: 'meet at the gate',
      );

      expect(carriers, 1);
    });

    test('the user can drop what is already held', () async {
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );
      expect(alice.runtime.couriers.count, 1);

      alice.runtime.dropCarriedMail();

      expect(alice.runtime.couriers.count, 0);
    });

    test('dropping does not touch this device\'s own conversations', () async {
      // The button says "drop what I am carrying for other people". If it also
      // deleted the user's own messages that would be a data-loss bug wearing
      // a reasonable label.
      await alice.runtime.sendText(
        await conversationOnceAnnounced(alice),
        'mine',
      );
      await alice.runtime.carryMail(
        await carolToBob(),
        depositor: carol.runtime.identity.publicKey,
        tier: CourierTier.favourite,
      );

      alice.runtime.dropCarriedMail();

      expect(_bodies(alice), contains('mine'));
    });
  });
}

/// A third party who is never present, so mail for them has to be carried.
final Uint8List _dave = Uint8List.fromList(List.filled(32, 5));

/// The radio peer id [from] knows [other] by.
Future<String> _peerIdFor(Device from, Device other) async {
  final wanted = await addressHashOf(other.runtime.identity.publicKey);
  late String found;
  await until(() {
    for (final peer in from.state.peers) {
      if (from.runtime.addressForPeer(peer.id) == wanted) {
        found = peer.id;
        return true;
      }
    }
    return false;
  }, 'a peer id for the other device');
  return found;
}

List<String> _bodies(Device device) => [
  for (final conversation in device.store.conversations())
    for (final message in device.store.messages(conversation.id)) message.body,
];
