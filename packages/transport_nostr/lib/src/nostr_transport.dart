import 'dart:async';
import 'dart:typed_data';

import 'package:transport_api/transport_api.dart';

import 'gift_wrap.dart';
import 'nostr_crypto.dart';
import 'relay_pool.dart';

/// The internet fallback, presented as an ordinary [Transport].
///
/// Deliberately identical in shape to the Bluetooth mesh so the router can
/// choose between them without special cases. It is not equivalent in
/// substance, and the UI must not pretend it is: using it means public relay
/// operators learn that *somebody* sent *someone* an encrypted message, and
/// when. That is why it is a fallback, why stealth mode disables it outright,
/// and why the message state chip says which path a message took.
class NostrTransport implements Transport {
  NostrTransport({
    required NostrKeyPair keys,
    RelayPool? pool,
    DateTime Function()? clock,
  }) : _keys = keys,
       _pool = pool ?? RelayPool(),
       _clock = clock ?? DateTime.now;

  final NostrKeyPair _keys;
  final RelayPool _pool;
  final DateTime Function() _clock;

  final _inbound = StreamController<InboundFrame>.broadcast();
  final _peerEvents = StreamController<PeerEvent>.broadcast();
  final _statusChanges = StreamController<TransportStatus>.broadcast();

  /// Nostr public keys we know how to reach, learned when pairing.
  ///
  /// A peer met only over Bluetooth cannot be reached this way, and saying so
  /// is better than silently failing to deliver.
  final _routes = <String, String>{};

  StreamSubscription<void>? _relaySubscription;
  Timer? _statusTimer;
  bool _running = false;

  String get publicKey => _keys.publicKeyHex;

  /// Registers a peer's Nostr key so they can be reached off the mesh.
  void addRoute(String peerId, String nostrPubkey) {
    _routes[peerId] = nostrPubkey;
    _peerEvents.add(
      PeerEvent(
        PeerEventKind.discovered,
        // Not a hop count in any physical sense. A relayed peer is not
        // "nearby", and reporting 1 would make the radar draw them as if they
        // were standing next to you.
        TransportPeer(peerId: peerId, hopDistance: 99),
      ),
    );
  }

  void removeRoute(String peerId) => _routes.remove(peerId);

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;

  @override
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;

  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  List<TransportPeer> get peers => [
    for (final peerId in _routes.keys)
      TransportPeer(peerId: peerId, hopDistance: 99),
  ];

  @override
  TransportStatus get status => TransportStatus(
    running: _running,
    // There is no radio here. Reporting these as true keeps `isHealthy`
    // meaningful for a caller that does not care which transport it holds.
    adapterOn: true,
    permissionsGranted: true,
    advertising: false,
    scanning: _running,
    connectedPeerCount: _pool.connectedCount,
    canAdvertise: false,
    detail: _pool.isConnected
        ? null
        : 'No relay server is reachable. Only Bluetooth is working.',
  );

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _pool.connect();
    _pool.subscribeToWraps(
      _keys.publicKeyHex,
      // A day back. Long enough that a phone switched off overnight still
      // collects what was sent to it; short enough that launching the app does
      // not replay months of relay history.
      since: _clock().subtract(const Duration(days: 1)),
    );

    _relaySubscription = _pool.events.listen((event) async {
      final unwrapped = await GiftWrap.open(wrap: event, recipient: _keys);
      if (unwrapped == null || _inbound.isClosed) return;

      _inbound.add(
        InboundFrame(bytes: unwrapped.frame, fromPeer: unwrapped.senderPubkey),
      );
    });

    // Connection state changes with no event to hang it off, so it is polled.
    // A relay dropping is otherwise invisible until a send fails.
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_statusChanges.isClosed) _statusChanges.add(status);
    });

    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _statusTimer?.cancel();
    _statusTimer = null;
    await _relaySubscription?.cancel();
    _relaySubscription = null;
    _pool.unsubscribeAll();
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  /// Sends a frame to one peer.
  ///
  /// Broadcast is not supported and never will be: "everyone near me" has no
  /// meaning on the internet, and fanning a broadcast out to every known
  /// contact would leak the contact list to the relays one message at a time.
  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    if (toPeer == null) return;

    final recipient = _routes[toPeer] ?? _asPubkey(toPeer);
    if (recipient == null) return;

    _pool.publish(
      await GiftWrap.seal(
        frame: frame,
        sender: _keys,
        recipientPubkey: recipient,
        now: _clock(),
      ),
    );
  }

  /// Treats a peer id that is itself a Nostr key as its own route, which is
  /// how a reply to an inbound relayed frame finds its way back.
  static String? _asPubkey(String peerId) {
    if (peerId.length != 64) return null;
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(peerId) ? peerId : null;
  }

  Future<void> dispose() async {
    await stop();
    await _pool.close();
    await _inbound.close();
    await _peerEvents.close();
    await _statusChanges.close();
  }
}
