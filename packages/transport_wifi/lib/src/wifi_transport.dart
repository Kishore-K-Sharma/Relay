import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:transport_api/transport_api.dart' as api;

import 'lan_discovery.dart';
import 'lan_link.dart';

/// The local-network transport.
///
/// This is the answer to a router with no internet behind it. Everyone joined
/// to the same Wi-Fi reaches everyone else in one hop, at roughly a hundred
/// times Bluetooth's throughput and a fraction of the battery, because nothing
/// has to scan.
///
/// It is deliberately *not* a substitute for the Bluetooth mesh. It works only
/// where a shared network already exists, it does nothing in a field or a
/// street, and on iOS it stops the moment the app is backgrounded. It runs
/// beside Bluetooth, never instead of it.
///
/// The transport carries opaque frames and has no idea what is inside them. The
/// Noise session on top is unchanged, so the router owner — and anyone else on
/// the network — sees encrypted bytes exactly as a relaying phone does.
class WifiTransport implements api.Transport {
  WifiTransport({
    required this.addressHash,
    required LanDiscovery discovery,
    this.helloTimeout = const Duration(seconds: 5),
    this.dialTimeout = const Duration(seconds: 5),
    Random? random,
  }) : _discovery = discovery,
       _instanceId = _newInstanceId(random ?? Random.secure());

  /// This device's truncated mesh address. Advertised so a peer can tell us
  /// apart, and sent in the link hello so both ends can agree which of two
  /// simultaneous connections to keep.
  final int addressHash;

  final LanDiscovery _discovery;

  /// How long a new connection has to introduce itself before it is dropped.
  ///
  /// Without this a port scanner, or a peer that crashed mid-handshake, holds a
  /// socket open forever.
  final Duration helloTimeout;

  final Duration dialTimeout;

  /// Random per run. Recognising our own advertisement by address hash would
  /// be wrong — 32 bits collide in a large crowd, and the two devices sharing a
  /// hash would each conclude the other was itself.
  final String _instanceId;

  ServerSocket? _server;

  /// Live links, one per peer address. The map is the peer table: a peer exists
  /// exactly as long as a socket to it does.
  final _links = <int, LanLink>{};

  /// Connections that have not said hello yet, held so [stop] can close them.
  final _pending = <LanLink>{};

  /// Instance ids currently being dialled, so a repeated discovery event does
  /// not open a second socket to the same device.
  final _dialing = <String>{};

