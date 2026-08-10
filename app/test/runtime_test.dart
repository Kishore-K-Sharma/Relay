import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:data/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/domain/models.dart' as ui;
import 'package:relay_app/src/runtime/runtime.dart';
import 'package:transport_api/transport_api.dart';

/// Two transports wired to each other, so a frame one sends is a frame the
/// other receives.
///
/// This is the only way to prove the runtime works: a single-sided fake can
/// only ever confirm that we call our own code. Here the receiving runtime has
/// to genuinely decode, decrypt and store what the sending one produced.
class WireTransport implements Transport {
  WireTransport(this.name);

  final String name;
  WireTransport? other;

  bool healthy = true;
  bool dropEverything = false;

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _peerEvents = StreamController<PeerEvent>.broadcast();
  final _statusChanges = StreamController<TransportStatus>.broadcast();
  final _peers = <TransportPeer>[];
  final sent = <Uint8List>[];

  void link(WireTransport peer) {
    other = peer;
    peer.other = this;
    _peers.add(TransportPeer(peerId: peer.name, hopDistance: 1));
    peer._peers.add(TransportPeer(peerId: name, hopDistance: 1));
  }

  void announcePeers() {
    for (final peer in _peers) {
      _peerEvents.add(PeerEvent(PeerEventKind.discovered, peer));
    }
  }

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;
  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;
  @override
  List<TransportPeer> get peers => _peers;

  @override
  TransportStatus get status => TransportStatus(
    running: healthy,
    adapterOn: healthy,
    permissionsGranted: healthy,
    advertising: healthy,
    scanning: healthy,
    connectedPeerCount: _peers.length,
  );

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    sent.add(frame);
    if (dropEverything) return;
    other?._inbound.add(InboundFrame(bytes: frame, fromPeer: name));
  }

  Future<void> dispose() async {
    await _inbound.close();
    await _peerEvents.close();
    await _statusChanges.close();
  }
}

/// Shared test clock, so backoff can be stepped over deliberately instead of
/// slept through.
DateTime now = DateTime(2026, 7, 26, 12);

class Harness {
  Harness._(this.state, this.store, this.transport, this.runtime);

  static Future<Harness> create(String name, WireTransport transport) async {
    final state = AppState(nickname: name);
    final store = LocalStore.open();
    final identity = await MeshIdentity.generate();
    final noiseKey = Uint8List.fromList(
      List.generate(32, (i) => (name.codeUnitAt(0) + i) % 256),
    );
    final addressHash = await addressHashOf(identity.publicKey);

    final runtime = MeshRuntime(
      state: state,
      store: store,
      mesh: transport,
      identity: identity,
      noiseStaticKey: noiseKey,
      localAddressHash: addressHash,
      clock: () => now,
    );
    await runtime.start();
    return Harness._(state, store, transport, runtime);
  }

  final AppState state;
  final LocalStore store;
  final WireTransport transport;
  final MeshRuntime runtime;

  int get addressHash => runtime.localAddressHash;

  Future<void> dispose() async {
    await runtime.stop();
    await transport.dispose();
    store.close();
  }
}

