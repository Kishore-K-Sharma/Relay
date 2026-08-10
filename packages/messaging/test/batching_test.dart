import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';

/// Several queued messages travelling in one frame.
///
/// Every frame costs a connection event, a 20-byte header, a nonce, a 16-byte
/// tag and a round up to the next padding block. For a mesh whose typical
/// message is a few words, that overhead is most of the airtime.
class CountingTransport implements Transport {
  final sent = <Uint8List>[];
  final _peers = [const TransportPeer(peerId: 'sara', hopDistance: 1)];
  final _inbound = StreamController<InboundFrame>.broadcast();

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<PeerEvent> get peerEvents => const Stream.empty();
  @override
  List<TransportPeer> get peers => _peers;
  @override
  TransportStatus get status => const TransportStatus(
    running: true,
    adapterOn: true,
    permissionsGranted: true,
    advertising: true,
    scanning: true,
    connectedPeerCount: 1,
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

const int localHash = 0xAAAA;
const int peerHash = 0xBBBB;

void main() {
  late LocalStore store;
  late CountingTransport mesh;
  late MessageService service;
  late SessionManager sessions;
  late SessionManager peerSessions;
  late MessageService peerService;
  late LocalStore peerStore;

  var now = DateTime(2026, 7, 26, 12);

  Future<void> establishSession() async {
    final msg1 = await sessions.beginHandshake(peerHash);
    final msg2 = await peerSessions.receiveHandshake(localHash, msg1);
    final msg3 = await sessions.receiveHandshake(peerHash, msg2!);
    await peerSessions.receiveHandshake(localHash, msg3!);
  }

  setUp(() {
    store = LocalStore.open()
      ..upsertConversation(
        id: 'c1',
        kind: ConversationKind.direct,
        title: 'Sara',
      );
    peerStore = LocalStore.open()
      ..upsertConversation(
        id: 'c1',
        kind: ConversationKind.direct,
        title: 'Me',
      );

    mesh = CountingTransport();
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
    peerService = MessageService(
      store: peerStore,
      router: TransportRouter(mesh: CountingTransport()),
      sessions: peerSessions,
      senderKey: Uint8List.fromList([9, 9, 9, 9]),
      localAddressHash: peerHash,
      clock: () => now,
      random: Random(7),
    );
  });

  tearDown(() async {
    await service.dispose();
    await peerService.dispose();
    await mesh.dispose();
    store.close();
    peerStore.close();
  });

  /// Queues [count] messages with nowhere to send them, so they pile up in the
  /// outbox exactly as they do when a peer is out of range.
  Future<void> queue(int count) async {
    for (var i = 0; i < count; i++) {
      await service.send(
        conversationId: 'c1',
        body: 'message $i',
        targetHash: peerHash,
      );
    }
  }

  /// Steps past the backoff each failed attempt scheduled, then retries.
  ///
  /// Without the step, `dueRetries` correctly returns nothing and the test
  /// would be asserting against an empty transport.
  Future<int> flush([MessageService? which]) {
    now = now.add(const Duration(hours: 1));
    return (which ?? service).retryDue();
  }

  test('several queued messages leave as one frame', () async {
    await queue(4);
    await establishSession();
    mesh.sent.clear();

    await flush();

    expect(mesh.sent, hasLength(1));
    expect(Frame.decode(mesh.sent.single).type, FrameType.batch);
  });

  test('the batch really contains all of them, in order', () async {
    await queue(4);
    await establishSession();
    mesh.sent.clear();
    await flush();

    final frame = Frame.decode(mesh.sent.single);
    final received = await peerService.receiveBatch(
      conversationId: 'c1',
      ciphertext: frame.payload,
      senderHash: localHash,
      via: TransportKind.mesh,
    );

    expect(received.map((r) => r.message.body), [
      'message 0',
      'message 1',
      'message 2',
      'message 3',
    ]);
  });

  test('one message is not wrapped in a batch', () async {
    // A container around a single item costs bytes and buys nothing.
    await queue(1);
    await establishSession();
    mesh.sent.clear();

    await flush();

    expect(Frame.decode(mesh.sent.single).type, FrameType.message);
  });

  test('messages to different people are not combined', () async {
    // A batch is one encrypted frame to one address. Two recipients share
    // nothing that could be coalesced.
    await queue(2);
    await service.send(
      conversationId: 'c1',
      body: 'someone else',
      targetHash: 0xCCCC,
    );
    await establishSession();
    mesh.sent.clear();

    await flush();

    final types = mesh.sent.map((f) => Frame.decode(f).type).toSet();
    expect(types, contains(FrameType.batch));
    expect(
      mesh.sent.where((f) => Frame.decode(f).dstHash == 0xCCCC),
      isEmpty,
      reason: 'no session with them yet, so that one only opens a handshake',
    );
  });

  test('every message in a batch is reported sent, not just one', () async {
    await queue(3);
    await establishSession();

    final outcomes = <SendOutcome>[];
    final subscription = service.outcomes.listen(outcomes.add);
    await flush();
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(outcomes.where((o) => o.state == MessageState.sent), hasLength(3));
    expect(
      store.messages('c1').every((m) => m.state == MessageState.sent),
      isTrue,
    );
  });

  test('one acknowledgement clears the whole batch', () async {
    // The saving would be undone if ten batched messages needed ten receipts,
    // and worse, nine of them would be retried until they expired.
    await queue(3);
    await establishSession();
    await flush();

    final newest = store.messages('c1').last.sequence!;
    service.acknowledgeSequence(newest, fromHash: peerHash);

    expect(
      store.messages('c1').every((m) => m.state == MessageState.delivered),
      isTrue,
    );
    expect(store.outboxDepth, 0);
  });

  test('an acknowledgement does not clear somebody else\'s messages', () async {
    await queue(2);
    await service.send(
      conversationId: 'c1',
      body: 'to another person',
      targetHash: 0xCCCC,
    );
    await establishSession();
    await flush();

    final newest = store.messages('c1')[1].sequence!;
    service.acknowledgeSequence(newest, fromHash: peerHash);

    expect(
      store.messages('c1').last.state,
      isNot(MessageState.delivered),
      reason: 'that one is addressed to a different person entirely',
    );
  });

  test('a batch that cannot be sent leaves everything queued', () async {
    await queue(3);
    await establishSession();
    // Nobody in range: the router has a healthy mesh but no route to the peer,
    // and a broadcast is not what a direct message wants.
    final offline = MessageService(
      store: store,
      router: TransportRouter(mesh: CountingTransport()),
      sessions: sessions,
      senderKey: Uint8List.fromList([1, 2, 3, 4]),
      localAddressHash: localHash,
      clock: () => now,
      random: Random(42),
      relayAllowed: (_) => false,
    );
    addTearDown(offline.dispose);

    await flush(offline);

    expect(store.outboxDepth, 3);
  });

  test('a room is never batched', () async {
    // Room traffic is already one frame to everybody; there is nothing to
    // coalesce, and wrapping it would hide it from members mid-upgrade.
    final key = Uint8List.fromList(List.filled(32, 3));
    service.registerRoom(0xDDDD, RoomCipher(key));
    store.upsertConversation(
      id: 'r1',
      kind: ConversationKind.room,
      title: 'RUFF7A',
    );

    for (var i = 0; i < 3; i++) {
      await service.send(
        conversationId: 'r1',
        body: 'room message $i',
        targetHash: 0xDDDD,
      );
    }
    mesh.sent.clear();

    await flush();

    expect(
      mesh.sent.map((f) => Frame.decode(f).type),
      everyElement(FrameType.room),
    );
  });
}
