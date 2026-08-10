import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_wifi/testing.dart';
import 'package:transport_wifi/transport_wifi.dart';

/// Two real transports, real TCP sockets on loopback, a fake mDNS between them.
///
/// Only the discovery half is faked, because it is the only half that cannot
/// run without a platform plugin. Everything the transport actually does —
/// listening, dialling, framing, resolving a duplicate connection — happens for
/// real here.
void main() {
  late FakeLanNetwork network;
  final started = <WifiTransport>[];

  setUp(() => network = FakeLanNetwork());

  tearDown(() async {
    for (final transport in started) {
      await transport.stop();
      await transport.dispose();
    }
    started.clear();
  });

  Future<WifiTransport> device(int addressHash, {bool start = true}) async {
    final transport = WifiTransport(
      addressHash: addressHash,
      discovery: network.join(),
      helloTimeout: const Duration(seconds: 2),
    );
    started.add(transport);
    if (start) await transport.start();
    return transport;
  }

  /// Waits for [transport] to see [count] peers, or fails the test.
  Future<void> awaitPeers(WifiTransport transport, int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (transport.peers.length != count) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'expected $count peers, saw ${transport.peers.length} '
          '(${transport.peers.map((p) => p.peerId).join(', ')})',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('two devices on the same network find each other', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);

    await awaitPeers(a, 1);
    await awaitPeers(b, 1);

    expect(a.peers.single.peerId, contains('bbbb'));
    expect(b.peers.single.peerId, contains('aaaa'));
  });

  test('a peer on the same network is one hop, never relayed', () async {
    // Everyone on a router reaches everyone else directly. Reporting a hop
    // count above one would make the UI claim a relay that is not happening.
    final a = await device(0xAAAA);
    await device(0xBBBB);
    await awaitPeers(a, 1);

    expect(a.peers.single.hopDistance, 1);
    expect(a.peers.single.isDirect, isTrue);
  });

  test('a frame sent to a peer arrives byte for byte', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    await awaitPeers(a, 1);
    await awaitPeers(b, 1);

    final received = b.inbound.first;
    await a.send(Uint8List.fromList([7, 7, 9]), toPeer: a.peers.single.peerId);

    final frame = await received.timeout(const Duration(seconds: 5));
    expect(frame.bytes, [7, 7, 9]);
    expect(frame.fromPeer, contains('aaaa'));
  });

  test('a broadcast reaches every peer', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    final c = await device(0xCCCC);
    await awaitPeers(a, 2);

    final atB = b.inbound.first;
    final atC = c.inbound.first;
    await a.send(Uint8List.fromList([1]));

    expect((await atB.timeout(const Duration(seconds: 5))).bytes, [1]);
    expect((await atC.timeout(const Duration(seconds: 5))).bytes, [1]);
  });

  test('excludePeer keeps a relayed frame from going back where it came '
      'from', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    final c = await device(0xCCCC);
    await awaitPeers(a, 2);
    await awaitPeers(b, 2);

    final atB = <Uint8List>[];
    b.inbound.listen((f) => atB.add(f.bytes));
    final atC = c.inbound.first;

    await a.send(
      Uint8List.fromList([1]),
      excludePeer: a.peers.firstWhere((p) => p.peerId.contains('bbbb')).peerId,
    );

    await atC.timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(atB, isEmpty);
  });

  test('a directed frame goes to that peer only', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    final c = await device(0xCCCC);
    await awaitPeers(a, 2);
    await awaitPeers(c, 2);

    final atC = <Uint8List>[];
    c.inbound.listen((f) => atC.add(f.bytes));
    final atB = b.inbound.first;

    await a.send(
      Uint8List.fromList([2]),
      toPeer: a.peers.firstWhere((p) => p.peerId.contains('bbbb')).peerId,
    );

    await atB.timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(atC, isEmpty);
  });

  test('a device does not connect to itself', () async {
    final a = await device(0xAAAA);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(a.peers, isEmpty);
    expect(a.linkCount, 0);
  });

  test('two devices dialling at once end up with one link each', () async {
    // The normal case, not an edge case: both sides discover each other in the
    // same instant and both dial. Left alone that is two sockets, two peer
    // entries, and every broadcast sent twice.
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);

    await awaitPeers(a, 1);
    await awaitPeers(b, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(a.linkCount, 1);
    expect(b.linkCount, 1);
  });

  test('both sides keep the same one of the two connections', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    await awaitPeers(a, 1);
    await awaitPeers(b, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Disagreeing here means each side keeps the socket the other closed, and
    // nothing is delivered in either direction.
    expect(a.dialedByUs(b.addressHash), isNot(b.dialedByUs(a.addressHash)));

    final atB = b.inbound.first;
    await a.send(Uint8List.fromList([5]), toPeer: a.peers.single.peerId);
    expect((await atB.timeout(const Duration(seconds: 5))).bytes, [5]);
  });

  test('a peer that stops is reported lost', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    await awaitPeers(a, 1);

    final lost = a.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.lost)
        .timeout(const Duration(seconds: 5));

    await b.stop();

    expect((await lost).peer.peerId, contains('bbbb'));
    expect(a.peers, isEmpty);
  });

  test('discovery is announced to listeners as it happens', () async {
    final a = await device(0xAAAA);
    final discovered = a.peerEvents
        .firstWhere((e) => e.kind == PeerEventKind.discovered)
        .timeout(const Duration(seconds: 5));

    await device(0xBBBB);

    expect((await discovered).peer.peerId, contains('bbbb'));
  });

  test('stealth mode withdraws the advertisement', () async {
    final discovery = network.join();
    final a = WifiTransport(addressHash: 0xAAAA, discovery: discovery);
    started.add(a);
    await a.start();

    await a.setStealthMode(true);

    expect(discovery.isAdvertising, isFalse);
  });

  test('stealth mode keeps carrying other people traffic', () async {
    // The cover story only works if a stealthed device is indistinguishable
    // from a device that is simply not being talked to.
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    await awaitPeers(a, 1);
    await awaitPeers(b, 1);

    await b.setStealthMode(true);

    final atB = b.inbound.first;
    await a.send(Uint8List.fromList([3]), toPeer: a.peers.single.peerId);
    expect((await atB.timeout(const Duration(seconds: 5))).bytes, [3]);
  });

  test('leaving stealth mode advertises again', () async {
    final discovery = network.join();
    final a = WifiTransport(addressHash: 0xAAAA, discovery: discovery);
    started.add(a);
    await a.start();
    await a.setStealthMode(true);

    await a.setStealthMode(false);

    expect(discovery.isAdvertising, isTrue);
  });

  test('status reports what is actually happening', () async {
    final a = await device(0xAAAA);
    expect(a.status.running, isTrue);
    expect(a.status.advertising, isTrue);
    expect(a.status.scanning, isTrue);
    expect(a.status.isHealthy, isTrue);

    await device(0xBBBB);
    await awaitPeers(a, 1);

    expect(a.status.connectedPeerCount, 1);
  });

  test('status changes are published', () async {
    final a = await device(0xAAAA, start: false);
    final change = a.statusChanges.first.timeout(const Duration(seconds: 5));

    await a.start();

    expect((await change).running, isTrue);
  });

  test('a refused local-network permission is reported, not hidden', () async {
    final discovery = network.join()..failure = LanUnavailable.permissionDenied;
    final a = WifiTransport(addressHash: 0xAAAA, discovery: discovery);
    started.add(a);

    await a.start();

    expect(a.status.permissionsGranted, isFalse);
    expect(a.status.isHealthy, isFalse);
    expect(a.status.detail, contains('permission'));
  });

  test('stopping closes every link and clears the peer list', () async {
    final a = await device(0xAAAA);
    await device(0xBBBB);
    await awaitPeers(a, 1);

    await a.stop();

    expect(a.peers, isEmpty);
    expect(a.linkCount, 0);
    expect(a.status.running, isFalse);
  });

  test('starting twice is harmless', () async {
    final a = await device(0xAAAA);
    final port = a.port;

    await a.start();

    expect(a.port, port);
  });

  test('a peer that never introduces itself is dropped', () async {
    final a = await device(0xAAAA);
    await connectSilently(a.port!);

    await Future<void>.delayed(const Duration(seconds: 3));

    expect(a.peers, isEmpty);
    expect(a.linkCount, 0);
  });

  test('an advertisement pointing nowhere does not break discovery', () async {
    final discovery = network.join();
    final a = WifiTransport(addressHash: 0xAAAA, discovery: discovery);
    started.add(a);
    await a.start();

    // A port nothing is listening on: the peer died between advertising and
    // being found, which mDNS caching makes routine.
    discovery.injectService(
      const DiscoveredService(
        instanceId: 'ghost',
        host: '127.0.0.1',
        port: 1,
        addressHash: 0xDEAD,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Still working afterwards is the actual assertion.
    await device(0xBBBB);
    await awaitPeers(a, 1);
  });

  test('the peer id is derived from the mesh address, so it survives a '
      'reconnect', () async {
    final a = await device(0xAAAA);
    final b = await device(0xBBBB);
    await awaitPeers(a, 1);
    final before = a.peers.single.peerId;

    await b.stop();
    await awaitPeers(a, 0);
    await b.start();
    await awaitPeers(a, 1);

    // A conversation is keyed on this. An id that changed on every reconnect
    // would fork the thread every time someone's phone slept.
    expect(a.peers.single.peerId, before);
  });
}

/// Opens a connection and then says nothing at all — a port scanner, a stalled
/// peer, or a device that crashed between connecting and introducing itself.
Future<Socket> connectSilently(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  addTearDown(socket.destroy);
  return socket;
}
