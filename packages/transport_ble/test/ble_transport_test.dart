import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_api/transport_api.dart' as api;
import 'package:transport_ble/transport_ble.dart';
import 'package:transport_ble/src/generated/ble_api.g.dart' as g;

/// A stand-in for the native side.
///
/// Subclassing the generated host API rather than mocking a channel keeps the
/// test honest about the real call signatures: if the Pigeon contract changes,
/// this stops compiling instead of silently passing.
class FakeHost extends g.BleHostApi {
  FakeHost({List<Uint8List>? inbox}) : inbox = inbox ?? [];

  final List<Uint8List> inbox;

  bool started = false;
  int? startedWithHash;
  String? startedWithPowerMode;
  bool stealth = false;
  bool wiped = false;
  String powerMode = 'balanced';
  final sent = <({Uint8List frame, String? target, String? exclude})>[];
  List<g.PeerInfo> peerList = const [];
  bool batteryExemptionNeeded = false;
  bool batterySettingsOpened = false;
  ({String nickname, Uint8List key})? announce;

  g.TransportStatus status = g.TransportStatus(
    running: false,
    adapterOn: true,
    permissionsGranted: true,
    advertising: false,
    scanning: false,
    connectedPeerCount: 0,
    canAdvertise: true,
    powerMode: 'balanced',
  );

  g.RelayStats stats = g.RelayStats(
    framesReceived: 0,
    framesRelayed: 0,
    framesDropped: 0,
    framesSuppressed: 0,
    storedForForward: 0,
    inboxDepth: 0,
  );

  bool permissionsGranted = true;
  bool bluetoothOn = true;
  bool permissionsAsked = false;
  bool enableRequested = false;

  /// What the user chooses when the dialog appears.
  bool grantOnRequest = true;

  @override
  Future<bool> hasPermissions() async => permissionsGranted;

  @override
  Future<bool> requestPermissions() async {
    permissionsAsked = true;
    permissionsGranted = grantOnRequest;
    return permissionsGranted;
  }

  @override
  Future<bool> isBluetoothEnabled() async => bluetoothOn;

  @override
  Future<void> requestEnableBluetooth() async => enableRequested = true;

  @override
  Future<void> start(int addressHash, String mode) async {
    started = true;
    startedWithHash = addressHash;
    startedWithPowerMode = mode;
    status.running = true;
  }

  @override
  Future<void> stop() async {
    started = false;
    status.running = false;
  }

  @override
  Future<void> sendFrame(
    Uint8List frame,
    String? targetPeerId,
    String? excludePeerId,
  ) async {
    sent.add((frame: frame, target: targetPeerId, exclude: excludePeerId));
  }

  @override
  Future<List<g.PeerInfo>> getPeers() async => peerList;

  @override
  Future<g.TransportStatus> getStatus() async => status;

  @override
  Future<g.RelayStats> getStats() async => stats;

  @override
  Future<List<Uint8List>> drainInbox() async {
    final drained = List<Uint8List>.from(inbox);
    inbox.clear();
    return drained;
  }

  @override
  Future<void> setPowerMode(String mode) async => powerMode = mode;

  @override
  Future<void> setStealthMode(bool enabled) async => stealth = enabled;

  @override
  Future<void> setAnnounce(String nickname, Uint8List signedSessionKey) async {
    announce = (nickname: nickname, key: signedSessionKey);
  }

  @override
  Future<void> wipe() async => wiped = true;

  @override
  Future<bool> needsBatteryExemption() async => batteryExemptionNeeded;

  @override
  Future<void> openBatterySettings() async => batterySettingsOpened = true;
}

