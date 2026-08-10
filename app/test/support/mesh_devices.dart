import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:data/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/runtime/runtime.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_wifi/testing.dart';
import 'package:transport_wifi/transport_wifi.dart';

/// Whole devices, assembled the way the app assembles them.
///
/// Real Noise handshakes, real databases, real TCP sockets on loopback. Only
/// mDNS is faked, because it is the one part that cannot run without a platform
/// plugin. Shared between the transport tests and the group tests so both are
/// exercising the same stack the app ships.
class SilentBluetooth implements Transport {
  SilentBluetooth({this.healthy = false});

  final bool healthy;

  @override
  Stream<InboundFrame> get inbound => const Stream.empty();
  @override
  Stream<PeerEvent> get peerEvents => const Stream.empty();
  @override
  Stream<TransportStatus> get statusChanges => const Stream.empty();
  @override
  List<TransportPeer> get peers => const [];

  @override
  /// Permission granted, radio switched off — the scenario these tests are
  /// about. A refused permission is a different message and a different fix.
  @override
  TransportStatus get status => TransportStatus(
    running: healthy,
    adapterOn: healthy,
    permissionsGranted: true,
    advertising: healthy,
    scanning: healthy,
    connectedPeerCount: 0,
    detail: healthy ? null : 'Bluetooth is off',
  );

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {}
}

class Device {
  Device._(this.state, this.store, this.wifi, this.runtime);

  static Future<Device> create(
    String name,
    FakeLanNetwork network, {
    bool bluetooth = false,

    /// Lets a test step over the outbox backoff instead of sleeping through
    /// it. Real time everywhere else, because the sockets are real.
    DateTime Function()? clock,
  }) async {
    final state = AppState(nickname: name);
    final store = LocalStore.open();
    final identity = await MeshIdentity.generate();
    final noiseKey = Uint8List.fromList(
      List.generate(32, (i) => (name.codeUnitAt(0) + i) % 256),
    );
    final addressHash = await addressHashOf(identity.publicKey);

    final wifi = WifiTransport(
      addressHash: addressHash,
      discovery: network.join(),
      helloTimeout: const Duration(seconds: 2),
    );

    final runtime = MeshRuntime(
      state: state,
      store: store,
      mesh: SilentBluetooth(healthy: bluetooth),
      wifi: wifi,
      identity: identity,
      noiseStaticKey: noiseKey,
      localAddressHash: addressHash,
      clock: clock,
    );
    await wifi.start();
    await runtime.start();
    return Device._(state, store, wifi, runtime).._noiseKey = noiseKey;
  }

  final AppState state;
  final LocalStore store;
  final WifiTransport wifi;
  final MeshRuntime runtime;

  /// This device's X25519 private key.
  ///
  /// Held here rather than exposed on the runtime: a test that needs to seal
  /// something as this device should reach into the harness for the secret,
  /// not put a getter for one on the production object.
  Uint8List get noiseKey => _noiseKey;
  late Uint8List _noiseKey;

  Future<void> dispose() async {
    await runtime.stop();
    await wifi.dispose();
    store.close();
  }
}

Future<void> settle() => pumpEventQueue(times: 40);

/// Waits for [check], failing the test rather than hanging forever.
Future<void> until(bool Function() check, String describe) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await settle();
  }
}

/// The conversation [from] can use to reply to whoever has announced.
///
/// Waiting for "a peer appeared" is not enough and produces a flaky test: the
/// link creates a peer the instant the socket connects, but there is nowhere
/// to send until that peer announces a mesh address.
Future<String> conversationOnceAnnounced(Device from) async {
  String? found;
  await until(() {
    for (final peer in from.state.peers) {
      final conversation = from.runtime.conversationForPeer(peer.id);
      if (conversation != null) {
        found = conversation.id;
        return true;
      }
    }
    return false;
  }, 'an announced peer to reply to');
  return found!;
}
