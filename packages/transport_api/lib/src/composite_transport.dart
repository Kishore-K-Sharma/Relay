import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// Several transports presented as one.
///
/// The device has more than one way to reach the people around it — Bluetooth
/// always, Wi-Fi when a network happens to exist — and everything above this
/// layer is better off not knowing. A message is sent to a peer; which radio
/// carries it is this class's problem.
///
/// Peer ids are tagged with the transport they came from, so a reply goes back
/// the way it arrived. The tag is a prefix, `ble/AA:BB`, and the split is on the
/// **first** separator only, because a transport's own ids may contain more.
class CompositeTransport implements Transport {
  CompositeTransport(Map<String, Transport> children)
    : _children = Map.unmodifiable(children) {
    for (final entry in _children.entries) {
      final name = entry.key;
      final child = entry.value;

      _subscriptions
        ..add(
          child.inbound.listen(
            (frame) => _inbound.add(
              InboundFrame(
                bytes: frame.bytes,
                fromPeer: tag(name, frame.fromPeer),
              ),
            ),
          ),
        )
        ..add(
          child.peerEvents.listen(
            (event) => _peerEvents.add(
              PeerEvent(event.kind, _tagPeer(name, event.peer)),
            ),
          ),
        )
        ..add(child.statusChanges.listen((_) => _statusChanges.add(status)));
    }
  }

  static const separator = '/';

  final Map<String, Transport> _children;
  final _subscriptions = <StreamSubscription<Object?>>[];

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _peerEvents = StreamController<PeerEvent>.broadcast();
  final _statusChanges = StreamController<TransportStatus>.broadcast();

  /// Why each transport failed to start, by name. Empty when all started.
  ///
  /// Not thrown, because one refused permission must not stop the others, and
  /// not swallowed, because the user still has to be told which half of the
  /// mesh is missing and why.
  final startErrors = <String, Object>{};

  /// The named transports, for reporting that is specific to one radio.
  ///
  /// A merged status is right for routing and wrong for the screen: "Bluetooth
  /// is off but Wi-Fi is working" is two facts, and collapsing them into one
  /// verdict makes the app lie about at least one.
  Map<String, Transport> get children => _children;

  Transport? child(String name) => _children[name];

  static String tag(String transport, String peerId) =>
      '$transport$separator$peerId';

  static String? transportOf(String taggedPeerId) {
    final index = taggedPeerId.indexOf(separator);
    return index < 0 ? null : taggedPeerId.substring(0, index);
  }

  static String? peerOf(String taggedPeerId) {
    final index = taggedPeerId.indexOf(separator);
    return index < 0 ? null : taggedPeerId.substring(index + 1);
  }

  static TransportPeer _tagPeer(String name, TransportPeer peer) =>
      TransportPeer(
        peerId: tag(name, peer.peerId),
        hopDistance: peer.hopDistance,
        rssi: peer.rssi,
        lastSeen: peer.lastSeen,
      );

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  List<TransportPeer> get peers => [
    for (final entry in _children.entries)
      for (final peer in entry.value.peers) _tagPeer(entry.key, peer),
  ];

  @override
  TransportStatus get status {
    final statuses = _children.values.map((c) => c.status).toList();
    final details = statuses.map((s) => s.detail).nonNulls.toList();

    return TransportStatus(
      // Any is the right rule throughout. One usable radio means the device can
      // reach people, and reporting otherwise would make the router refuse to
      // send over the radio that works.
      running: statuses.any((s) => s.running),
      adapterOn: statuses.any((s) => s.adapterOn),
      permissionsGranted: statuses.any((s) => s.permissionsGranted),
      advertising: statuses.any((s) => s.advertising),
      scanning: statuses.any((s) => s.scanning),
      connectedPeerCount: statuses.fold(0, (n, s) => n + s.connectedPeerCount),
      canAdvertise: statuses.any((s) => s.canAdvertise),
      detail: details.isEmpty ? null : details.join('. '),
    );
  }

  @override
  Future<void> start() async {
    startErrors.clear();
    for (final entry in _children.entries) {
      try {
        await entry.value.start();
      } on Object catch (error) {
        startErrors[entry.key] = error;
      }
    }
    _statusChanges.add(status);
  }

  @override
  Future<void> stop() async {
    for (final child in _children.values) {
      await child.stop();
    }
    _statusChanges.add(status);
  }

  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    if (toPeer != null) {
      final name = transportOf(toPeer);
      final child = name == null ? null : _children[name];
      // Dropped rather than thrown: a peer can vanish between the decision to
      // reply and the reply, and every call site would get the guard wrong.
      if (child == null) return;
      await child.send(frame, toPeer: peerOf(toPeer));
      return;
    }

    final excludeTransport = excludePeer == null
        ? null
        : transportOf(excludePeer);

    for (final entry in _children.entries) {
      await entry.value.send(
        frame,
        // The exclusion means "not back down the link this arrived on". That
        // link exists on one transport; on the others there is nothing to
        // exclude, and skipping them would drop a hop.
        excludePeer: entry.key == excludeTransport
            ? peerOf(excludePeer!)
            : null,
      );
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _inbound.close();
    await _peerEvents.close();
    await _statusChanges.close();
  }
}
