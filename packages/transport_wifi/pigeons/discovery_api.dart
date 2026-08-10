// Pigeon contract for local-network discovery.
//
// Regenerate with:
//   dart run pigeon --input packages/transport_wifi/pigeons/discovery_api.dart
//
// Narrower than the BLE contract on purpose. Native does discovery and nothing
// else: it publishes an mDNS service and reports the ones it finds. The sockets
// are pure Dart, because `dart:io` speaks TCP identically on both platforms and
// there is no reason to write that twice in two languages.
//
// mDNS specifically, rather than a UDP broadcast beacon: since iOS 14, sending
// or receiving multicast and broadcast requires an entitlement Apple grants by
// application, while Bonjour needs only a usage string. Android's NsdManager
// speaks the same protocol, so one contract covers both.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/discovery_api.g.dart',
    kotlinOut:
        '../../app/android/app/src/main/kotlin/dev/kishorek/relay/wifi/DiscoveryApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.kishorek.relay.wifi'),
    swiftOut: '../../app/ios/Runner/Wifi/DiscoveryApi.g.swift',
    // Both generated Swift files land in the same app target, and Pigeon names
    // its error class `PigeonError` by default. Two of those in one module is
    // a duplicate declaration that makes every generated call ambiguous.
    swiftOptions: SwiftOptions(errorClassName: 'DiscoveryPigeonError'),
    dartPackageName: 'transport_wifi',
  ),
)
/// Another device advertising Relay on the local network.
class ServiceInfo {
  ServiceInfo({
    required this.instanceId,
    required this.host,
    required this.port,
    required this.addressHash,
  });

  /// Random per run. The only reliable way to recognise our own advertisement:
  /// the address hash is 32 bits and collides, and matching on it would make
  /// two colliding devices invisible to each other rather than merely confused.
  String instanceId;

  /// Resolved address. Already an IP — an unresolved hostname would make the
  /// Dart side do a DNS lookup that cannot succeed on a network with no DNS.
  String host;

  int port;

  /// The mesh address the device claims. A routing hint only; the link hello
  /// and then the Noise handshake are what actually establish who is there.
  int addressHash;
}

/// Why the local network cannot be used. Both cases are the user's to fix, so
/// they are reported separately rather than as one failure.
enum DiscoveryUnavailable {
  /// iOS local-network permission refused, or Android NSD unavailable.
  permissionDenied,

  /// No Wi-Fi. Cellular does not count: there are no peers on it.
  noNetwork,
}

@HostApi()
abstract class DiscoveryHostApi {
  /// Whether discovery can run right now.
  bool isAvailable();

  /// Why not. Null when [isAvailable] is true.
  DiscoveryUnavailable? unavailableReason();

  /// Publishes this device on the local network.
  ///
  /// Asynchronous because registration is confirmed by a platform callback, and
  /// reporting success before the platform has agreed would make the UI claim
  /// the device is findable when it is not.
  @async
  void advertise(String instanceId, int addressHash, int port);

  @async
  void stopAdvertising();

  @async
  void browse();

  @async
  void stopBrowsing();
}

@FlutterApi()
abstract class DiscoveryFlutterApi {
  void onServiceFound(ServiceInfo service);

  /// Advisory. mDNS is unreliable about departures, so this is a hint to stop
  /// dialling — never a reason to consider a peer gone. The socket closing is
  /// the authoritative signal.
  void onServiceLost(String instanceId);

  void onAvailabilityChanged(bool available, DiscoveryUnavailable? reason);
}