/// Lets every queued microtask and stream event drain.
Future<void> settle() => pumpEventQueue(times: 40);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WireTransport aliceWire;
  late WireTransport bobWire;
  late Harness alice;
  late Harness bob;

  setUp(() async {
    now = DateTime(2026, 7, 26, 12);
    aliceWire = WireTransport('alice');
    bobWire = WireTransport('bob');
    aliceWire.link(bobWire);

    alice = await Harness.create('alice', aliceWire);
    bob = await Harness.create('bob', bobWire);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  group('presence', () {
    test('an announce teaches the other side a name and an address', () async {
      await alice.runtime.announcePresence();
      await settle();

      expect(bob.state.peers, hasLength(1));
      expect(bob.state.peers.single.nickname, 'alice');
    });

    test(
      'a peer with no announce yet shows as unnamed rather than absent',
      () async {
        aliceWire.announcePeers();
        await settle();

        // Dropping unnamed peers would make the mesh look empty for the first
        // seconds after a phone comes into range, which is exactly when the user
        // is looking at the screen.
        expect(alice.state.peers, hasLength(1));
        expect(alice.state.peers.single.nickname, isNotEmpty);
      },
    );

    test('a name in a non-Latin script arrives intact', () async {
      alice.state.nickname = 'नेहा';
      await alice.runtime.announcePresence();
      await settle();

      // `String.codeUnits` would truncate every one of these characters to a
      // single byte and the name would arrive as mojibake.
      expect(bob.state.peers.single.nickname, 'नेहा');
    });

    test(
      'a very long name is cut without corrupting the last character',
      () async {
        alice.state.nickname = 'नेहा' * 20;
        await alice.runtime.announcePresence();
        await settle();

        final received = bob.state.peers.single.nickname;
        expect(received, isNotEmpty);
        expect(utf8.encode(received).length, lessThanOrEqualTo(32));
        // Cutting mid-character would leave a replacement glyph on the end.
        expect(received, isNot(contains('�')));
      },
    );

    test('losing a peer removes them from the UI', () async {
      await alice.runtime.announcePresence();
      await settle();
      expect(bob.state.peers, hasLength(1));

      // The id the runtime knows, not the transport's own: peer ids carry
      // which radio they arrived on, because a reply has to go back the way it
      // came now that there is more than one radio.
      bob.runtime.handlePeerLost(bob.state.peers.single.id);
      await settle();

      expect(bob.state.peers, isEmpty);
    });
  });

  group('direct messages', () {
    Future<void> introduce() async {
      await alice.runtime.announcePresence();
      await bob.runtime.announcePresence();
      await settle();
    }

    test('a message reaches the other device and is readable there', () async {
      await introduce();

      final conversation = alice.runtime.conversationForPeer(
        alice.state.peers.first.id,
      );
      expect(conversation, isNotNull);

      // The first send only opens the handshake. Completing it flushes the
      // message without any further prompting, which is the behaviour a user
      // experiences as "I pressed send and it went".
      await alice.runtime.sendText(conversation!.id, 'meet at gate B');
      await settle();

      final received = bob.state.conversations
          .expand((c) => c.messages)
          .where((m) => !m.fromMe)
          .toList();
      expect(received, hasLength(1));
      expect(received.single.body, 'meet at gate B');
    });

    test('nothing readable crosses the wire', () async {
      await introduce();
      final conversation = alice.runtime.conversationForPeer(
        alice.state.peers.first.id,
      )!;

      await alice.runtime.sendText(conversation.id, 'meet at gate B');
      await settle();

      for (final frame in aliceWire.sent) {
        expect(String.fromCharCodes(frame), isNot(contains('gate B')));
      }
    });

    ui.Message mine(String conversationId, String body) => alice.state
        .conversation(conversationId)!
        .messages
        .where((m) => m.fromMe && m.body == body)
        .single;

    test(
      'the sender sees sent, not delivered, while no ack has returned',
      () async {
        await introduce();
        final conversation = alice.runtime.conversationForPeer(
          alice.state.peers.first.id,
        )!;

        // Get a session up first, then silence the return path so the frame goes
        // out but no acknowledgement can come back.
        await alice.runtime.sendText(conversation.id, 'warm up');
        await settle();
        bobWire.dropEverything = true;

        await alice.runtime.sendText(conversation.id, 'hello');
        await settle();

        expect(
          mine(conversation.id, 'hello').state,
          ui.MessageState.sent,
          reason: 'a frame leaving the radio is not evidence it arrived',
        );
      },
    );

    test('an ack from the other device turns sent into delivered', () async {
      await introduce();
      final conversation = alice.runtime.conversationForPeer(
        alice.state.peers.first.id,
      )!;

      await alice.runtime.sendText(conversation.id, 'hello');
      await settle();

      expect(mine(conversation.id, 'hello').state, ui.MessageState.delivered);
    });

    test(
      'a message sent while out of range is delivered when range returns',
      () async {
        await introduce();
        final conversation = alice.runtime.conversationForPeer(
          alice.state.peers.first.id,
        )!;

        // Establish the session while the link is up, then break it.
        await alice.runtime.sendText(conversation.id, 'first');
        await settle();
        aliceWire.dropEverything = true;

        await alice.runtime.sendText(conversation.id, 'while apart');
        await settle();
        expect(
          bob.state.conversations.expand((c) => c.messages).map((m) => m.body),
          isNot(contains('while apart')),
        );

        aliceWire.dropEverything = false;
        now = now.add(const Duration(minutes: 10));
        await alice.runtime.retryPending();
        await settle();

        final bodies = bob.state.conversations
            .expand((c) => c.messages)
            .map((m) => m.body)
            .toList();
        expect(bodies, contains('while apart'));
      },
    );
  });

  group('rooms', () {
    test('two devices in the same room can read each other', () async {
      final code = await alice.runtime.joinRoom('MESH42');
      await bob.runtime.joinRoom('MESH42');
      await settle();

      await alice.runtime.sendText(code.conversationId, 'north exit');
      await settle();

      final bobRoom = bob.state.conversation(code.conversationId);
      expect(bobRoom, isNotNull);
      expect(
        bobRoom!.messages.where((m) => !m.fromMe).map((m) => m.body),
        contains('north exit'),
      );
    });

    test('a device with a different code reads nothing', () async {
      final code = await alice.runtime.joinRoom('MESH42');
      await bob.runtime.joinRoom('QRSTUV');
      await settle();

      await alice.runtime.sendText(code.conversationId, 'north exit');
      await settle();

      final bobMessages = bob.state.conversations.expand((c) => c.messages);
      expect(bobMessages.where((m) => !m.fromMe), isEmpty);
    });

    test('/leave stops the room being readable', () async {
      final code = await alice.runtime.joinRoom('MESH42');
      await bob.runtime.joinRoom('MESH42');
      await settle();

      final outcome = await bob.runtime.runCommand(
        '/leave',
        conversationId: code.conversationId,
      );
      await settle();
      await alice.runtime.sendText(code.conversationId, 'north exit');
      await settle();

      expect(outcome.notice, isNotNull);
      final bobRoom = bob.state.conversation(code.conversationId);
      expect(
        bobRoom?.messages.where((m) => !m.fromMe).map((m) => m.body) ??
            const <String>[],
        isNot(contains('north exit')),
      );
    });

    test('/leave outside a group says so instead of doing nothing', () async {
      // Silence here reads as "it worked", and the user walks away believing
      // they have left something they have not.
      final outcome = await alice.runtime.runCommand(
        '/leave',
        conversationId: '',
      );

      expect(outcome.notice, isNotNull);
    });

    test('leaving stops us answering for the room\'s history', () async {
      // The reason this matters beyond tidiness: while you are in a room you
      // serve its past to anyone who joins. A room you forgot you were in is a
      // room you are still handing to strangers.
      final code = await alice.runtime.joinRoom('MESH42');
      await alice.runtime.sendText(code.conversationId, 'north exit');
      await settle();

      await alice.runtime.runCommand(
        '/leave',
        conversationId: code.conversationId,
      );
      await settle();

      expect(alice.runtime.hasPendingHistoryReply(code.roomId), isFalse);
    });
  });

  group('status', () {
    test('a transport that is down is reported, not hidden', () async {
      aliceWire.healthy = false;
      await alice.runtime.refreshStatus();

      expect(alice.state.status.isHealthy, isFalse);
      expect(alice.state.status.problem, isNotNull);
    });
  });

  group('stealth mode', () {
    test('stops announcing presence', () async {
      await alice.runtime.setStealth(true);
      aliceWire.sent.clear();

      await alice.runtime.announcePresence();
      await settle();

      // The point of the mode. A beacon carrying a nickname would announce the
      // user to everyone in radio range, which is what they just asked to stop.
      expect(aliceWire.sent, isEmpty);

      // Bob may still see a radio contact — native stops advertising, but an
      // already-open link does not vanish. What he must not have is Alice's
      // name or her mesh address, so there is nobody for him to write to.
      expect(bob.state.peers.map((p) => p.nickname), isNot(contains('alice')));
      expect(bob.runtime.conversationForPeer('alice'), isNull);
    });

    test('keeps carrying other people\'s messages', () async {
      await bob.runtime.announcePresence();
      await settle();
      await alice.runtime.setStealth(true);

      final before = bob.state.peers.length;
      await bob.runtime.announcePresence();
      await settle();

      // Relaying is what provides the cover. A device that went silent
      // entirely would stand out as the one that stopped participating, and
      // would also stop being useful to everyone around it.
      expect(alice.state.peers, hasLength(greaterThanOrEqualTo(before)));
    });

    test('disables the internet relay', () async {
      await alice.runtime.setStealth(true);

      expect(alice.runtime.router.stealthMode, isTrue);
      expect(alice.runtime.router.relayAvailable, isFalse);
      expect(alice.state.status.relayAvailable, isFalse);
    });

    test('is visible in the status the UI renders', () async {
      await alice.runtime.setStealth(true);

      expect(alice.state.status.stealthMode, isTrue);
    });

    test('turning it off announces again', () async {
      await alice.runtime.setStealth(true);
      await settle();
      aliceWire.sent.clear();

      await alice.runtime.setStealth(false);
      await settle();

      // Without this the user would appear to still be hidden until something
      // else happened to trigger a beacon.
      expect(aliceWire.sent, isNotEmpty);
      expect(bob.state.peers, hasLength(1));
    });

    test('a message can still be sent while hidden', () async {
      await bob.runtime.announcePresence();
      await settle();
      await alice.runtime.setStealth(true);

      final conversation = alice.runtime.conversationForPeer(
        alice.state.peers.first.id,
      )!;
      await alice.runtime.sendText(conversation.id, 'still here');
      await settle();

      // Stealth suppresses discovery, not conversation. Someone who already
      // knows you can still be reached, which is the whole reason to use it.
      expect(
        bob.state.conversations.expand((c) => c.messages).map((m) => m.body),
        contains('still here'),
      );
    });
  });

  group('panic wipe', () {
    test('erases messages, contacts and sessions', () async {
      await alice.runtime.announcePresence();
      await bob.runtime.announcePresence();
      await settle();

      final conversation = alice.runtime.conversationForPeer(
        alice.state.peers.first.id,
      )!;
      await alice.runtime.sendText(conversation.id, 'something private');
      await settle();

      await alice.runtime.panicWipe();

      expect(alice.state.conversations, isEmpty);
      expect(alice.store.messages(conversation.id), isEmpty);
      expect(alice.state.peers, isEmpty);
    });
  });
}
