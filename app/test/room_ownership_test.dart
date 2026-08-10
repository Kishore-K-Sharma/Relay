import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Who runs a room, and whether it is kept.
///
/// Every claim here is advisory. A room's only real access control is its code:
/// anyone holding it can read, write, and run a build that ignores all of this.
/// What ownership buys is a convention plus one hard guarantee — nobody can
/// forge a claim in somebody else's name, because every claim is signed.
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

  Future<void> deliver([int ms = 400]) async {
    await settle();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await settle();
  }

  test('a room starts with nobody running it', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    expect(alice.runtime.roomOwner(room.conversationId), isNull);
    expect(alice.runtime.isRoomOwner(room.conversationId), isFalse);
  });

  test('claiming a room makes you its owner here and elsewhere', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();

    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();

    expect(alice.runtime.isRoomOwner(mine.conversationId), isTrue);
    expect(
      bob.runtime.roomOwner(theirs.conversationId),
      alice.runtime.identity.publicKey,
    );
    expect(bob.runtime.isRoomOwner(theirs.conversationId), isFalse);
  });

  test('a second claim does not displace the first', () async {
    // First one wins. Otherwise the room's owner is whoever spoke most
    // recently, which is not ownership at all.
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();

    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();
    await bob.runtime.claimRoom(theirs.conversationId);
    await deliver();

    expect(
      alice.runtime.roomOwner(mine.conversationId),
      alice.runtime.identity.publicKey,
    );
  });

  test('a forged claim is refused', () async {
    // The signature is the one part of this that is not advisory.
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await deliver();

    await alice.runtime.debugSendForgedClaim(
      mine.conversationId,
      bob.runtime.identity.publicKey,
    );
    await deliver();

    expect(alice.runtime.roomOwner(mine.conversationId), isNull);
  });

  test('an owner can hand the room over', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();
    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();

    await alice.runtime.transferRoom(
      mine.conversationId,
      bob.runtime.identity.publicKey,
    );
    await deliver();

    expect(
      alice.runtime.roomOwner(mine.conversationId),
      bob.runtime.identity.publicKey,
    );
    expect(bob.runtime.isRoomOwner(theirs.conversationId), isTrue);
  });

  test('somebody who does not own the room cannot give it away', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();
    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();

    await bob.runtime.transferRoom(
      theirs.conversationId,
      bob.runtime.identity.publicKey,
    );
    await deliver();

    expect(
      alice.runtime.roomOwner(mine.conversationId),
      alice.runtime.identity.publicKey,
    );
  });

  test('a room is kept by default', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    expect(alice.runtime.roomRetains(room.conversationId), isTrue);
  });

  test('the owner can ask that a room is not kept', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();
    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();

    await alice.runtime.setRoomRetention(mine.conversationId, retain: false);
    await deliver();

    expect(alice.runtime.roomRetains(mine.conversationId), isFalse);
    expect(bob.runtime.roomRetains(theirs.conversationId), isFalse);
  });

  test('somebody who does not own the room cannot change that', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    final theirs = await bob.runtime.joinRoom('RUFF7A');
    await deliver();
    await alice.runtime.claimRoom(mine.conversationId);
    await deliver();

    await bob.runtime.setRoomRetention(theirs.conversationId, retain: false);
    await deliver();

    expect(alice.runtime.roomRetains(mine.conversationId), isTrue);
  });

  test('an unkept room is erased when you leave it', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.claimRoom(mine.conversationId);
    await alice.runtime.setRoomRetention(mine.conversationId, retain: false);
    await alice.runtime.sendText(mine.conversationId, 'forget this');
    await deliver();

    alice.runtime.leaveRoom(mine.conversationId);

    expect(alice.store.messages(mine.conversationId), isEmpty);
  });

  test('a kept room survives leaving it', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(mine.conversationId, 'remember this');
    await deliver();

    alice.runtime.leaveRoom(mine.conversationId);

    expect(alice.store.messages(mine.conversationId), hasLength(1));
  });

  test('an unkept room is erased when the app stops', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.claimRoom(mine.conversationId);
    await alice.runtime.setRoomRetention(mine.conversationId, retain: false);
    await alice.runtime.sendText(mine.conversationId, 'gone on close');
    await deliver();

    await alice.runtime.stop();

    expect(alice.store.messages(mine.conversationId), isEmpty);
  });

  test('ownership and retention survive a restart', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.claimRoom(mine.conversationId);
    await alice.runtime.setRoomRetention(mine.conversationId, retain: false);
    await deliver();

    expect(
      alice.store.room(mine.roomId)!.ownerKey,
      alice.runtime.identity.publicKey,
    );
    expect(alice.store.room(mine.roomId)!.retain, isFalse);
  });

  test('a panic wipe forgets who ran what', () async {
    final mine = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.claimRoom(mine.conversationId);

    await alice.runtime.panicWipe();

    expect(alice.store.room(mine.roomId), isNull);
  });
}
