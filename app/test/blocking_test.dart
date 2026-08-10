import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// Blocking someone.
///
/// The app had no way to make a person stop reaching you, which for a chat app
/// aimed at crowds is a safety gap rather than a missing convenience.
///
/// The design decision worth stating: a blocked peer's traffic is still
/// *relayed*. Blocking is about what this device shows its owner, not about
/// punishing someone by breaking the mesh for everyone standing near them. A
/// device that stopped forwarding for one person would also be trivially
/// detectable as having blocked them.
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

  List<String> bodiesAt(Device device) => [
    for (final conversation in device.state.conversations)
      for (final message in conversation.messages) message.body,
  ];

  test('a message from a blocked peer is not shown', () async {
    // Both announce first: bob needs a conversation with alice before he can
    // send to her, and blocking is about what alice then does with it.
    await bob.runtime.announcePresence();
    await alice.runtime.announcePresence();
    final conversation = await conversationOnceAnnounced(alice);
    final fromBob = await conversationOnceAnnounced(bob);

    await alice.runtime.block(bob.runtime.identity.publicKey);
    await bob.runtime.sendText(fromBob, 'let me in');
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();

    expect(bodiesAt(alice), isNot(contains('let me in')));
    expect(conversation, isNotEmpty);
  });

  test('a blocked peer disappears from the people nearby', () async {
    await bob.runtime.announcePresence();
    await until(() => alice.state.peers.isNotEmpty, 'bob to appear');

    await alice.runtime.block(bob.runtime.identity.publicKey);
    await settle();

    expect(alice.state.peers, isEmpty);
  });

  test('a blocked peer stays gone when they announce again', () async {
    await alice.runtime.block(bob.runtime.identity.publicKey);

    await bob.runtime.announcePresence();
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();

    expect(alice.state.peers, isEmpty);
  });

  test('unblocking lets them back in', () async {
    await alice.runtime.block(bob.runtime.identity.publicKey);
    await alice.runtime.unblock(bob.runtime.identity.publicKey);

    await bob.runtime.announcePresence();
    await until(() => alice.state.peers.isNotEmpty, 'bob to reappear');
  });

  test('blocking survives a restart', () async {
    // Held in the database, not in memory. A block that lapsed when the app
    // was closed would be worse than none, because the user would believe it
    // was still in force.
    await alice.runtime.block(bob.runtime.identity.publicKey);

    expect(alice.store.isBlocked(bob.runtime.identity.publicKey), isTrue);
  });

  test('the blocked list is readable, so it can be undone', () async {
    // A block with no way to review it is a trap: someone blocks a stranger in
    // a crowd, later wants to undo it, and has no idea who they blocked.
    await alice.runtime.block(bob.runtime.identity.publicKey);

    expect(alice.store.blocked(), hasLength(1));
    expect(
      alice.store.blocked().single.publicKey,
      bob.runtime.identity.publicKey,
    );
  });

  test('we do not send to someone we have blocked', () async {
    // Blocking is mutual in effect. Continuing to send to them while ignoring
    // their replies would be a strange half-state and a privacy leak: they
    // would still learn where and when we are.
    await bob.runtime.announcePresence();
    final conversation = await conversationOnceAnnounced(alice);
    await alice.runtime.block(bob.runtime.identity.publicKey);

    await alice.runtime.sendText(conversation, 'still here?');
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();

    expect(bodiesAt(bob), isNot(contains('still here?')));
  });

  test('blocking does not stop us relaying for them', () async {
    // The part most likely to be "fixed" into something worse. Refusing to
    // relay would break the mesh for bystanders standing near the blocked
    // person, and would make the block visible to them.
    //
    // This used to assert `runtime.relaysFor(...) == true` against a method
    // whose body was the literal `true`. That is a tautology: someone could
    // teach the relay to skip blocked senders and this test would still pass,
    // because the relay does not live in Dart. It lives in RelayEngine, in
    // Kotlin and in Swift, where a frame is forwarded before anyone has
    // decided who sent it.
    //
    // So the guarantee is asserted where it is actually kept: those two files
    // have no concept of blocking at all. If a block list ever appears in
    // either, this fails.
    for (final path in [
      'app/android/app/src/main/kotlin/dev/kishorek/relay/ble/RelayEngine.kt',
      'app/ios/Runner/Ble/RelayEngine.swift',
    ]) {
      final source = _read(path).toLowerCase();
      expect(
        source,
        isNot(contains('block')),
        reason:
            '$path now knows about blocking. Relaying must not depend on who '
            'sent a frame — see docs/SECURITY.md §2.',
      );
    }
  });

  test('a panic wipe clears the block list with everything else', () async {
    await alice.runtime.block(bob.runtime.identity.publicKey);

    await alice.runtime.panicWipe();

    expect(alice.store.blocked(), isEmpty);
  });
}

/// Reads a repo-relative path regardless of where the runner was started.
String _read(String path) {
  for (var dir = Directory.current; ; dir = dir.parent) {
    final file = File('${dir.path}/$path');
    if (file.existsSync()) return file.readAsStringSync();
    if (dir.path == dir.parent.path) {
      fail('cannot find $path from ${Directory.current.path} — has it moved?');
    }
  }
}
