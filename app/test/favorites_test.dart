import 'package:data/data.dart' as db;
import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Favourites.
///
/// A favourite is a person the user has deliberately chosen, and that choice
/// buys three things they do not get by default:
///
///  1. **The internet relay.** Relaying leaks metadata to a third party — that
///     two identities are talking, and when. Doing that for every stranger who
///     walked past would be a poor trade; doing it for someone the user picked
///     is what makes the relay useful at all.
///  2. **A longer retry window.** An ordinary message gives up after a day. A
///     favourite's is kept for a week, because "I'll see them next week" is a
///     normal thing to be true of someone you chose and not of a stranger.
///  3. **A place in the list.** Favourites stay visible when out of range, so
///     there is somewhere to write to them, and they sort above everyone else.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLanNetwork network;
  late Device alice;
  late Device bob;

  setUp(() async {
    network = FakeLanNetwork();
    alice = await Device.create('alice', network);
    bob = await Device.create('bob', network);
    await until(
      () => alice.wifi.linkCount == 1 && bob.wifi.linkCount == 1,
      'the two devices to link',
    );
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  test('favouriting someone is remembered', () async {
    await alice.runtime.favourite(
      bob.runtime.identity.publicKey,
      nickname: 'bob',
    );

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isTrue);
    expect(alice.store.favourites().single.nickname, 'bob');
  });

  test('favouriting works before there is any contact row', () async {
    // The user can star someone the moment they appear, long before anyone has
    // scanned a code. Requiring verification first would make the feature
    // unreachable in exactly the situation it is for.
    await alice.runtime.favourite(bob.runtime.identity.publicKey);

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isTrue);
  });

  test('verifying someone later keeps their favourite', () async {
    await alice.runtime.favourite(bob.runtime.identity.publicKey);

    alice.store.saveContact(
      publicKey: bob.runtime.identity.publicKey,
      nickname: 'bob',
      trust: db.TrustState.verified,
    );

    expect(
      alice.store.isFavourite(bob.runtime.identity.publicKey),
      isTrue,
      reason: 'saving a contact must not clobber a flag it knows nothing about',
    );
  });

  test('unfavouriting removes it', () async {
    await alice.runtime.favourite(bob.runtime.identity.publicKey);
    await alice.runtime.unfavourite(bob.runtime.identity.publicKey);

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isFalse);
    expect(alice.store.favourites(), isEmpty);
  });

  test('blocking someone drops the favourite', () async {
    // The two contradict. Leaving both set would mean the relay policy and the
    // block disagreed about the same person, and one of them would win by
    // accident rather than by decision.
    await alice.runtime.favourite(bob.runtime.identity.publicKey);
    await alice.runtime.block(bob.runtime.identity.publicKey);

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isFalse);
  });

  test(
    'the relay is offered to favourites and withheld from strangers',
    () async {
      await bob.runtime.announcePresence();
      await conversationOnceAnnounced(alice);
      final hash = bob.runtime.localAddressHash;

      expect(alice.runtime.relayAllowedFor(hash), isFalse);

      await alice.runtime.favourite(bob.runtime.identity.publicKey);

      expect(alice.runtime.relayAllowedFor(hash), isTrue);
    },
  );

  test('a favourite is retried for a week, a stranger for a day', () async {
    await bob.runtime.announcePresence();
    await conversationOnceAnnounced(alice);

    expect(
      alice.runtime.retryWindowFor(bob.runtime.localAddressHash),
      const Duration(hours: 24),
    );

    await alice.runtime.favourite(bob.runtime.identity.publicKey);

    expect(
      alice.runtime.retryWindowFor(bob.runtime.localAddressHash),
      const Duration(days: 7),
    );
  });

  test('a favourite stays in the list after they go out of range', () async {
    await bob.runtime.announcePresence();
    // Waiting for the announce rather than for the link. A peer exists the
    // instant the socket connects, before anyone has said who they are, and at
    // that point the app cannot yet tell that this peer is the favourite.
    await conversationOnceAnnounced(alice);
    await alice.runtime.favourite(
      bob.runtime.identity.publicKey,
      nickname: 'bob',
    );

    alice.runtime.handlePeerLost(alice.state.peers.single.id);
    await settle();

    final peer = alice.state.peers.single;
    expect(peer.nickname, 'bob');
    expect(peer.isFavourite, isTrue);
    expect(
      peer.isReachable,
      isFalse,
      reason: 'still listed, but the app must not pretend they are nearby',
    );
  });

  test('an unfavourited peer who is out of range disappears', () async {
    await bob.runtime.announcePresence();
    await conversationOnceAnnounced(alice);
    await alice.runtime.favourite(bob.runtime.identity.publicKey);
    alice.runtime.handlePeerLost(alice.state.peers.single.id);
    await settle();

    await alice.runtime.unfavourite(bob.runtime.identity.publicKey);
    await settle();

    expect(alice.state.peers, isEmpty);
  });

  test('favourites sort above everyone else', () async {
    await bob.runtime.announcePresence();
    await conversationOnceAnnounced(alice);

    final carol = await Device.create('carol', network);
    addTearDown(carol.dispose);
    await carol.runtime.announcePresence();
    await until(() => alice.state.peers.length == 2, 'carol to appear');

    await alice.runtime.favourite(
      carol.runtime.identity.publicKey,
      nickname: 'carol',
    );
    await settle();

    expect(alice.state.peers.first.nickname, 'carol');
  });

  test('a panic wipe clears favourites with everything else', () async {
    await alice.runtime.favourite(bob.runtime.identity.publicKey);

    await alice.runtime.panicWipe();

    expect(alice.store.favourites(), isEmpty);
    expect(
      alice.runtime.relayAllowedFor(bob.runtime.localAddressHash),
      isFalse,
    );
  });
}
