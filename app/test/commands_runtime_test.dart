import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Commands doing what they say, against a real stack.
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

  test('plain text is sent as a message', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    final outcome = await alice.runtime.runCommand(
      'hello everyone',
      conversationId: room.conversationId,
    );
    await deliver();

    expect(outcome.notice, isNull);
    expect(
      alice.state.conversation(room.conversationId)!.messages.single.body,
      'hello everyone',
    );
  });

  test('/join joins a group and opens it', () async {
    final outcome = await alice.runtime.runCommand(
      '/join RUFF7A',
      conversationId: '',
    );

    expect(outcome.openConversation, isNotNull);
    expect(alice.state.conversation(outcome.openConversation!), isNotNull);
  });

  test('/join says so plainly when the code is not a code', () async {
    final outcome = await alice.runtime.runCommand(
      '/join NOTACODE!!',
      conversationId: '',
    );

    expect(outcome.notice, isNotNull);
    expect(outcome.openConversation, isNull);
  });

  test('/who lists people in range by name', () async {
    final outcome = await alice.runtime.runCommand('/who', conversationId: '');

    expect(outcome.notice, contains('bob'));
  });

  test('/who is honest when nobody is there', () async {
    final carol = await Device.create('carol', FakeLanNetwork());
    addTearDown(carol.dispose);

    final outcome = await carol.runtime.runCommand('/who', conversationId: '');

    expect(outcome.notice, contains('Nobody'));
  });

  test('/channels lists the groups you are in', () async {
    await alice.runtime.joinRoom('RUFF7A');

    final outcome = await alice.runtime.runCommand(
      '/channels',
      conversationId: '',
    );

    expect(outcome.notice, contains('RUFF7A'));
  });

  test('/msg opens a conversation with somebody by name', () async {
    final outcome = await alice.runtime.runCommand(
      '/msg bob are you there',
      conversationId: '',
    );
    await deliver();

    expect(outcome.openConversation, isNotNull);
    expect(
      alice.state.conversation(outcome.openConversation!)!.messages.single.body,
      'are you there',
    );
  });

  test('/msg to a name nobody has says so', () async {
    final outcome = await alice.runtime.runCommand(
      '/msg nobody hello',
      conversationId: '',
    );

    expect(outcome.notice, contains('nobody'));
    expect(outcome.openConversation, isNull);
  });

  test('/block and /unblock work by name', () async {
    await alice.runtime.runCommand('/block bob', conversationId: '');

    expect(alice.store.isBlocked(bob.runtime.identity.publicKey), isTrue);

    await alice.runtime.runCommand('/unblock bob', conversationId: '');

    expect(alice.store.isBlocked(bob.runtime.identity.publicKey), isFalse);
  });

  test('/fav and /unfav work by name', () async {
    await alice.runtime.runCommand('/fav bob', conversationId: '');

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isTrue);

    await alice.runtime.runCommand('/unfav bob', conversationId: '');

    expect(alice.store.isFavourite(bob.runtime.identity.publicKey), isFalse);
  });

  test('/clear erases this conversation on this phone only', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');
    await alice.runtime.sendText(room.conversationId, 'forget me');
    await deliver();

    await alice.runtime.runCommand(
      '/clear',
      conversationId: room.conversationId,
    );

    expect(alice.store.messages(room.conversationId), isEmpty);
    // The other device is untouched; nothing was asked of it.
    expect(bob.state.conversations, isEmpty);
  });

  test('/nick changes your name and re-announces it', () async {
    await alice.runtime.runCommand('/nick zara', conversationId: '');
    await deliver();

    expect(alice.state.nickname, 'zara');
    expect(bob.runtime.mentionCandidatesFor(''), isEmpty);
    await until(
      () => bob.state.peers.any((p) => p.nickname == 'zara'),
      'bob to learn the new name',
    );
  });

  test('/claim and /save run the room', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    await alice.runtime.runCommand(
      '/claim',
      conversationId: room.conversationId,
    );
    await alice.runtime.runCommand(
      '/save off',
      conversationId: room.conversationId,
    );

    expect(alice.runtime.isRoomOwner(room.conversationId), isTrue);
    expect(alice.runtime.roomRetains(room.conversationId), isFalse);
  });

  test('/save with no argument reports rather than changes', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    final outcome = await alice.runtime.runCommand(
      '/save',
      conversationId: room.conversationId,
    );

    expect(outcome.notice, isNotNull);
    expect(alice.runtime.roomRetains(room.conversationId), isTrue);
  });

  test('room commands refuse to run outside a room', () async {
    final outcome = await alice.runtime.runCommand(
      '/claim',
      conversationId: '',
    );

    expect(outcome.notice, contains('group'));
  });

  test(
    '/pass announces the new code rather than moving people silently',
    () async {
      // Deliberately not automatic. Re-keying everyone on a remote instruction
      // means anyone who takes the owner's key can move the whole group without
      // a soul noticing. A visible message the members act on cannot.
      final room = await alice.runtime.joinRoom('RUFF7A');
      await alice.runtime.runCommand(
        '/claim',
        conversationId: room.conversationId,
      );
      await bob.runtime.joinRoom('RUFF7A');
      await deliver();

      await alice.runtime.runCommand(
        '/pass ZEBRA7',
        conversationId: room.conversationId,
      );
      await deliver();

      final heard = bob.state.conversations
          .expand((c) => c.messages)
          .map((m) => m.body);
      expect(heard.any((b) => b.contains('ZEBRA7')), isTrue);
    },
  );

  test('/pass refuses if you do not run the room', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    final outcome = await alice.runtime.runCommand(
      '/pass ZEBRA7',
      conversationId: room.conversationId,
    );

    expect(outcome.notice, contains('owner'));
  });

  test('/help lists the commands', () async {
    final outcome = await alice.runtime.runCommand('/help', conversationId: '');

    expect(outcome.notice, contains('/join'));
  });

  test('a typo is reported and never sent to the room', () async {
    final room = await alice.runtime.joinRoom('RUFF7A');

    final outcome = await alice.runtime.runCommand(
      '/blcok bob',
      conversationId: room.conversationId,
    );
    await deliver();

    expect(outcome.notice, contains('/blcok'));
    expect(alice.state.conversation(room.conversationId)!.messages, isEmpty);
  });
}
