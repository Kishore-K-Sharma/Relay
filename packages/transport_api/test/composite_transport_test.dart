import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';

/// A transport that records what it was asked to do.
class RecordingTransport implements Transport {
  RecordingTransport({this.healthy = true, this.startError});

  bool healthy;
  Object? startError;

  bool started = false;
  bool stopped = false;
  final sent = <({Uint8List frame, String? toPeer, String? excludePeer})>[];

  final _peers = <TransportPeer>[];
  final inboundController = StreamController<InboundFrame>.broadcast();
  final peerEventController = StreamController<PeerEvent>.broadcast();
  final statusController = StreamController<TransportStatus>.broadcast();

  void addPeer(String id, {int hops = 1}) =>
      _peers.add(TransportPeer(peerId: id, hopDistance: hops));

  @override
  Stream<InboundFrame> get inbound => inboundController.stream;

  @override
  Stream<PeerEvent> get peerEvents => peerEventController.stream;

  @override
  Stream<TransportStatus> get statusChanges => statusController.stream;

  @override
  List<TransportPeer> get peers => List.unmodifiable(_peers);

  @override
  TransportStatus get status => TransportStatus(
    running: started,
    adapterOn: healthy,
    permissionsGranted: healthy,
    advertising: healthy,
    scanning: healthy,
    connectedPeerCount: _peers.length,
  );

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    started = false;
  }

  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    sent.add((frame: frame, toPeer: toPeer, excludePeer: excludePeer));
  }
}

void main() {
  late RecordingTransport ble;
  late RecordingTransport wifi;
  late CompositeTransport composite;

  setUp(() {
    ble = RecordingTransport();
    wifi = RecordingTransport();
    composite = CompositeTransport({'ble': ble, 'wifi': wifi});
  });

  test('peers from every transport appear, tagged with where they came '
      'from', () {
    ble.addPeer('AA:BB');
    wifi.addPeer('wifi:0000beef');

    expect(composite.peers.map((p) => p.peerId), [
      'ble/AA:BB',
      'wifi/wifi:0000beef',
    ]);
  });

  test('the tag is what makes a reply go back the way it came', () async {
    ble.addPeer('AA:BB');
    wifi.addPeer('wifi:0000beef');

    await composite.send(Uint8List.fromList([1]), toPeer: 'wifi/wifi:0000beef');

    expect(ble.sent, isEmpty);
    expect(wifi.sent.single.toPeer, 'wifi:0000beef');
  });

  test('a broadcast goes out on every transport', () async {
    await composite.send(Uint8List.fromList([1]));

    expect(ble.sent, hasLength(1));
    expect(wifi.sent, hasLength(1));
    expect(ble.sent.single.toPeer, isNull);
  });

  test('excluding a peer only constrains the transport it is on', () async {
    // The exclusion exists to stop a relayed frame echoing back down the link
    // it arrived on. On the other radio there is no such link, and skipping the
    // broadcast there would silently drop a hop.
    await composite.send(Uint8List.fromList([1]), excludePeer: 'ble/AA:BB');

    expect(ble.sent.single.excludePeer, 'AA:BB');
    expect(wifi.sent.single.excludePeer, isNull);
    expect(wifi.sent, hasLength(1));
  });

  test('a send to an unknown transport is dropped, not thrown', () async {
    await composite.send(Uint8List.fromList([1]), toPeer: 'carrier-pigeon/x');

    expect(ble.sent, isEmpty);
    expect(wifi.sent, isEmpty);
  });

  test('inbound frames from every transport arrive, tagged', () async {
    final frames = <InboundFrame>[];
    composite.inbound.listen(frames.add);

    ble.inboundController.add(
      InboundFrame(bytes: Uint8List.fromList([1]), fromPeer: 'AA:BB'),
    );
    wifi.inboundController.add(
      InboundFrame(bytes: Uint8List.fromList([2]), fromPeer: 'wifi:1'),
    );
    await pumpEventQueue();

    expect(frames.map((f) => f.fromPeer), ['ble/AA:BB', 'wifi/wifi:1']);
  });

  test('peer events are tagged the same way', () async {
    final events = <PeerEvent>[];
    composite.peerEvents.listen(events.add);

    wifi.peerEventController.add(
      const PeerEvent(
        PeerEventKind.discovered,
        TransportPeer(peerId: 'wifi:1', hopDistance: 1),
      ),
    );
    await pumpEventQueue();

    expect(events.single.peer.peerId, 'wifi/wifi:1');
  });

  test('one working transport is enough to be healthy', () async {
    await composite.start();
    ble.healthy = false;

    // Bluetooth off with Wi-Fi working must not report the mesh as dead — it
    // is not, and refusing to send over Wi-Fi because of it would be a bug the
    // user experiences as messages that never leave.
    expect(composite.status.isHealthy, isTrue);
  });

  test('no working transport is not healthy', () async {
    await composite.start();
    ble.healthy = false;
    wifi.healthy = false;

    expect(composite.status.isHealthy, isFalse);
  });

  test('the peer count is the total across transports', () {
    ble.addPeer('a');
    wifi.addPeer('b');
    wifi.addPeer('c');

    expect(composite.status.connectedPeerCount, 3);
  });

  test('a transport that will not start does not stop the others', () async {
    ble.startError = StateError('bluetooth permission refused');

    await composite.start();

    expect(wifi.started, isTrue);
    expect(composite.startErrors.keys, ['ble']);
  });

  test('a failure to start is reported rather than thrown', () async {
    // Thrown, it would abort the others. Swallowed, the user would never learn
    // why half the mesh is missing. Recorded, the caller decides.
    ble.startError = StateError('nope');

    await expectLater(composite.start(), completes);
    expect(composite.startErrors['ble'], isA<StateError>());
  });

  test('a later successful start clears the earlier failure', () async {
    ble.startError = StateError('nope');
    await composite.start();

    ble.startError = null;
    await composite.start();

    expect(composite.startErrors, isEmpty);
  });

  test('stopping stops everything', () async {
    await composite.start();
    await composite.stop();

    expect(ble.stopped, isTrue);
    expect(wifi.stopped, isTrue);
  });

  test('a change on any transport publishes a combined status', () async {
    await composite.start();
    final next = composite.statusChanges.first;

    wifi.addPeer('x');
    wifi.statusController.add(wifi.status);

    expect((await next).connectedPeerCount, 1);
  });

  test('the named transports stay reachable for per-radio reporting', () {
    // The UI has to be able to say "Bluetooth is off, Wi-Fi is working"
    // rather than one merged verdict that is true of neither.
    expect(composite.child('wifi'), same(wifi));
    expect(composite.child('nothing'), isNull);
  });

  test('a peer id survives the round trip through the tag', () {
    ble.addPeer('wifi/weird:id');

    final tagged = composite.peers.single.peerId;

    expect(tagged, 'ble/wifi/weird:id');
    expect(CompositeTransport.transportOf(tagged), 'ble');
    expect(CompositeTransport.peerOf(tagged), 'wifi/weird:id');
  });
}
