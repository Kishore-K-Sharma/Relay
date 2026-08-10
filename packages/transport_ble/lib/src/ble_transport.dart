import 'dart:async';
import 'dart:typed_data';

import 'package:transport_api/transport_api.dart' as api;

import 'generated/ble_api.g.dart' as g;

/// Relay counters, surfaced so mesh trouble is visible instead of mysterious.
class BleRelayStats {
  const BleRelayStats({
    required this.framesReceived,
    required this.framesRelayed,
    required this.framesDropped,
    required this.framesSuppressed,
    required this.storedForForward,
    required this.inboxDepth,
  });

  final int framesReceived;
  final int framesRelayed;
  final int framesDropped;
  final int framesSuppressed;
  final int storedForForward;
  final int inboxDepth;

  static const empty = BleRelayStats(
    framesReceived: 0,
    framesRelayed: 0,
    framesDropped: 0,
    framesSuppressed: 0,
    storedForForward: 0,
    inboxDepth: 0,
  );
}

/// Why the radio could not be started.
enum BleNotReady {
  permissionsDenied('The app needs Bluetooth permission to find people nearby'),
  bluetoothOff('Bluetooth is off');

  const BleNotReady(this.message);

  /// Plain language, ready to show. Both cases are fixable by the user, so the
  /// UI must say which one it is rather than reporting a generic failure.
  final String message;
}

class BleNotReadyException implements Exception {
  const BleNotReadyException(this.reason);

  final BleNotReady reason;

  @override
  String toString() => 'BleNotReadyException: ${reason.message}';
}

/// The Bluetooth LE mesh transport.
///
/// This class is a translator and nothing more. It converts between the Pigeon
/// types and the transport-agnostic ones in `transport_api`, and holds the
/// peer table so callers do not have to make a platform call to read it. Every
/// decision about *what* to send lives above it; every decision about *how* to
/// drive the radio lives below it in native code.
class BleTransport implements api.Transport, g.BleFlutterApi {
  BleTransport({
    required this.addressHash,
    g.BleHostApi? hostApi,
    DateTime Function()? clock,
    String powerMode = 'balanced',

    /// Registers this object to receive native callbacks. Tests drive the
    /// callbacks directly and pass false to stay off the binary messenger.
    bool registerHandler = true,
  }) : _host = hostApi ?? g.BleHostApi(),
       _clock = clock ?? DateTime.now,
       _powerMode = powerMode {
    if (registerHandler) g.BleFlutterApi.setUp(this);
  }

  /// This device's truncated session address. Native needs it to decide which
  /// frames are terminal and must be stored for Dart rather than relayed on.
  final int addressHash;

  final g.BleHostApi _host;
  final DateTime Function() _clock;

  String _powerMode;

  final _peers = <String, api.TransportPeer>{};
  final _inbound = StreamController<api.InboundFrame>.broadcast();
  final _peerEvents = StreamController<api.PeerEvent>.broadcast();
  final _statusChanges = StreamController<api.TransportStatus>.broadcast();

  api.TransportStatus _status = const api.TransportStatus.stopped();

  @override
  Stream<api.InboundFrame> get inbound => _inbound.stream;

  @override
  Stream<api.PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Stream<api.TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  List<api.TransportPeer> get peers => List.unmodifiable(_peers.values);

  @override
  api.TransportStatus get status => _status;

  String get powerMode => _powerMode;

  Future<bool> hasPermissions() => _host.hasPermissions();

  /// Shows the system permission dialog and reports what the user chose.
  Future<bool> requestPermissions() => _host.requestPermissions();

  Future<bool> isBluetoothEnabled() => _host.isBluetoothEnabled();

  /// Asks the OS to prompt the user to turn Bluetooth on.
  Future<void> requestEnableBluetooth() => _host.requestEnableBluetooth();

  /// Starts the radio.
  ///
  /// Throws [BleNotReadyException] rather than starting into a state that
  /// cannot work. Calling into the platform without permission makes Android
  /// throw a SecurityException on a BLE callback thread, which reaches the user
  /// as the app dying with no explanation.
  @override
  Future<void> start() async {
    if (!await _host.hasPermissions()) {
      throw const BleNotReadyException(BleNotReady.permissionsDenied);
    }
    if (!await _host.isBluetoothEnabled()) {
      throw const BleNotReadyException(BleNotReady.bluetoothOff);
    }

    await _host.start(addressHash, _powerMode);
    await _refreshStatus();
    await _refreshPeers();
    await drainInbox();
  }

