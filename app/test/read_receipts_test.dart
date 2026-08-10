import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/domain/models.dart' as ui;
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Read receipts, which the app has always been able to display and has never
/// been able to produce.
///
/// `MessageState.read` existed, the double tick existed, `markRead` existed —
/// and nothing ever put a read receipt on a wire, so the state was unreachable.
/// A state the UI can render and the protocol cannot reach is worse than a
/// missing feature: it looks finished.
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

  /// Alice sends [body] to Bob and waits for it to land.
  Future<String> aliceSends(String body) async {
    await bob.runtime.announcePresence();
    final conversation = await conversationOnceAnnounced(alice);
    await alice.runtime.sendText(conversation, body);
    await until(
      () => bob.state.conversations.any(
        (c) => c.messages.any((m) => m.body == body),
      ),
      '"$body" to reach bob',
    );
    return conversation;
  }

  ui.Message sentMessage(Device device, String conversationId) => device.state
      .conversation(conversationId)!
      .messages
      .firstWhere((m) => m.fromMe);

  test('a message is delivered but not read until it is opened', () async {
    final conversation = await aliceSends('north gate at nine');
    await settle();

    // Delivered means the device acked it. Read means a person looked at it.
    // Collapsing the two would be a claim nobody made.
    expect(sentMessage(alice, conversation).state, ui.MessageState.delivered);
  });

  test('opening the conversation tells the sender it was read', () async {
    final conversation = await aliceSends('north gate at nine');
    await settle();

    final bobConversation = bob.state.conversations.firstWhere(
      (c) => c.messages.any((m) => !m.fromMe),
    );
    await bob.runtime.markConversationRead(bobConversation.id);

    await until(
      () => sentMessage(alice, conversation).state == ui.MessageState.read,
      'alice to see the read receipt',
    );
  });

  test('reading the newest message marks the earlier ones read too', () async {
    // Reading message five means you saw one to four above it. Leaving them on
    // "delivered" would show a conversation the user has plainly read as half
    // unread.
    final conversation = await aliceSends('first');
    await aliceSends('second');
    await aliceSends('third');
    await settle();

    final bobConversation = bob.state.conversations.firstWhere(
      (c) => c.messages.any((m) => !m.fromMe),
    );
    await bob.runtime.markConversationRead(bobConversation.id);

    await until(
      () => alice.state
          .conversation(conversation)!
          .messages
          .where((m) => m.fromMe)
          .every((m) => m.state == ui.MessageState.read),
      'every message alice sent to be marked read',
    );
  });

  test('a read receipt never moves a message backwards', () async {
    // Receipts can arrive out of order over a mesh. A late delivery ack must
    // not un-read a message the user has watched turn read.
    final conversation = await aliceSends('north gate at nine');
    final bobConversation = bob.state.conversations.firstWhere(
      (c) => c.messages.any((m) => !m.fromMe),
    );
    await bob.runtime.markConversationRead(bobConversation.id);
    await until(
      () => sentMessage(alice, conversation).state == ui.MessageState.read,
      'the read receipt',
    );

    await bob.runtime.markConversationRead(bobConversation.id);
    await settle();

    expect(sentMessage(alice, conversation).state, ui.MessageState.read);
  });

  test(
    'reading a conversation with nothing from the peer sends nothing',
    () async {
      // An empty conversation, or one containing only our own messages, has
      // nothing to acknowledge. Sending a receipt naming no message would be a
      // frame of pure noise on a battery-constrained radio.
      await bob.runtime.announcePresence();
      final conversation = await conversationOnceAnnounced(alice);

      await alice.runtime.markConversationRead(conversation);
      await settle();

      expect(
        alice.state.conversation(conversation)?.messages ?? const [],
        isEmpty,
      );
    },
  );

  test('marking read clears the unread count locally', () async {
    await aliceSends('north gate at nine');
    await settle();
    final bobConversation = bob.state.conversations.firstWhere(
      (c) => c.messages.any((m) => !m.fromMe),
    );
    expect(bob.state.conversation(bobConversation.id)!.unread, greaterThan(0));

    await bob.runtime.markConversationRead(bobConversation.id);
    await settle();

    expect(bob.state.conversation(bobConversation.id)!.unread, 0);
  });

  test('a group message is never marked read', () async {
    // A room has many readers and no single one speaks for the group. There is
    // no honest way to say "read", so nothing claims it.
    final room = await alice.runtime.joinRoom('FEST24');
    await bob.runtime.joinRoom('FEST24');
    await alice.runtime.sendText(room.conversationId, 'we are by the flag');
    await until(
      () => bob.state.conversations.any(
        (c) => c.messages.any((m) => m.body == 'we are by the flag'),
      ),
      'the room message to arrive',
    );

    await bob.runtime.markConversationRead(room.conversationId);
    await settle();

    expect(
      sentMessage(alice, room.conversationId).state,
      isNot(ui.MessageState.read),
    );
  });
}
