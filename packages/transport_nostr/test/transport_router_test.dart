import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';

/// Records what was sent so routing decisions are observable.
class RecordingTransport implements Transport {
  RecordingTransport({this.healthy = true, List<String> peerIds = const []})
    : _peers = peerIds
          .map((id) => TransportPeer(peerId: id, hopDistance: 1))
          .toList();

  bool healthy;
  final List<TransportPeer> _peers;
  final sent = <({Uint8List frame, String? toPeer})>[];
  final _inbound = StreamController<InboundFrame>.broadcast();

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
    sent.add((frame: frame, toPeer: toPeer));
  }

  void deliver(String fromPeer) =>
      _inbound.add(InboundFrame(bytes: Uint8List(4), fromPeer: fromPeer));

  Future<void> dispose() => _inbound.close();
}

final frame = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  group('TransportRouter', () {
    test('prefers the mesh when the peer is in Bluetooth range', () async {
      final mesh = RecordingTransport(peerIds: ['sara']);
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final result = await router.send(frame, toPeer: 'sara');

      expect(result.kind, TransportKind.mesh);
      expect(result.accepted, isTrue);
      expect(mesh.sent, hasLength(1));
      expect(relay.sent, isEmpty);
    });

    test('falls back to the relay when the peer is out of range', () async {
      final mesh = RecordingTransport();
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final result = await router.send(frame, toPeer: 'sara');

      expect(result.kind, TransportKind.relay);
      expect(relay.sent.single.toPeer, 'sara');
      expect(mesh.sent, isEmpty);
    });

    test('always sends a broadcast over the mesh, never the relay', () async {
      final mesh = RecordingTransport(peerIds: ['a']);
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final result = await router.send(frame);

      expect(result.kind, TransportKind.mesh);
      expect(
        relay.sent,
        isEmpty,
        reason: '"everyone physically near me" is meaningless to a relay',
      );
    });

    test('refuses the relay in stealth mode and says why', () async {
      final mesh = RecordingTransport();
      final relay = RecordingTransport();
      final router = TransportRouter(
        mesh: mesh,
        relay: relay,
        stealthMode: true,
      );

      final result = await router.send(frame, toPeer: 'sara');

      expect(result.accepted, isFalse);
      expect(result.reason, contains('stealth'));
      expect(relay.sent, isEmpty);
    });

    test('reports honestly when nothing could be sent', () async {
      final mesh = RecordingTransport(healthy: false);
      final router = TransportRouter(mesh: mesh);

      final result = await router.send(frame, toPeer: 'sara');

      expect(result.accepted, isFalse);
      expect(result.reason, isNotNull);
    });

    test('does not claim a broadcast was sent when Bluetooth is off', () async {
      final mesh = RecordingTransport(healthy: false);
      final router = TransportRouter(mesh: mesh);

      final result = await router.send(frame);

      expect(result.accepted, isFalse);
      expect(mesh.sent, isEmpty);
    });

    test('treats an unhealthy relay as unavailable', () async {
      final mesh = RecordingTransport();
      final relay = RecordingTransport(healthy: false);
      final router = TransportRouter(mesh: mesh, relay: relay);

      expect(router.relayAvailable, isFalse);
      expect((await router.send(frame, toPeer: 'sara')).accepted, isFalse);
    });

    test('will not use the relay for a peer the caller has not chosen', () async {
      // The relay is a third party. It learns that two Nostr identities are
      // talking and roughly when, which is metadata the mesh never leaks. That
      // trade is worth making for someone the user deliberately picked and not
      // for every stranger who walked past, so the decision is the caller's.
      final mesh = RecordingTransport();
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final result = await router.send(
        frame,
        toPeer: 'sara',
        allowRelay: false,
      );

      expect(result.accepted, isFalse);
      expect(relay.sent, isEmpty);
      expect(result.reason, contains('favourite'));
    });

    test('still uses the relay when the caller allows it', () async {
      final mesh = RecordingTransport();
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final result = await router.send(frame, toPeer: 'sara', allowRelay: true);

      expect(result.kind, TransportKind.relay);
      expect(relay.sent, hasLength(1));
    });

    test('tags inbound frames with the transport they arrived on', () async {
      final mesh = RecordingTransport();
      final relay = RecordingTransport();
      final router = TransportRouter(mesh: mesh, relay: relay);

      final seen = <TransportKind>[];
      final subscription = router.inbound.listen((e) => seen.add(e.kind));
      await Future<void>.delayed(Duration.zero);

      mesh.deliver('p1');
      relay.deliver('p2');
      await Future<void>.delayed(Duration.zero);

      expect(seen, [TransportKind.mesh, TransportKind.relay]);
      await subscription.cancel();
      await mesh.dispose();
      await relay.dispose();
    });
  });

  group('MessageDeduplicator', () {
    test('accepts a message once', () {
      final dedup = MessageDeduplicator();
      final sender = Uint8List.fromList([1, 2, 3]);

      expect(dedup.accept(senderKey: sender, sequence: 1), isTrue);
      expect(dedup.accept(senderKey: sender, sequence: 1), isFalse);
    });

    test('suppresses the same message arriving over both transports', () {
      final dedup = MessageDeduplicator();
      final sender = Uint8List.fromList([9]);

      expect(dedup.accept(senderKey: sender, sequence: 7), isTrue);
      expect(
        dedup.accept(senderKey: sender, sequence: 7),
        isFalse,
        reason: 'a relayed copy is a separate transmission of one message',
      );
    });

    test('distinguishes senders and sequences', () {
      final dedup = MessageDeduplicator();

      expect(
        dedup.accept(senderKey: Uint8List.fromList([1]), sequence: 1),
        isTrue,
      );
      expect(
        dedup.accept(senderKey: Uint8List.fromList([2]), sequence: 1),
        isTrue,
      );
      expect(
        dedup.accept(senderKey: Uint8List.fromList([1]), sequence: 2),
        isTrue,
      );
    });

    test('stays bounded', () {
      final dedup = MessageDeduplicator(maxEntries: 3);
      final sender = Uint8List.fromList([1]);

      for (var i = 0; i < 5; i++) {
        dedup.accept(senderKey: sender, sequence: i);
      }

      expect(
        dedup.accept(senderKey: sender, sequence: 0),
        isTrue,
        reason: 'the oldest entry was evicted, so it reads as new again',
      );
      expect(dedup.accept(senderKey: sender, sequence: 4), isFalse);
    });
  });
}
