import 'dart:async';

import 'package:meta/meta.dart';

/// Another device advertising Relay on this network.
@immutable
class DiscoveredService {
  const DiscoveredService({
    required this.instanceId,
    required this.host,
    required this.port,
    required this.addressHash,
  });

  /// Random per session, and the only reliable way to recognise our own
  /// advertisement coming back to us.
  ///
  /// Filtering by address hash would be wrong: it is 32 bits, so two devices in
  /// a crowd can share one, and the collision would make each of them invisible
  /// to the other rather than merely confused.
  final String instanceId;

  final String host;
  final int port;

  /// The mesh address the device claims. Unverified at this layer — the link's
  /// hello is what the transport actually trusts, and even that is only a
  /// routing hint until the Noise handshake proves who is there.
  final int addressHash;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredService &&
      other.instanceId == instanceId &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(instanceId, host, port);

  @override
  String toString() => 'DiscoveredService($instanceId at $host:$port)';
}

/// Why the local network cannot be used.
enum LanUnavailable {
  permissionDenied(
    'The app needs permission to find devices on your Wi-Fi network',
  ),
  noNetwork('Not connected to Wi-Fi');

  const LanUnavailable(this.message);

  /// Plain language, ready to show. Both are fixable by the user.
  final String message;
}

/// Finding peers on the local network, and being findable.
///
/// Separated from the transport because the two halves have nothing in common:
/// this one is entirely platform code (Android's NsdManager, Apple's Bonjour),
/// and the transport below it is pure Dart sockets. Keeping them apart is what
/// lets the transport be tested against a real TCP stack with no plugin loaded.
abstract interface class LanDiscovery {
  /// Peers appearing. Replays nothing: a subscriber must be attached first.
  Stream<DiscoveredService> get found;

  /// Instance ids of peers whose advertisement went away.
  ///
  /// Advisory only. mDNS is unreliable about departures, so the transport must
  /// not depend on this to notice a peer has gone — the socket closing is the
  /// authoritative signal.
  Stream<String> get lost;

  /// True once the platform has confirmed the local network is usable.
  bool get isAvailable;

  /// Why not, when [isAvailable] is false.
  LanUnavailable? get unavailableReason;

  /// Publishes this device. Called again with a new port after a restart.
  Future<void> advertise({
    required String instanceId,
    required int addressHash,
    required int port,
  });

  /// Withdraws the advertisement. Used by stealth mode, where the device must
  /// still be able to carry other people's traffic without announcing itself.
  Future<void> stopAdvertising();

  Future<void> browse();

  Future<void> stopBrowsing();

  Future<void> dispose();
}
