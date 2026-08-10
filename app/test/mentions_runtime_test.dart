import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// A mention arriving over a real radio, in a real room.
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
    await alice.runtime.joinRoom('RUFF7A');
    await bob.runtime.joinRoom('RUFF7A');
    // Both introduce themselves, as the real app does on start. Without it
    // neither device knows the other's name, and a mention has nothing to
    // match against.
    await alice.runtime.announcePresence();
    await bob.runtime.announcePresence();
    await settle();
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  Future<void> deliver() async {
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();
  }

  test('being named in a room is flagged', () async {
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, 'hey @alice can you come');
    await deliver();

    final received = alice.state.conversations.single.messages.single;
    expect(received.mentionsYou, isTrue);
  });

  test('a message naming somebody else is not flagged', () async {
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, 'hey @carol can you come');
    await deliver();

    expect(
      alice.state.conversations.single.messages.single.mentionsYou,
      isFalse,
    );
  });

  test('an ordinary room message is not flagged', () async {
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, 'hello everyone');
    await deliver();

    expect(
      alice.state.conversations.single.messages.single.mentionsYou,
      isFalse,
    );
  });

  test('the name is matched however it was capitalised', () async {
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, 'hey @ALICE');
    await deliver();

    expect(
      alice.state.conversations.single.messages.single.mentionsYou,
      isTrue,
    );
  });

  test('our own message never counts as mentioning us', () async {
    // Otherwise quoting your own name lights up your own conversation.
    final room = alice.state.conversations.single;
    await alice.runtime.sendText(room.id, 'this is @alice speaking');
    await settle();

    expect(alice.state.conversations.single.hasMention, isFalse);
  });

  test('the conversation shows it was mentioned until it is read', () async {
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, '@alice look at this');
    await deliver();

    expect(alice.state.conversations.single.hasMention, isTrue);

    await alice.runtime.markConversationRead(
      alice.state.conversations.single.id,
    );
    await settle();

    expect(alice.state.conversations.single.hasMention, isFalse);
  });

  test('a room message says who sent it', () async {
    // Without this a group chat is a wall of anonymous text, and a mention has
    // no name to complete against.
    final room = bob.state.conversations.single;
    await bob.runtime.sendText(room.id, 'hello');
    await deliver();

    expect(alice.state.conversations.single.messages.single.senderName, 'bob');
  });

  test('the room offers the names of the people in it', () async {
    final aliceRoom = alice.state.conversations.single.id;

    expect(alice.runtime.mentionCandidatesFor(aliceRoom), contains('bob'));
  });

  test('the room never offers the user their own name', () async {
    // Nobody mentions themselves, and it is the one name in the list that
    // cannot possibly be useful.
    final aliceRoom = alice.state.conversations.single.id;
    expect(
      alice.runtime.mentionCandidatesFor(aliceRoom),
      isNot(contains('alice')),
    );
  });

  test('a direct conversation offers nothing', () async {
    await bob.runtime.announcePresence();
    final direct = await conversationOnceAnnounced(alice);

    expect(alice.runtime.mentionCandidatesFor(direct), isEmpty);
  });
}