  @override
  Future<void> stop() async {
    await _host.stop();
    // Peers are session state. Leaving them on screen after the radio stops
    // would show people the user can no longer reach.
    _peers.clear();
    await _refreshStatus();
  }

  @override
  Future<void> send(Uint8List frame, {String? toPeer, String? excludePeer}) =>
      _host.sendFrame(frame, toPeer, excludePeer);

  /// Pulls in frames that native stored while the Dart isolate was not running.
  ///
  /// This is what makes the app-closed case work: without it, everything
  /// addressed to this device during that window is silently lost.
  Future<int> drainInbox() async {
    final frames = await _host.drainInbox();
    for (final bytes in frames) {
      _inbound.add(api.InboundFrame(bytes: bytes, fromPeer: 'stored'));
    }
    return frames.length;
  }

  Future<BleRelayStats> stats() async {
    final s = await _host.getStats();
    return BleRelayStats(
      framesReceived: s.framesReceived,
      framesRelayed: s.framesRelayed,
      framesDropped: s.framesDropped,
      framesSuppressed: s.framesSuppressed,
      storedForForward: s.storedForForward,
      inboxDepth: s.inboxDepth,
    );
  }

  Future<void> setPowerMode(String mode) async {
    _powerMode = mode;
    await _host.setPowerMode(mode);
  }

  /// Stops advertising and presence while continuing to relay for others.
  /// Continuing to relay is what provides the cover.
  Future<void> setStealthMode(bool enabled) => _host.setStealthMode(enabled);

  /// Sets the presence beacon. An empty nickname suppresses it entirely.
  Future<void> setAnnounce(String nickname, Uint8List signedSessionKey) =>
      _host.setAnnounce(nickname, signedSessionKey);

  /// Destroys native inbox, store-and-forward queue and dedup table.
  /// Part of panic wipe; irreversible.
  Future<void> wipe() => _host.wipe();

  Future<bool> needsBatteryExemption() => _host.needsBatteryExemption();

  Future<void> openBatterySettings() => _host.openBatterySettings();

  Future<void> refresh() async {
    await _refreshStatus();
    await _refreshPeers();
  }

  Future<void> _refreshStatus() async {
    _publishStatus(_translate(await _host.getStatus()));
  }

  Future<void> _refreshPeers() async {
    for (final peer in await _host.getPeers()) {
      onPeerDiscovered(peer);
    }
  }

  void _publishStatus(api.TransportStatus status) {
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  api.TransportStatus _translate(g.TransportStatus s) => api.TransportStatus(
    running: s.running,
    adapterOn: s.adapterOn,
    permissionsGranted: s.permissionsGranted,
    advertising: s.advertising,
    scanning: s.scanning,
    connectedPeerCount: s.connectedPeerCount,
    canAdvertise: s.canAdvertise,
    detail: s.detail,
  );

  // ------------------------------------------------------- native callbacks

  @override
  void onFrameReceived(Uint8List frame, String fromPeerId) {
    if (_inbound.isClosed) return;
    _inbound.add(api.InboundFrame(bytes: frame, fromPeer: fromPeerId));
  }

  @override
  void onPeerDiscovered(g.PeerInfo peer) {
    final known = _peers.containsKey(peer.peerId);
    final translated = api.TransportPeer(
      peerId: peer.peerId,
      hopDistance: peer.hopDistance,
      rssi: peer.rssi,
      // An age, not a wall-clock instant: the UI shows "seen 2s ago", and a
      // raw timestamp would put the conversion in every call site.
      lastSeen: Duration(
        milliseconds: (_clock().millisecondsSinceEpoch - peer.lastSeenMillis)
            .clamp(0, 1 << 40),
      ),
    );

    _peers[peer.peerId] = translated;
    if (_peerEvents.isClosed) return;
    _peerEvents.add(
      api.PeerEvent(
        known ? api.PeerEventKind.updated : api.PeerEventKind.discovered,
        translated,
      ),
    );
  }

  @override
  void onPeerLost(String peerId) {
    final peer = _peers.remove(peerId);
    if (peer == null || _peerEvents.isClosed) return;
    _peerEvents.add(api.PeerEvent(api.PeerEventKind.lost, peer));
  }

  @override
  void onStatusChanged(g.TransportStatus status) =>
      _publishStatus(_translate(status));

  Future<void> dispose() async {
    await _inbound.close();
    await _peerEvents.close();
    await _statusChanges.close();
  }
}
