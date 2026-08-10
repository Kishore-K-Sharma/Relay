import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr_event.dart';
import 'socks5.dart';

/// Opens a connection to a relay. Injectable so tests need no network.
///
/// Asynchronous because a proxied connection cannot be opened synchronously:
/// reaching a relay through Tor means a SOCKS5 handshake and an HTTP upgrade
/// before there is a channel at all. See [proxiedSocketFactory].
typedef RelaySocketFactory = FutureOr<WebSocketChannel> Function(Uri url);

WebSocketChannel _defaultSocket(Uri url) => WebSocketChannel.connect(url);

/// A factory that reaches every relay through a SOCKS5 proxy.
///
/// Pass `ProxyConfig.tor()` to route relay traffic through a Tor daemon
/// listening locally. **Relay does not ship that daemon** — see
/// `docs/SECURITY.md`. Without one running, every relay connection fails and
/// the app correctly reports the relay as unavailable rather than quietly
/// falling back to a direct connection, which would defeat the point.
RelaySocketFactory proxiedSocketFactory(ProxyConfig proxy) =>
    (Uri url) => connectThroughProxy(url, proxy: proxy);

/// Public relays used by default.
///
/// Several, because any single one will be down, rate-limiting, or blocked on
/// the network the user happens to be on. They are load-bearing infrastructure
/// operated by strangers, which is exactly why nothing readable is ever sent
/// to them.
const defaultRelays = <String>[
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://nostr.mom',
];

/// A pool of relay connections.
///
/// Publishing goes to all of them and succeeds if any one accepts; subscribing
/// listens to all of them and deduplicates by event id. Relays disagree about
/// what they hold and go down without warning, so redundancy is not an
/// optimisation here — a single relay would mean routine silent message loss.
class RelayPool {
  RelayPool({
    List<String>? urls,
    RelaySocketFactory socketFactory = _defaultSocket,
    Duration reconnectDelay = const Duration(seconds: 5),
  }) : _urls = urls ?? defaultRelays,
       _socketFactory = socketFactory,
       _reconnectDelay = reconnectDelay;

  final List<String> _urls;
  final RelaySocketFactory _socketFactory;
  final Duration _reconnectDelay;

  final _connections = <String, _Connection>{};
  final _events = StreamController<NostrEvent>.broadcast();

  /// Event ids already surfaced, so the same event arriving from four relays
  /// reaches the caller once.
  final _seen = <String>{};
  final _seenOrder = <String>[];
  static const int _maxSeen = 4000;

  /// Active subscriptions, replayed to any relay that reconnects.
  final _subscriptions = <String, Map<String, Object?>>{};

  bool _closed = false;

  Stream<NostrEvent> get events => _events.stream;

  int get connectedCount =>
      _connections.values.where((c) => c.connected).length;

  bool get isConnected => connectedCount > 0;

  void connect() {
    if (_closed) return;
    for (final url in _urls) {
      _connections.putIfAbsent(url, () => _open(url));
    }
  }

  _Connection _open(String url) {
    final connection = _Connection(url);
    unawaited(_attach(connection, url));
    return connection;
  }

  Future<void> _attach(_Connection connection, String url) async {
    try {
      final channel = await _socketFactory(Uri.parse(url));
      if (_closed) {
        await channel.sink.close();
        return;
      }
      connection.channel = channel;
      connection.connected = true;

      channel.stream.listen(
        (message) => _onMessage(connection, message),
        onError: (Object _) => _onClosed(connection),
        onDone: () => _onClosed(connection),
        cancelOnError: true,
      );

      // A relay that comes back must be told what we are listening for, or it
      // silently delivers nothing and the failure looks like "no messages".
      for (final entry in _subscriptions.entries) {
        connection.send(['REQ', entry.key, entry.value]);
      }
    } on Object {
      // Includes a refused proxy. Reported as "not connected" rather than
      // retried directly, so the relay honestly shows as unavailable.
      connection.connected = false;
      _scheduleReconnect(url);
    }
  }

  void _onClosed(_Connection connection) {
    connection.connected = false;
    if (_closed) return;
    _connections.remove(connection.url);
    _scheduleReconnect(connection.url);
  }

  void _scheduleReconnect(String url) {
    if (_closed) return;
    Timer(_reconnectDelay, () {
      if (_closed || _connections.containsKey(url)) return;
      _connections[url] = _open(url);
    });
  }

  void _onMessage(_Connection connection, Object? raw) {
    if (raw is! String) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }

    // Relay frames are ["EVENT", subId, event], ["EOSE", subId], ["OK", ...],
    // ["NOTICE", text]. Only the first carries anything we want.
    if (decoded is! List || decoded.isEmpty || decoded.first != 'EVENT') return;
    if (decoded.length < 3) return;

    final event = NostrEvent.fromJson(decoded[2]);
    if (event == null || !_accept(event.id)) return;

    if (!_events.isClosed) _events.add(event);
  }

  bool _accept(String id) {
    if (!_seen.add(id)) return false;
    _seenOrder.add(id);
    while (_seenOrder.length > _maxSeen) {
      _seen.remove(_seenOrder.removeAt(0));
    }
    return true;
  }

  /// Publishes to every relay. Returns how many accepted the write.
  int publish(NostrEvent event) {
    var delivered = 0;
    for (final connection in _connections.values) {
      if (connection.send(['EVENT', event.toJson()])) delivered++;
    }
    return delivered;
  }

  /// Subscribes to gift wraps addressed to [pubkey].
  ///
  /// [since] avoids replaying the whole history a relay happens to hold every
  /// time the app starts.
  void subscribeToWraps(String pubkey, {DateTime? since}) {
    final filter = <String, Object?>{
      'kinds': [NostrEvent.kindGiftWrap],
      '#p': [pubkey],
      if (since != null) 'since': since.millisecondsSinceEpoch ~/ 1000,
    };

    // A fixed id per pubkey, so reconnecting replaces the subscription rather
    // than stacking a second copy of it on the relay.
    final id = 'wraps-${pubkey.substring(0, 8)}';
    _subscriptions[id] = filter;

    for (final connection in _connections.values) {
      connection.send(['REQ', id, filter]);
    }
  }

  void unsubscribeAll() {
    for (final id in _subscriptions.keys) {
      for (final connection in _connections.values) {
        connection.send(['CLOSE', id]);
      }
    }
    _subscriptions.clear();
  }

  Future<void> close() async {
    _closed = true;
    unsubscribeAll();
    for (final connection in _connections.values) {
      await connection.close();
    }
    _connections.clear();
    await _events.close();
  }
}

class _Connection {
  _Connection(this.url);

  final String url;
  WebSocketChannel? channel;
  bool connected = false;

  bool send(List<Object?> message) {
    if (!connected) return false;
    try {
      channel?.sink.add(jsonEncode(message));
      return true;
    } catch (_) {
      connected = false;
      return false;
    }
  }

  Future<void> close() async {
    connected = false;
    try {
      await channel?.sink.close();
    } catch (_) {
      // Already gone. Nothing useful to do or report.
    }
  }
}
