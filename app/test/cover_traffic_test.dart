import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Cover traffic against a real stack.
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
    await alice.runtime.announcePresence();
    await bob.runtime.announcePresence();
    await settle();
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

  /// Gets a Noise session going, which cover traffic requires.
  Future<String> talk() async {
    final conversation = await conversationOnceAnnounced(alice);
    await alice.runtime.sendText(conversation, 'hello');
    await deliver();
    return conversation;
  }

  test('it is off unless asked for', () async {
    expect(alice.runtime.coverTraffic.enabled, isFalse);
    expect(await alice.runtime.sendCoverFrame(), isFalse);
  });

  test('a dummy frame goes out once there is somebody to send it to', () async {
    await talk();
    alice.runtime.setCoverTraffic(true);

    expect(await alice.runtime.sendCoverFrame(), isTrue);
  });

  test('a dummy never appears as a message', () async {
    // The entire point. If it showed up, it would be a bug the user could see
    // and an observer could count.
    final conversation = await talk();
    alice.runtime.setCoverTraffic(true);

    await alice.runtime.sendCoverFrame();
    await deliver();

    final bobsMessages = bob.state.conversations
        .expand((c) => c.messages)
        .map((m) => m.body)
        .toList();
    expect(bobsMessages, ['hello']);
    expect(
      alice.state.conversation(conversation)!.messages.map((m) => m.body),
      ['hello'],
    );
  });

  test('a dummy is never acknowledged', () async {
    // An ack would identify the real frames immediately, which would leave the
    // cost and remove the benefit.
    await talk();
    alice.runtime.setCoverTraffic(true);
    final before = alice.store.messages(alice.state.conversations.single.id);

    await alice.runtime.sendCoverFrame();
    await deliver();

    expect(
      alice.store.messages(alice.state.conversations.single.id).length,
      before.length,
    );
  });

  test('nothing is sent to someone we have never spoken to', () async {
    // Opening a session purely to send noise would introduce this device to a
    // stranger — the opposite of the intent.
    alice.runtime.setCoverTraffic(true);

    expect(await alice.runtime.sendCoverFrame(), isFalse);
  });

  test('nothing is sent to somebody blocked', () async {
    await talk();
    await alice.runtime.block(bob.runtime.identity.publicKey);
    alice.runtime.setCoverTraffic(true);

    expect(await alice.runtime.sendCoverFrame(), isFalse);
  });

  test('switching it off stops it', () async {
    await talk();
    alice.runtime.setCoverTraffic(true);
    alice.runtime.setCoverTraffic(false);

    expect(alice.runtime.coverTraffic.enabled, isFalse);
    expect(await alice.runtime.sendCoverFrame(), isFalse);
  });

  test('real messages still arrive with cover on', () async {
    // The jitter must delay messages, not lose them.
    final conversation = await talk();
    alice.runtime.setCoverTraffic(true);

    await alice.runtime.sendText(conversation, 'still works');
    await deliver(800);

    expect(
      bob.state.conversations.expand((c) => c.messages).map((m) => m.body),
      contains('still works'),
    );
  });
}