  final _inbound = StreamController<api.InboundFrame>.broadcast();
  final _peerEvents = StreamController<api.PeerEvent>.broadcast();
  final _statusChanges = StreamController<api.TransportStatus>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];

  bool _running = false;
  bool _advertising = false;
  bool _browsing = false;
  bool _stealth = false;

  @override
  Stream<api.InboundFrame> get inbound => _inbound.stream;

  @override
  Stream<api.PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Stream<api.TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  List<api.TransportPeer> get peers => [
    for (final hash in _links.keys)
      api.TransportPeer(peerId: peerIdFor(hash), hopDistance: 1),
  ];

  @override
  api.TransportStatus get status {
    final reason = _discovery.unavailableReason;
    return api.TransportStatus(
      running: _running,
      adapterOn: reason != LanUnavailable.noNetwork,
      permissionsGranted: reason != LanUnavailable.permissionDenied,
      advertising: _advertising,
      scanning: _browsing,
      connectedPeerCount: _links.length,
      detail: reason?.message,
    );
  }

  /// The TCP port we are listening on, or null when stopped.
  int? get port => _server?.port;

  /// Peer id for a mesh address.
  ///
  /// Derived from the address rather than the socket, so it survives a
  /// reconnect. A peer id that changed whenever a phone slept would fork the
  /// conversation every time.
  static String peerIdFor(int addressHash) =>
      'wifi:${(addressHash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

  static int? _addressFromPeerId(String peerId) {
    if (!peerId.startsWith('wifi:')) return null;
    return int.tryParse(peerId.substring(5), radix: 16);
  }

  @visibleForTesting
  int get linkCount => _links.length;

  /// Which side opened the surviving link to [peerHash]. Tests use it to check
  /// that both devices resolved a simultaneous dial the same way.
  @visibleForTesting
  bool dialedByUs(int peerHash) => _links[peerHash]!.dialedByUs;

  // ------------------------------------------------------------- lifecycle

  @override
  Future<void> start() async {
    if (_running) return;

    if (!_discovery.isAvailable) {
      // Nothing to bind and nothing to advertise. The status carries the
      // reason so the UI can say which of the two fixable things is wrong.
      _publishStatus();
      return;
    }

    // Port 0: the OS picks a free one and mDNS carries it, so nothing is
    // hard-coded and two instances on one machine do not collide.
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _running = true;

    _subscriptions
      ..add(server.listen(_onIncoming, onError: (Object _) {}))
      ..add(_discovery.found.listen(_onFound))
      ..add(_discovery.lost.listen(_onServiceLost));

    await _discovery.browse();
    _browsing = true;

    if (!_stealth) await _startAdvertising();

    _publishStatus();
  }

  @override
  Future<void> stop() async {
    // Cleared before the first await. Cancelling is asynchronous, and a
    // connection accepted during that gap would otherwise add a subscription
    // to the list being iterated.
    _running = false;
    final subscriptions = [..._subscriptions];
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    await _discovery.stopBrowsing();
    _browsing = false;
    await _stopAdvertising();

    for (final link in [..._links.values, ..._pending]) {
      await link.close();
    }
    _links.clear();
    _pending.clear();
    _dialing.clear();

    await _server?.close();
    _server = null;

    _publishStatus();
  }

  Future<void> dispose() async {
    await stop();
    await _discovery.dispose();
    await _inbound.close();
    await _peerEvents.close();
    await _statusChanges.close();
  }

  // -------------------------------------------------------------- discovery

  Future<void> _startAdvertising() async {
    final port = _server?.port;
    if (port == null) return;
    await _discovery.advertise(
      instanceId: _instanceId,
      addressHash: addressHash,
      port: port,
    );
    _advertising = true;
  }

  Future<void> _stopAdvertising() async {
    if (!_advertising) return;
    await _discovery.stopAdvertising();
    _advertising = false;
  }

  /// Stops announcing this device while leaving it able to carry traffic.
  ///
  /// Same bargain as Bluetooth stealth: no beacon, but relaying continues,
  /// because a device that stopped relaying would stand out precisely when it
  /// was trying not to.
  Future<void> setStealthMode(bool enabled) async {
    _stealth = enabled;
    if (enabled) {
      await _stopAdvertising();
    } else if (_running) {
      await _startAdvertising();
    }
    _publishStatus();
  }

  void _onFound(DiscoveredService service) {
    if (service.instanceId == _instanceId) return;
    if (_links.containsKey(service.addressHash)) return;
    if (!_dialing.add(service.instanceId)) return;

    unawaited(_dial(service));
  }

  void _onServiceLost(String instanceId) {
    // Advisory only. A withdrawn advertisement does not mean the socket died,
    // and the socket is what actually carries messages, so the peer stays until
    // its link ends.
    _dialing.remove(instanceId);
  }

  Future<void> _dial(DiscoveredService service) async {
    try {
      final socket = await Socket.connect(
        service.host,
        service.port,
        timeout: dialTimeout,
      );
      await _adopt(
        LanLink(socket, localAddressHash: addressHash, dialedByUs: true),
      );
    } on Object {
      // Every dial failure is routine and none is recoverable here. mDNS
      // caches, so an advertisement regularly outlives the device behind it;
      // a peer can also reset the connection between accept and hello. The
      // catch is deliberately total because the failure modes are not worth
      // distinguishing and an escaped one crashes the isolate.
    } finally {
      _dialing.remove(service.instanceId);
    }
  }

  void _onIncoming(Socket socket) {
    unawaited(
      _adopt(LanLink(socket, localAddressHash: addressHash, dialedByUs: false)),
    );
  }

  // ------------------------------------------------------------------ links

  Future<void> _adopt(LanLink link) async {
    _pending.add(link);

    final int peerHash;
    try {
      peerHash = await link.ready.timeout(helloTimeout);
    } on TimeoutException {
      _pending.remove(link);
      await link.close();
      return;
    }

    _pending.remove(link);

    if (!_running) {
      // Stopped while this connection was introducing itself.
      await link.close();
      return;
    }

    if (peerHash == addressHash) {
      // Either our own advertisement reached us by a path the instance id did
      // not cover, or two devices have collided on a 32-bit address. Neither is
      // routable: every frame for that address would be ambiguous.
      await link.close();
      return;
    }

    final existing = _links[peerHash];
    if (existing != null &&
        !_prefer(link, over: existing, peerHash: peerHash)) {
      await link.close();
      return;
    }

    _links[peerHash] = link;
    unawaited(link.done.then((_) => _onLinkClosed(peerHash, link)));

    // Not tracked in [_subscriptions]: the stream closes when the link does,
    // which ends this subscription on its own. Holding one per link that has
    // ever existed would leak for the life of the app.
    link.frames.listen(
      (bytes) => _emitFrame(bytes, peerHash),
      onError: (Object _) {},
    );

    if (existing != null) {
      await existing.close();
    } else {
      _emitPeerEvent(api.PeerEventKind.discovered, peerHash);
    }
    _publishStatus();
  }

  /// Which of two connections to the same peer survives.
  ///
  /// Both devices dialling at once is the normal case, not a rare race: they
  /// discover each other in the same instant. The rule has to be one both sides
  /// compute identically from what they already know, or each keeps the socket
  /// the other just closed and nothing is delivered in either direction.
  ///
  /// The rule: keep the connection opened by the *lower* address hash.
  bool _prefer(
    LanLink candidate, {
    required LanLink over,
    required int peerHash,
  }) {
    final weDialTheKeeper = addressHash < peerHash;
    return candidate.dialedByUs == weDialTheKeeper &&
        over.dialedByUs != weDialTheKeeper;
  }

  void _onLinkClosed(int peerHash, LanLink link) {
    // Only the registered link speaks for the peer. A link closed by the
    // duplicate-resolution rule must not report the peer as gone.
    if (!identical(_links[peerHash], link)) return;

    _links.remove(peerHash);
    _emitPeerEvent(api.PeerEventKind.lost, peerHash);
    _publishStatus();
  }

  void _emitFrame(Uint8List bytes, int peerHash) {
    if (_inbound.isClosed) return;
    _inbound.add(api.InboundFrame(bytes: bytes, fromPeer: peerIdFor(peerHash)));
  }

  void _emitPeerEvent(api.PeerEventKind kind, int peerHash) {
    if (_peerEvents.isClosed) return;
    _peerEvents.add(
      api.PeerEvent(
        kind,
        api.TransportPeer(peerId: peerIdFor(peerHash), hopDistance: 1),
      ),
    );
  }

  void _publishStatus() {
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  // ---------------------------------------------------------------- sending

  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    if (toPeer != null) {
      final hash = _addressFromPeerId(toPeer);
      if (hash != null) _links[hash]?.send(frame);
      return;
    }

    final excluded = excludePeer == null
        ? null
        : _addressFromPeerId(excludePeer);

    for (final entry in _links.entries) {
      if (entry.key == excluded) continue;
      entry.value.send(frame);
    }
  }

  static String _newInstanceId(Random random) => List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
