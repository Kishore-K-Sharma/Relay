import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';

class FakeTransport implements Transport {
  FakeTransport({this.healthy = true, List<String> peerIds = const []})
    : _peers = peerIds
          .map((id) => TransportPeer(peerId: id, hopDistance: 1))
          .toList();

  bool healthy;
  final List<TransportPeer> _peers;
  final sent = <Uint8List>[];
  final _inbound = StreamController<InboundFrame>.broadcast();

  void addPeer(String id) =>
      _peers.add(TransportPeer(peerId: id, hopDistance: 1));

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<PeerEvent> get peerEvents => const Stream.empty();
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
  Stream<TransportStatus> get statusChanges => const Stream.empty();
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
  }

  Future<void> dispose() => _inbound.close();
}

/// Undoes the length padding the service applies before encryption.
///
/// Tests that decrypt by hand see the padded block, not the envelope. Without
/// this they would be asserting against filler bytes.
Uint8List unpad(Uint8List plaintext) => const PaddingPolicy().strip(plaintext);

const int localHash = 0xAAAA;
const int peerHash = 0xBBBB;

void main() {
  late LocalStore store;
  late FakeTransport mesh;
  late MessageService service;
  late SessionManager sessions;

  /// The peer's own session state, so a test can decrypt what we sent and
  /// encrypt something back. Without it every assertion about encryption would
  /// be checking our own code against itself.
  late SessionManager peerSessions;

  var now = DateTime(2026, 7, 26, 12);

  /// Runs a full Noise XX handshake so the service has a usable session.
  Future<void> establishSession() async {
    final msg1 = await sessions.beginHandshake(peerHash);
    final msg2 = await peerSessions.receiveHandshake(localHash, msg1);
    final msg3 = await sessions.receiveHandshake(peerHash, msg2!);
    await peerSessions.receiveHandshake(localHash, msg3!);
  }

  setUp(() {
    store = LocalStore.open();
    store.upsertConversation(
      id: 'c1',
      kind: ConversationKind.direct,
      title: 'Sara',
    );
    mesh = FakeTransport(peerIds: ['sara']);
    sessions = SessionManager(
      staticPrivateKey: Uint8List.fromList(List.filled(32, 1)),
      localAddressHash: localHash,
    );
    peerSessions = SessionManager(
      staticPrivateKey: Uint8List.fromList(List.filled(32, 2)),
      localAddressHash: peerHash,
    );
    service = MessageService(
      store: store,
      router: TransportRouter(mesh: mesh),
      sessions: sessions,
      senderKey: Uint8List.fromList([1, 2, 3, 4]),
      localAddressHash: localHash,
      clock: () => now,
      random: Random(42),
    );
  });

  tearDown(() async {
    await service.dispose();
    await mesh.dispose();
    store.close();
  });

  group('sending', () {
    test('stores the message and puts frames on the transport', () async {
      await establishSession();

      final outcome = await service.send(
        conversationId: 'c1',
        body: 'meet at gate B',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      expect(outcome.state, MessageState.sent);
      expect(mesh.sent, isNotEmpty);
      expect(store.messages('c1').single.body, 'meet at gate B');
    });

    test('what goes on the wire is ciphertext', () async {
      await establishSession();

      await service.send(
        conversationId: 'c1',
        body: 'meet at gate B',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      final wire = String.fromCharCodes(mesh.sent.single);
      expect(wire, isNot(contains('gate B')));
    });

    test('the peer can actually decrypt what we sent', () async {
      await establishSession();

      await service.send(
        conversationId: 'c1',
        body: 'meet at gate B',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      final frame = Frame.decode(mesh.sent.single);
      final plaintext = await peerSessions.decrypt(localHash, frame.payload);
      final envelope = AppEnvelope.decode(unpad(plaintext))!;

      expect(String.fromCharCodes(envelope.body), 'meet at gate B');
    });

    test(
      'the encrypted flag on the header is true, and true honestly',
      () async {
        await establishSession();

        await service.send(
          conversationId: 'c1',
          body: 'hi',
          targetHash: peerHash,
          targetPeerId: 'sara',
        );

        expect(Frame.decode(mesh.sent.single).flags.encrypted, isTrue);
      },
    );

    test('a message to a peer with no session starts a handshake instead of '
        'going out in clear', () async {
      final outcome = await service.send(
        conversationId: 'c1',
        body: 'secret',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      // Nothing readable may leave the device. The message waits.
      expect(outcome.state, MessageState.queued);
      expect(store.outboxDepth, 1);

      expect(mesh.sent, hasLength(1));
      final frame = Frame.decode(mesh.sent.single);
      expect(frame.type, FrameType.handshake);
      expect(String.fromCharCodes(frame.payload), isNot(contains('secret')));
    });

    test('completing a handshake flushes what was waiting', () async {
      await service.send(
        conversationId: 'c1',
        body: 'secret',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      // Drive the peer's half of the handshake and feed the replies back.
      final msg1 = Frame.decode(mesh.sent.single).payload;
      final msg2 = await peerSessions.receiveHandshake(localHash, msg1);
      await service.handleHandshake(peerHash: peerHash, message: msg2!);

      final msg3 = Frame.decode(mesh.sent.last).payload;
      await peerSessions.receiveHandshake(localHash, msg3);

      now = now.add(const Duration(minutes: 5));
      await service.retryDue();

      final last = Frame.decode(mesh.sent.last);
      expect(last.type, FrameType.message);
      final plaintext = await peerSessions.decrypt(localHash, last.payload);
      expect(
        String.fromCharCodes(AppEnvelope.decode(unpad(plaintext))!.body),
        'secret',
      );
    });

    test('a message in a non-Latin script survives the round trip', () async {
      await establishSession();
      const body = 'उत्तरी द्वार पर मिलो 🚪';

      await service.send(
        conversationId: 'c1',
        body: body,
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      // `String.codeUnits` yields UTF-16, and anything above 0xFF is silently
      // truncated on the way into a byte list. Most of the world's languages
      // would arrive as mojibake.
      final frame = Frame.decode(mesh.sent.single);
      final plaintext = await peerSessions.decrypt(localHash, frame.payload);
      final envelope = AppEnvelope.decode(unpad(plaintext))!;

      expect(utf8.decode(envelope.body), body);
    });

    test('reports sent, never delivered, on transmission', () async {
      await establishSession();

      final outcome = await service.send(
        conversationId: 'c1',
        body: 'hi',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      expect(
        outcome.state,
        MessageState.sent,
        reason: 'a frame leaving the radio is not evidence it arrived',
      );
      expect(store.messages('c1').single.state, MessageState.sent);
    });

    test('queues rather than failing when nothing is reachable', () async {
      await establishSession();
      mesh.healthy = false;

      final outcome = await service.send(
        conversationId: 'c1',
        body: 'hi',
        targetHash: peerHash,
        targetPeerId: 'nobody',
      );

      expect(outcome.state, MessageState.queued);
      expect(outcome.reason, isNotNull);
      expect(store.outboxDepth, 1);
    });

    test('fragments a payload too large for one frame', () async {
      await establishSession();

      // Deliberately not 'x' * 900, which compresses to almost nothing and
      // then fits in a single frame — the test would pass for the wrong
      // reason and stop covering fragmentation at all.
      // `(i * 37 + i * i) % 90` looks scrambled and has a period of 90, so
      // LZ4 eats it. Only a real pseudo-random stream is incompressible.
      final random = Random(5);
      final incompressible = String.fromCharCodes(
        List.generate(900, (_) => 33 + random.nextInt(90)),
      );

      await service.send(
        conversationId: 'c1',
        body: incompressible,
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      expect(mesh.sent.length, greaterThan(1));
    });

    test(
      'a compressible payload of the same size needs fewer frames',
      () async {
        // The point of compression, stated as a test rather than assumed.
        await establishSession();

        await service.send(
          conversationId: 'c1',
          body: 'north gate at nine. ' * 45,
          targetHash: peerHash,
          targetPeerId: 'sara',
        );

        expect(mesh.sent.length, 1);
      },
    );

    test('keeps the message in the outbox until acknowledged', () async {
      await establishSession();

      final outcome = await service.send(
        conversationId: 'c1',
        body: 'hi',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );
      expect(store.outboxDepth, 1);

      service.acknowledge(outcome.messageId);

      expect(store.outboxDepth, 0);
      expect(store.messages('c1').single.state, MessageState.delivered);
    });

    test('emits an outcome event for the UI', () async {
      await establishSession();
      final events = <SendOutcome>[];
      final subscription = service.outcomes.listen(events.add);

      await service.send(
        conversationId: 'c1',
        body: 'hi',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.single.state, MessageState.sent);
      await subscription.cancel();
    });
  });

  group('rooms', () {
    setUp(() {
      store.upsertConversation(
        id: 'room1',
        kind: ConversationKind.room,
        title: 'Field',
      );
      service.registerRoom(
        0xC0DE,
        RoomCipher(Uint8List.fromList(List.filled(32, 7))),
      );
    });

    test('a room message is encrypted under the room key', () async {
      await service.send(
        conversationId: 'room1',
        body: 'north exit now',
        targetHash: 0xC0DE,
      );

      final frame = Frame.decode(mesh.sent.single);
      expect(frame.type, FrameType.room);
      expect(String.fromCharCodes(frame.payload), isNot(contains('north')));

      final opened = await RoomCipher(
        Uint8List.fromList(List.filled(32, 7)),
      ).decrypt(frame.payload);
      expect(
        String.fromCharCodes(AppEnvelope.decode(unpad(opened))!.body),
        'north exit now',
      );
    });

    test('a room needs no handshake', () async {
      final outcome = await service.send(
        conversationId: 'room1',
        body: 'hello everyone',
        targetHash: 0xC0DE,
      );

      // Everyone with the code shares one key, so there is nobody to shake
      // hands with — the message goes out immediately.
      expect(outcome.state, MessageState.sent);
    });
  });

  group('retrying', () {
    test('retries a queued message once a peer appears', () async {
      await establishSession();
      mesh.healthy = false;
      await service.send(
        conversationId: 'c1',
        body: 'deferred',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );
      expect(mesh.sent, isEmpty);

      mesh.healthy = true;
      now = now.add(const Duration(minutes: 5));
      final retried = await service.retryDue();

      expect(retried, 1);
      expect(mesh.sent, isNotEmpty);
    });

    test('gives up after the outbox lifetime and says so', () async {
      await establishSession();
      mesh.healthy = false;
      final outcome = await service.send(
        conversationId: 'c1',
        body: 'doomed',
        targetHash: peerHash,
        targetPeerId: 'sara',
      );

      now = now.add(const Duration(hours: 25));
      await service.retryDue();

      expect(store.messages('c1').single.state, MessageState.expired);
      expect(store.outboxDepth, 0);
      expect(outcome.messageId, isNotEmpty);
    });
  });

  group('receiving', () {
    /// Encrypts as the peer would, so the service is decrypting something it
    /// did not itself produce.
    Future<Uint8List> sealed(int sequence, String body, {int? voiceMs}) async {
      final envelope = AppEnvelope(
        senderKey: Uint8List.fromList([9, 9, 9, 9]),
        sequence: sequence,
        body: Uint8List.fromList(body.codeUnits),
        voiceDurationMs: voiceMs,
      ).encode();
      // Padded the way the service pads, or the receiver strips filler that
      // is not there and drops the message.
      return peerSessions.encrypt(
        localHash,
        const PaddingPolicy().pad(envelope),
      );
    }

    setUp(establishSession);

    test('stores an inbound message', () async {
      final message = await service.receive(
        conversationId: 'c1',
        ciphertext: await sealed(1, 'hello'),
        senderHash: peerHash,
        via: TransportKind.mesh,
        hopCount: 2,
      );

      expect(message!.message.body, 'hello');
      expect(message.message.hopCount, 2);
      expect(store.messages('c1').single.fromMe, isFalse);
    });

    test('suppresses the same message arriving twice', () async {
      final first = await sealed(1, 'hello');
      await service.receive(
        conversationId: 'c1',
        ciphertext: first,
        senderHash: peerHash,
        via: TransportKind.mesh,
      );

      // The relayed copy is a separate transmission, so it is separately
      // encrypted — the duplicate has to be caught above the crypto layer.
      final second = await service.receive(
        conversationId: 'c1',
        ciphertext: await sealed(1, 'hello'),
        senderHash: peerHash,
        via: TransportKind.relay,
      );

      expect(
        second,
        isNull,
        reason: 'the same message over both paths is one message',
      );
      expect(store.messages('c1'), hasLength(1));
    });

    test('records which transport it arrived on', () async {
      final message = await service.receive(
        conversationId: 'c1',
        ciphertext: await sealed(1, 'via relay'),
        senderHash: peerHash,
        via: TransportKind.relay,
      );

      expect(message!.message.transport, 'relay');
    });

    test('a frame from an unknown peer is dropped, not shown', () async {
      final message = await service.receive(
        conversationId: 'c1',
        ciphertext: Uint8List(64),
        senderHash: 0xDEAD,
        via: TransportKind.mesh,
      );

      expect(message, isNull);
      expect(store.messages('c1'), isEmpty);
    });

    test('a forged ciphertext is dropped', () async {
      final tampered = await sealed(1, 'hello');
      tampered[0] ^= 0xFF;

      final message = await service.receive(
        conversationId: 'c1',
        ciphertext: tampered,
        senderHash: peerHash,
        via: TransportKind.mesh,
      );

      expect(message, isNull);
    });

    test('carries a voice note duration', () async {
      final message = await service.receive(
        conversationId: 'c1',
        ciphertext: await sealed(5, 'xx', voiceMs: 12000),
        senderHash: peerHash,
        via: TransportKind.mesh,
      );

      expect(message!.message.voiceDurationMs, 12000);
    });

    test('a room message decrypts under the room key', () async {
      store.upsertConversation(
        id: 'room1',
        kind: ConversationKind.room,
        title: 'Field',
      );
      final key = Uint8List.fromList(List.filled(32, 7));
      service.registerRoom(0xC0DE, RoomCipher(key));

      final envelope = AppEnvelope(
        senderKey: Uint8List.fromList([4, 4, 4, 4]),
        sequence: 1,
        body: Uint8List.fromList('hi room'.codeUnits),
      ).encode();

      final message = await service.receive(
        conversationId: 'room1',
        ciphertext: await RoomCipher(
          key,
        ).encrypt(const PaddingPolicy().pad(envelope)),
        senderHash: 0xC0DE,
        via: TransportKind.mesh,
      );

      expect(message!.message.body, 'hi room');
    });
  });

  group('AppEnvelope', () {
    test('round-trips', () {
      final original = AppEnvelope(
        senderKey: Uint8List.fromList([1, 2, 3, 4]),
        sequence: 77,
        body: Uint8List.fromList('body'.codeUnits),
        voiceDurationMs: 3000,
      );

      final decoded = AppEnvelope.decode(original.encode())!;

      expect(decoded.sequence, 77);
      expect(String.fromCharCodes(decoded.body), 'body');
      expect(decoded.voiceDurationMs, 3000);
    });

    test('treats zero duration as not a voice note', () {
      final decoded = AppEnvelope.decode(
        AppEnvelope(
          senderKey: Uint8List(4),
          sequence: 1,
          body: Uint8List(0),
        ).encode(),
      )!;

      expect(decoded.voiceDurationMs, isNull);
    });
  });
}
