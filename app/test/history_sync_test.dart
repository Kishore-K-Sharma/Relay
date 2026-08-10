import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Catching up on a group you have just joined.
///
/// Without this, joining a room shows an empty screen while everyone else is
/// mid-conversation, and the only way to find out what was said is to ask
/// somebody to repeat it.
///
/// The privacy consequence is stated in the room reminder and in
/// `docs/SECURITY.md`: anyone who obtains the code gets not only everything
/// said from now on — which was always true — but a bounded window of what was
/// said before they arrived.
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

  Future<void> deliver([int ms = 300]) async {
    await settle();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await settle();
  }

  List<String> bodiesIn(Device device, String conversationId) => [
    for (final message in device.state.conversation(conversationId)!.messages)
      message.body,
  ];

  test('joining a room shows what was said before you arrived', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'we are on the roof');
    await alice.runtime.sendText(room.conversationId, 'bring water');
    await deliver();

    final joined = await bob.runtime.joinRoom('RUFF7A');
    await deliver(2500);

    expect(bodiesIn(bob, joined.conversationId), [
      'we are on the roof',
      'bring water',
    ]);
  });

  test('catching up does not mark everything unread', () async {
    // Unread means "arrived while you were not looking". These predate the
    // user entirely, and a badge reading 100 on a room they have just joined
    // is noise, not information.
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'earlier');
    await deliver();

    final joined = await bob.runtime.joinRoom('RUFF7A');
    await deliver(2500);

    expect(bob.state.conversation(joined.conversationId)!.unread, 0);
  });

  test('catching up twice does not duplicate anything', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'once only');
    await deliver();

    final joined = await bob.runtime.joinRoom('RUFF7A');
    await deliver(2500);
    await bob.runtime.requestRoomHistory(joined.conversationId);
    await deliver(2500);

    expect(bodiesIn(bob, joined.conversationId), ['once only']);
  });

  test('somebody outside the room cannot answer or read the answer', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'members only');
    await deliver();

    final carol = await Device.create('carol', network);
    addTearDown(carol.dispose);
    final other = await carol.runtime.joinRoom('ZEBRA7');
    await deliver(2500);

    expect(bodiesIn(carol, other.conversationId), isEmpty);
  });

  test(
    'a request is answered after a pause, so a crowd does not all reply',
    () async {
      // Twenty phones answering the same request at the same instant would drown
      // the room in duplicate history. Each waits a random moment first.
      final room = await alice.runtime.joinRoom('RUFF7A');
      await alice.runtime.sendText(room.conversationId, 'something');
      await deliver();

      await bob.runtime.joinRoom('RUFF7A');
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settle();

      expect(alice.runtime.hasPendingHistoryReply(room.roomId), isTrue);
    },
  );

  test('hearing someone else answer cancels our own reply', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'something');
    await deliver();

    final carol = await Device.create('carol', network);
    addTearDown(carol.dispose);
    await carol.runtime.joinRoom('RUFF7A');
    await deliver(2500);

    // Both alice and carol are in the room. Whoever answered first, neither is
    // still sitting on a queued reply afterwards.
    expect(alice.runtime.hasPendingHistoryReply(room.roomId), isFalse);
    expect(carol.runtime.hasPendingHistoryReply(room.roomId), isFalse);
  });

  test('stealth mode does not ask', () async {
    // A request announces that this device has just joined a particular room.
    // Stealth mode exists to stop exactly that kind of statement.
    await alice.runtime.setStealth(true);

    final joined = await alice.runtime.joinRoom('RUFF7A');
    await settle();

    expect(alice.runtime.hasPendingHistoryRequest(joined.roomId), isFalse);
  });

  test('leaving a room stops us answering for it', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'private');
    await deliver();
    alice.runtime.leaveRoom(room.conversationId);

    final joined = await bob.runtime.joinRoom('RUFF7A');
    await deliver(2500);

    expect(bob.state.conversation(joined.conversationId)?.messages, isEmpty);
  });
}
