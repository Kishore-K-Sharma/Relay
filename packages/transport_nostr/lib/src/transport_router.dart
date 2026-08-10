import 'dart:async';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:transport_api/transport_api.dart';

/// Which path a frame took. Always surfaced to the user: "delivered over
/// Bluetooth" and "delivered via a relay server" have different privacy
/// consequences, and hiding the difference would be dishonest.
enum TransportKind { mesh, relay }

class RouteResult {
  const RouteResult({required this.kind, required this.accepted, this.reason});

  final TransportKind kind;
  final bool accepted;
  final String? reason;
}

/// Chooses between the Bluetooth mesh and the internet relay.
///
/// Rules, in order:
///  1. If the destination is reachable over the mesh, use the mesh. It is
///     faster, private, and costs nobody any infrastructure.
///  2. Otherwise use the relay, if one is available and stealth mode is off.
///  3. Otherwise queue and report honestly that nothing was sent.
///
/// A frame may arrive by both paths. Duplicate suppression is the receiver's
/// job, keyed on the application message identity rather than [MsgId], because
/// a relayed copy is a separate transmission with its own id.
class TransportRouter {
  TransportRouter({
    required Transport mesh,
    Transport? relay,
    this.stealthMode = false,
  }) : _mesh = mesh,
       _relay = relay;

  final Transport _mesh;
  final Transport? _relay;

  /// When true the relay is never used, and only Bluetooth is touched.
  bool stealthMode;

  Transport get mesh => _mesh;
  Transport? get relay => _relay;

  bool get relayAvailable =>
      !stealthMode && _relay != null && _relay.status.isHealthy;

  bool reachableOverMesh(String peerId) =>
      _mesh.peers.any((peer) => peer.peerId == peerId);

  /// Sends [frame], choosing a path.
  ///
  /// [allowRelay] is the caller's decision about this particular recipient, not
  /// a capability check. The relay works by handing a third party the fact that
  /// two identities are talking and when — metadata the mesh never produces —
  /// so the app spends it only on people the user deliberately chose. The
  /// router cannot make that judgement itself and does not try.
  Future<RouteResult> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
    bool allowRelay = true,
  }) async {
    final meshUsable = _mesh.status.isHealthy;

    // Broadcasts always go to the mesh; they are meaningless to a relay, which
    // has no notion of "everyone physically near me".
    if (toPeer == null) {
      if (!meshUsable) {
        return const RouteResult(
          kind: TransportKind.mesh,
          accepted: false,
          reason: 'Bluetooth is unavailable',
        );
      }
      await _mesh.send(frame, excludePeer: excludePeer);
      return const RouteResult(kind: TransportKind.mesh, accepted: true);
    }

    if (meshUsable && reachableOverMesh(toPeer)) {
      await _mesh.send(frame, toPeer: toPeer, excludePeer: excludePeer);
      return const RouteResult(kind: TransportKind.mesh, accepted: true);
    }

    if (relayAvailable && allowRelay) {
      await _relay!.send(frame, toPeer: toPeer);
      return const RouteResult(kind: TransportKind.relay, accepted: true);
    }

    return RouteResult(
      kind: TransportKind.mesh,
      accepted: false,
      reason: stealthMode
          ? 'out of Bluetooth range, and stealth mode blocks the internet relay'
          : !allowRelay && relayAvailable
          ? 'out of range — mark them a favourite to reach them over the '
                'internet as well'
          : 'out of Bluetooth range and no relay is reachable',
    );
  }

  /// Frames from every transport, tagged with how they arrived.
  Stream<({InboundFrame frame, TransportKind kind})> get inbound {
    final controller =
        StreamController<
          ({InboundFrame frame, TransportKind kind})
        >.broadcast();

    final subscriptions = <StreamSubscription<InboundFrame>>[
      _mesh.inbound.listen(
        (f) => controller.add((frame: f, kind: TransportKind.mesh)),
      ),
      if (_relay != null)
        _relay.inbound.listen(
          (f) => controller.add((frame: f, kind: TransportKind.relay)),
        ),
    ];

    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };

    return controller.stream;
  }
}

/// End-to-end duplicate suppression across transports.
///
/// The relay-level [DedupSet] cannot do this job: a retry, or the same message
/// arriving over both Bluetooth and the internet, carries a different [MsgId]
/// each time. Only the sender identity plus their message sequence identifies
/// the message itself.
class MessageDeduplicator {
  MessageDeduplicator({this.maxEntries = 4000});

  final int maxEntries;
  final _seen = <String>{};
  final _order = <String>[];

  /// Returns true when this is the first time the message has been seen.
  bool accept({required Uint8List senderKey, required int sequence}) {
    final key = '${_hex(senderKey)}:$sequence';
    if (!_seen.add(key)) return false;

    _order.add(key);
    while (_order.length > maxEntries) {
      _seen.remove(_order.removeAt(0));
    }
    return true;
  }

  void clear() {
    _seen.clear();
    _order.clear();
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
