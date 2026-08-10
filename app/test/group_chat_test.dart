import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Group chat with more than two people in it.
///
/// The existing room tests use two devices, which is enough to prove the key
/// derivation and the cipher and nothing about the thing a group actually is.
/// A group is a broadcast: one person speaks and everybody hears, including
/// people the sender has never handshaked with and does not know are there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLanNetwork network;
  late Device alice;
  late Device bob;
  late Device carol;

  const code = 'FEST24';

  /// Test clock, so the outbox backoff can be stepped over rather than slept
  /// through. Everything else in this file runs on real time, because the
  /// sockets underneath are real.
  var now = DateTime(2026, 7, 26, 12);

  setUp(() async {
    now = DateTime(2026, 7, 26, 12);
    network = FakeLanNetwork();
    alice = await Device.create('alice', network, clock: () => now);
    bob = await Device.create('bob', network, clock: () => now);
    carol = await Device.create('carol', network, clock: () => now);

    await until(
      () =>
          alice.wifi.linkCount == 2 &&
          bob.wifi.linkCount == 2 &&
          carol.wifi.linkCount == 2,
      'three devices to link to each other',
    );
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  /// Everyone joins [code] and ends up with the same room.
  Future<void> joinAll(List<Device> devices) async {
    for (final device in devices) {
      await device.runtime.joinRoom(code);
    }
  }

  /// The bodies of every message in [device]'s copy of the room.
  List<String> roomMessages(Device device) => [
    for (final conversation in device.state.conversations)
      if (conversation.title == code)
        for (final message in conversation.messages) message.body,
  ];

  Future<void> awaitMessage(Device device, String body) => until(
    () => roomMessages(device).contains(body),
    '"$body" to reach ${device.state.nickname}',
  );

  test('one person speaks and everybody in the group hears', () async {
    await joinAll([alice, bob, carol]);

    final room = await alice.runtime.joinRoom(code);
    await alice.runtime.sendText(room.conversationId, 'we are by the flag');

    await awaitMessage(bob, 'we are by the flag');
    await awaitMessage(carol, 'we are by the flag');
  });

  test('everyone can speak, not just whoever started it', () async {
    // A room has no owner and no join order. Nothing in the design makes the
    // first member special, and a test that only ever sends one direction
    // would not notice if something did.
    await joinAll([alice, bob, carol]);

    await bob.runtime.sendText(
      (await bob.runtime.joinRoom(code)).conversationId,
      'bring water',
    );

    await awaitMessage(alice, 'bring water');
    await awaitMessage(carol, 'bring water');
  });

  test('a conversation holds everything said, in order', () async {
    await joinAll([alice, bob, carol]);
    final aliceRoom = (await alice.runtime.joinRoom(code)).conversationId;
    final bobRoom = (await bob.runtime.joinRoom(code)).conversationId;

    await alice.runtime.sendText(aliceRoom, 'first');
    await awaitMessage(carol, 'first');
    await bob.runtime.sendText(bobRoom, 'second');
    await awaitMessage(carol, 'second');

    expect(roomMessages(carol), ['first', 'second']);
  });

  test('everyone derives the same room from the same code', () async {
    // The room id is derived from the code, not agreed between devices. If two
    // phones derived different ids they would each sit in an empty room and
    // never know why.
    final fromAlice = await alice.runtime.joinRoom(code);
    final fromCarol = await carol.runtime.joinRoom(code);

    expect(fromAlice.roomId, fromCarol.roomId);
    expect(fromAlice.conversationId, fromCarol.conversationId);
  });

  test('the code is case and whitespace insensitive', () async {
    // It gets read aloud in a noisy place and typed by someone in a hurry.
    final typed = await alice.runtime.joinRoom('  fest24 ');

    expect(typed.roomId, (await bob.runtime.joinRoom(code)).roomId);
  });

  test('someone outside the group cannot read it', () async {
    await joinAll([alice, bob]);
    await carol.runtime.joinRoom('ZEBRA7');

    await alice.runtime.sendText(
      (await alice.runtime.joinRoom(code)).conversationId,
      'we are by the flag',
    );
    await awaitMessage(bob, 'we are by the flag');

    // Carol received the frame — it is a broadcast, she is on the network —
    // and could not open it. Anything else means the room key does nothing.
    expect(
      carol.state.conversations.expand((c) => c.messages).map((m) => m.body),
      isNot(contains('we are by the flag')),
    );
  });

  test('a device in no group at all still carries the traffic', () async {
    // This is what makes a mesh work. A phone that only forwarded messages it
    // could read would leave everyone else's group broken.
    await joinAll([alice, bob]);

    final relayed = <int>[];
    carol.wifi.inbound.listen((frame) => relayed.addAll(frame.bytes));

    await alice.runtime.sendText(
      (await alice.runtime.joinRoom(code)).conversationId,
      'we are by the flag',
    );
    await awaitMessage(bob, 'we are by the flag');

    expect(relayed, isNotEmpty);
  });

  test('leaving a group stops it being readable', () async {
    await joinAll([alice, bob, carol]);
    final aliceRoom = (await alice.runtime.joinRoom(code)).conversationId;
    await alice.runtime.sendText(aliceRoom, 'first');
    await awaitMessage(carol, 'first');

    carol.runtime.leaveRoom(
      (await carol.runtime.joinRoom(code)).conversationId,
    );
    await alice.runtime.sendText(aliceRoom, 'second');
    await awaitMessage(bob, 'second');

    expect(roomMessages(carol), isNot(contains('second')));
  });

  test('a group message is never reported as delivered', () async {
    // There is no single recipient to speak for the group, so nothing acks a
    // room message. Showing a delivery tick would be inventing a confirmation
    // nobody sent — the exact dishonesty this product exists to avoid.
    await joinAll([alice, bob, carol]);
    final room = (await alice.runtime.joinRoom(code)).conversationId;

    await alice.runtime.sendText(room, 'we are by the flag');
    await awaitMessage(bob, 'we are by the flag');
    await settle();

    final sent = alice.state
        .conversation(room)!
        .messages
        .firstWhere((m) => m.fromMe);
    expect(sent.state.isConfirmed, isFalse);
  });

  test('nothing readable from a group crosses the wire', () async {
    await joinAll([alice, bob]);

    final captured = <int>[];
    carol.wifi.inbound.listen((frame) => captured.addAll(frame.bytes));

    await alice.runtime.sendText(
      (await alice.runtime.joinRoom(code)).conversationId,
      'we are by the flag',
    );
    await awaitMessage(bob, 'we are by the flag');

    expect(
      String.fromCharCodes(captured.where((b) => b >= 32 && b < 127)),
      isNot(contains('by the flag')),
    );
  });

  test('a message spoken into an empty group is retried, not lost', () async {
    // Somebody creates a group and types into it before anyone has joined. The
    // frame goes out and nobody can open it — a room has no handshake to wait
    // on, so there is nothing to tell the sender to hold back. What has to
    // happen is that the outbox keeps it and tries again.
    final room = (await alice.runtime.joinRoom(code)).conversationId;
    await alice.runtime.sendText(room, 'anyone here');
    await settle();
    expect(roomMessages(bob), isEmpty);

    await joinAll([bob]);
    // Past the backoff for a first attempt. Without this the retry is not due
    // and the test would prove only that nothing happens immediately.
    now = now.add(const Duration(minutes: 5));
    await alice.runtime.retryPending();

    await awaitMessage(bob, 'anyone here');
  });
}
