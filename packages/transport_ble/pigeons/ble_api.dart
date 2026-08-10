// Pigeon contract for the BLE transport.
//
// Regenerate with:
//   dart run pigeon --input packages/transport_ble/pigeons/ble_api.dart
//
// The contract is deliberately narrow. Native exposes a byte pipe and peer
// events; it never learns what a frame means. Everything above the radio —
// protocol, crypto, routing policy — lives in Dart, except the opaque relay,
// which must survive the Dart isolate being dead.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/ble_api.g.dart',
    kotlinOut:
        '../../app/android/app/src/main/kotlin/dev/kishorek/relay/ble/BleApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.kishorek.relay.ble'),
    swiftOut: '../../app/ios/Runner/Ble/BleApi.g.swift',
    dartPackageName: 'transport_ble',
  ),
)
/// A peer currently reachable over the mesh.
class PeerInfo {
  PeerInfo({
    required this.peerId,
    required this.hopDistance,
    required this.isDirect,
    required this.lastSeenMillis,
    this.rssi,
    this.nickname,
    this.sessionKeyHash,
  });

  /// Stable for the duration of a session only, never across sessions.
  String peerId;

  /// 1 means a direct radio connection.
  int hopDistance;

  bool isDirect;
  int lastSeenMillis;
  int? rssi;
  String? nickname;

  /// Truncated address hash this peer advertises.
  int? sessionKeyHash;
}

/// Current transport health. Every degraded state is surfaced, never swallowed.
class TransportStatus {
  TransportStatus({
    required this.running,
    required this.adapterOn,
    required this.permissionsGranted,
    required this.advertising,
    required this.scanning,
    required this.connectedPeerCount,
    required this.canAdvertise,
    required this.powerMode,
    this.detail,
  });

  bool running;
  bool adapterOn;
  bool permissionsGranted;
  bool advertising;
  bool scanning;
  int connectedPeerCount;

  /// False on hardware with no BLE peripheral support. Such a device can still
  /// receive and relay, but cannot be discovered — the UI must say so.
  bool canAdvertise;

  /// "performance" | "balanced" | "saver"
  String powerMode;

  String? detail;
}

/// Counters for the diagnostics screen. Mesh problems are otherwise invisible.
class RelayStats {
  RelayStats({
    required this.framesReceived,
    required this.framesRelayed,
    required this.framesDropped,
    required this.framesSuppressed,
    required this.storedForForward,
    required this.inboxDepth,
  });

  int framesReceived;
  int framesRelayed;
  int framesDropped;
  int framesSuppressed;
  int storedForForward;
  int inboxDepth;
}

@HostApi()
abstract class BleHostApi {
  /// Whether every runtime permission the mesh needs has been granted.
  bool hasPermissions();

  /// Shows the system permission dialog and resolves with the outcome.
  ///
  /// Asynchronous because the answer arrives on an activity callback, which may
  /// be many seconds later or never — the user can leave the dialog on screen.
  @async
  bool requestPermissions();

  bool isBluetoothEnabled();

  /// Asks the OS to turn Bluetooth on. Never forces it: an app silently
  /// enabling a radio is exactly the behaviour this one exists to avoid.
  void requestEnableBluetooth();

  /// Starts the radio and the foreground relay.
  ///
  /// [addressHash] is this device's truncated session address; native needs it
  /// to decide which frames are terminal and must be persisted for Dart.
  void start(int addressHash, String powerMode);

  void stop();

  /// Queues a frame. [targetPeerId] null means broadcast to every peer;
  /// [excludePeerId] omits one, used so a relayed frame is never echoed back.
  void sendFrame(Uint8List frame, String? targetPeerId, String? excludePeerId);

  List<PeerInfo> getPeers();

  TransportStatus getStatus();

  RelayStats getStats();

  /// Drains frames addressed to this device that arrived while Dart was not
  /// running. This is what makes the app-closed case work.
  List<Uint8List> drainInbox();

  void setPowerMode(String mode);

  /// Stealth mode: stop advertising and presence, keep relaying for others.
  /// Continuing to relay is what provides cover.
  void setStealthMode(bool enabled);

  /// Sets the presence beacon contents. Empty nickname suppresses the beacon.
  void setAnnounce(String nickname, Uint8List signedSessionKey);

  /// Destroys all native state: inbox, store-and-forward queue, dedup table.
  /// Part of panic wipe; irreversible.
  void wipe();

  /// True when the OS is likely to kill the relay service. Drives the
  /// per-manufacturer battery-exemption prompt.
  bool needsBatteryExemption();

  void openBatterySettings();
}

@FlutterApi()
abstract class BleFlutterApi {
  void onFrameReceived(Uint8List frame, String fromPeerId);
  void onPeerDiscovered(PeerInfo peer);
  void onPeerLost(String peerId);
  void onStatusChanged(TransportStatus status);
}
