import 'dart:typed_data';

import 'package:meta/meta.dart';

/// How a transport is currently behaving. Surfaced to the UI so degraded states
/// are always visible rather than silently swallowed.
@immutable
class TransportStatus {
  const TransportStatus({
    required this.running,
    required this.adapterOn,
    required this.permissionsGranted,
    required this.advertising,
    required this.scanning,
    required this.connectedPeerCount,
    this.canAdvertise = true,
    this.detail,
  });

  const TransportStatus.stopped()
    : running = false,
      adapterOn = false,
      permissionsGranted = false,
      advertising = false,
      scanning = false,
      connectedPeerCount = 0,
      canAdvertise = true,
      detail = null;

  final bool running;
  final bool adapterOn;
  final bool permissionsGranted;
  final bool advertising;
  final bool scanning;
  final int connectedPeerCount;

  /// False on hardware with no BLE peripheral support. Such a device can still
  /// receive and relay but cannot be discovered, and the UI must say so.
  final bool canAdvertise;

  /// Human-readable explanation of a degraded state, if any.
  final String? detail;

  bool get isHealthy => running && adapterOn && permissionsGranted;
}

/// A reachable peer.
@immutable
class TransportPeer {
  const TransportPeer({
    required this.peerId,
    required this.hopDistance,
    this.rssi,
    this.lastSeen,
  });

  /// Stable for the lifetime of a session, not across sessions.
  final String peerId;

  /// 1 means a direct radio connection.
  final int hopDistance;

  /// Signal strength in dBm where the transport can measure it.
  final int? rssi;

  final Duration? lastSeen;

  bool get isDirect => hopDistance == 1;

  @override
  bool operator ==(Object other) =>
      other is TransportPeer && other.peerId == peerId;

  @override
  int get hashCode => peerId.hashCode;
}

/// A frame as it arrived, still opaque.
@immutable
class InboundFrame {
  const InboundFrame({required this.bytes, required this.fromPeer});

  final Uint8List bytes;
  final String fromPeer;
}

enum PeerEventKind { discovered, lost, updated }

@immutable
class PeerEvent {
  const PeerEvent(this.kind, this.peer);
  final PeerEventKind kind;
  final TransportPeer peer;
}

/// Moves opaque frames between devices.
abstract interface class Transport {
  /// Frames arriving from other devices.
  Stream<InboundFrame> get inbound;

  /// Peers appearing, disappearing, or changing distance.
  Stream<PeerEvent> get peerEvents;

  /// Frames currently reachable peers.
  List<TransportPeer> get peers;

  TransportStatus get status;

  Stream<TransportStatus> get statusChanges;

  Future<void> start();

  Future<void> stop();

  /// Sends [frame] to [toPeer], or to every reachable peer when null.
  ///
  /// [excludePeer] omits one peer from a broadcast — used so a relayed frame is
  /// never echoed back to the device it came from.
  Future<void> send(Uint8List frame, {String? toPeer, String? excludePeer});
}