g.PeerInfo peerInfo(String id, {int hops = 1, int? rssi}) => g.PeerInfo(
  peerId: id,
  hopDistance: hops,
  isDirect: hops == 1,
  lastSeenMillis: 1000,
  rssi: rssi,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHost host;
  late BleTransport transport;

  setUp(() {
    host = FakeHost();
    transport = BleTransport(
      addressHash: 0xABCD1234,
      hostApi: host,
      clock: () => DateTime.fromMillisecondsSinceEpoch(3000),
      registerHandler: false,
    );
  });

  tearDown(() => transport.dispose());

  test('start hands the local address and power mode to native', () async {
    await transport.start();

    expect(host.started, isTrue);
    expect(host.startedWithHash, 0xABCD1234);
    expect(host.startedWithPowerMode, 'balanced');
  });

  test('start drains frames that arrived while Dart was not running', () async {
    // The whole point of the native relay: messages addressed to this device
    // land in native storage while the app is closed. Losing them on launch
    // would make the app-closed case pointless.
    host = FakeHost(
      inbox: [
        Uint8List.fromList([1, 2, 3]),
      ],
    );
    transport = BleTransport(
      addressHash: 1,
      hostApi: host,
      registerHandler: false,
    );

    final received = <Uint8List>[];
    transport.inbound.listen((frame) => received.add(frame.bytes));

    await transport.start();
    await pumpEventQueue();

    expect(received, hasLength(1));
    expect(received.single, [1, 2, 3]);
  });

  test('frames pushed from native reach the inbound stream', () async {
    final received = <api.InboundFrame>[];
    transport.inbound.listen(received.add);

    transport.onFrameReceived(Uint8List.fromList([9, 9]), 'peer-a');
    await pumpEventQueue();

    expect(received.single.bytes, [9, 9]);
    expect(received.single.fromPeer, 'peer-a');
  });

  test('discovering a peer adds it and emits an event', () async {
    final events = <api.PeerEvent>[];
    transport.peerEvents.listen(events.add);

    transport.onPeerDiscovered(peerInfo('peer-a', rssi: -60));
    await pumpEventQueue();

    expect(transport.peers.single.peerId, 'peer-a');
    expect(transport.peers.single.rssi, -60);
    expect(transport.peers.single.isDirect, isTrue);
    expect(events.single.kind, api.PeerEventKind.discovered);
  });

  test(
    'rediscovering a known peer updates rather than duplicates it',
    () async {
      final events = <api.PeerEvent>[];
      transport.peerEvents.listen(events.add);

      transport.onPeerDiscovered(peerInfo('peer-a', hops: 1));
      transport.onPeerDiscovered(peerInfo('peer-a', hops: 3));
      await pumpEventQueue();

      expect(transport.peers, hasLength(1));
      expect(transport.peers.single.hopDistance, 3);
      expect(events.last.kind, api.PeerEventKind.updated);
    },
  );

  test('losing a peer removes it', () async {
    transport.onPeerDiscovered(peerInfo('peer-a'));
    transport.onPeerLost('peer-a');

    expect(transport.peers, isEmpty);
  });

  test('lastSeen is reported as an age, not a wall-clock instant', () {
    transport.onPeerDiscovered(peerInfo('peer-a'));

    // Peer last seen at 1000ms, clock at 3000ms.
    expect(transport.peers.single.lastSeen, const Duration(seconds: 2));
  });

  test('send forwards target and exclusion to native untouched', () async {
    await transport.send(
      Uint8List.fromList([7]),
      toPeer: 'peer-a',
      excludePeer: 'peer-b',
    );

    expect(host.sent.single.target, 'peer-a');
    expect(host.sent.single.exclude, 'peer-b');
  });

  test('a broadcast passes no target', () async {
    await transport.send(Uint8List.fromList([7]));

    expect(host.sent.single.target, isNull);
  });

  test('native status is translated and published', () async {
    final seen = <api.TransportStatus>[];
    transport.statusChanges.listen(seen.add);

    transport.onStatusChanged(
      g.TransportStatus(
        running: true,
        adapterOn: true,
        permissionsGranted: true,
        advertising: false,
        scanning: true,
        connectedPeerCount: 2,
        canAdvertise: false,
        powerMode: 'saver',
        detail: 'this device cannot advertise',
      ),
    );
    await pumpEventQueue();

    expect(transport.status.isHealthy, isTrue);
    expect(transport.status.canAdvertise, isFalse);
    expect(transport.status.detail, 'this device cannot advertise');
    expect(seen, hasLength(1));
  });

  test('status is unhealthy while Bluetooth is off', () {
    transport.onStatusChanged(
      g.TransportStatus(
        running: true,
        adapterOn: false,
        permissionsGranted: true,
        advertising: false,
        scanning: false,
        connectedPeerCount: 0,
        canAdvertise: true,
        powerMode: 'balanced',
      ),
    );

    expect(transport.status.isHealthy, isFalse);
  });

  test('stopping clears the peer list', () async {
    transport.onPeerDiscovered(peerInfo('peer-a'));

    await transport.stop();

    // Peers are session state. Keeping them after the radio stops would show
    // the user people they can no longer reach.
    expect(transport.peers, isEmpty);
    expect(host.started, isFalse);
  });

  test('stealth mode is forwarded to native', () async {
    await transport.setStealthMode(true);
    expect(host.stealth, isTrue);
  });

  test('wipe destroys native state too', () async {
    await transport.wipe();
    expect(host.wiped, isTrue);
  });

  test('stats are exposed for the diagnostics screen', () async {
    host.stats = g.RelayStats(
      framesReceived: 10,
      framesRelayed: 4,
      framesDropped: 1,
      framesSuppressed: 5,
      storedForForward: 2,
      inboxDepth: 0,
    );

    final stats = await transport.stats();

    expect(stats.framesRelayed, 4);
    expect(stats.framesSuppressed, 5);
  });

  test('requesting permissions surfaces the user\'s answer', () async {
    host.grantOnRequest = false;

    expect(await transport.requestPermissions(), isFalse);
    expect(host.permissionsAsked, isTrue);
  });

  test('starting without permissions does not touch the radio', () async {
    host.permissionsGranted = false;
    host.grantOnRequest = false;

    // Calling start anyway would have native throw a SecurityException on a
    // background thread, which surfaces to the user as the app dying.
    await expectLater(transport.start(), throwsA(isA<BleNotReadyException>()));
    expect(host.started, isFalse);
  });

  test(
    'starting with Bluetooth off reports that, not a generic failure',
    () async {
      host.permissionsGranted = true;
      host.bluetoothOn = false;

      await expectLater(
        transport.start(),
        throwsA(
          isA<BleNotReadyException>().having(
            (e) => e.reason,
            'reason',
            BleNotReady.bluetoothOff,
          ),
        ),
      );
    },
  );

  test(
    'start proceeds once permissions and Bluetooth are both in place',
    () async {
      host.permissionsGranted = true;
      host.bluetoothOn = true;

      await transport.start();

      expect(host.started, isTrue);
    },
  );

  test('asking to enable Bluetooth reaches the OS', () async {
    await transport.requestEnableBluetooth();
    expect(host.enableRequested, isTrue);
  });

  test('power mode changes are forwarded and remembered', () async {
    await transport.setPowerMode('saver');

    expect(host.powerMode, 'saver');

    // A restart must not silently revert to the default.
    await transport.start();
    expect(host.startedWithPowerMode, 'saver');
  });
}
