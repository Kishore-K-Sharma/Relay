import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// An in-memory stand-in for a relay.
///
/// Every relay it hands out shares one event log, so publishing on one
/// connection is visible on another — which is what a real relay pool does and
/// what the transport depends on.
class FakeRelayNetwork {
  final published = <Map<String, Object?>>[];
  final subscriptions = <String, Map<String, Object?>>{};
  final _sockets = <_FakeSocket>[];

  WebSocketChannel connect(Uri url) {
    final socket = _FakeSocket(this);
    _sockets.add(socket);
    return socket;
  }

  void deliver(Map<String, Object?> event) {
    for (final socket in _sockets) {
      socket.push(jsonEncode(['EVENT', 'sub', event]));
    }
  }

  Future<void> dispose() async {
    for (final socket in _sockets) {
      await socket.dispose();
    }
  }
}

class _FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeSocket(this.network);

  final FakeRelayNetwork network;
  final _incoming = StreamController<dynamic>.broadcast();
  late final _sink = _FakeSink(this);

  void push(String message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  void handle(Object? raw) {
    final decoded = jsonDecode(raw as String);
    if (decoded is! List || decoded.isEmpty) return;

    switch (decoded.first) {
      case 'EVENT':
        network.published.add(decoded[1] as Map<String, Object?>);
      case 'REQ':
        network.subscriptions[decoded[1] as String] =
            decoded[2] as Map<String, Object?>;
      default:
        break;
    }
  }

  Future<void> dispose() => _incoming.close();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.socket);

  final _FakeSocket socket;

  @override
  void add(dynamic data) => socket.handle(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => socket.dispose();

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => Future<void>.value();
}

final alice = NostrKeyPair.fromPrivateHex('0a' * 32);
final bob = NostrKeyPair.fromPrivateHex('0b' * 32);

void main() {
  late FakeRelayNetwork network;
  late NostrTransport transport;

  setUp(() async {
    network = FakeRelayNetwork();
    transport = NostrTransport(
      keys: alice,
      pool: RelayPool(
        urls: const ['wss://one.example', 'wss://two.example'],
        socketFactory: network.connect,
      ),
    );
    await transport.start();
  });

  tearDown(() async {
    await transport.dispose();
    await network.dispose();
  });

  test('subscribes for gift wraps addressed to us', () {
    final filter = network.subscriptions.values.single;

    expect(filter['kinds'], [NostrEvent.kindGiftWrap]);
    expect(filter['#p'], [alice.publicKeyHex]);
  });

  test('a broadcast is not attempted', () async {
    await transport.send(Uint8List.fromList([1, 2, 3]));

    // "Everyone near me" has no meaning on the internet, and fanning out to
    // every contact would hand the relays a contact list.
    expect(network.published, isEmpty);
  });

  test('a frame to a known peer is published, wrapped', () async {
    transport.addRoute('bob', bob.publicKeyHex);

    await transport.send(Uint8List.fromList([1, 2, 3]), toPeer: 'bob');

    expect(network.published, hasLength(2), reason: 'one per relay');
    final event = network.published.first;
    expect(event['kind'], NostrEvent.kindGiftWrap);
    expect(event['pubkey'], isNot(alice.publicKeyHex));
  });

  test('an inbound wrap surfaces as a frame from its real sender', () async {
    final received = <InboundFrame>[];
    transport.inbound.listen(received.add);

    network.deliver(
      (await GiftWrap.seal(
        frame: Uint8List.fromList([9, 8, 7]),
        sender: bob,
        recipientPubkey: alice.publicKeyHex,
        now: DateTime.utc(2026, 7, 26),
      )).toJson(),
    );
    await pumpEventQueue();

    expect(received.single.bytes, [9, 8, 7]);
    expect(received.single.fromPeer, bob.publicKeyHex);
  });

  test('a wrap for someone else is ignored', () async {
    final received = <InboundFrame>[];
    transport.inbound.listen(received.add);

    network.deliver(
      (await GiftWrap.seal(
        frame: Uint8List.fromList([9]),
        sender: bob,
        recipientPubkey: bob.publicKeyHex,
        now: DateTime.utc(2026, 7, 26),
      )).toJson(),
    );
    await pumpEventQueue();

    expect(received, isEmpty);
  });

  test('the same event from two relays surfaces once', () async {
    final received = <InboundFrame>[];
    transport.inbound.listen(received.add);

    final wrap = (await GiftWrap.seal(
      frame: Uint8List.fromList([5]),
      sender: bob,
      recipientPubkey: alice.publicKeyHex,
      now: DateTime.utc(2026, 7, 26),
    )).toJson();

    network.deliver(wrap);
    network.deliver(wrap);
    await pumpEventQueue();

    expect(received, hasLength(1));
  });

  test('a reply goes back to a peer identified by their key alone', () async {
    // An inbound relayed frame arrives from a hex pubkey, with no route
    // registered. The reply must still find its way home.
    await transport.send(Uint8List.fromList([1]), toPeer: bob.publicKeyHex);

    expect(network.published, isNotEmpty);
  });

  test(
    'status reports the relay as unavailable when nothing is connected',
    () async {
      final offline = NostrTransport(
        keys: alice,
        pool: RelayPool(
          urls: const ['wss://down.example'],
          socketFactory: (_) => throw StateError('refused'),
        ),
      );
      await offline.start();

      expect(offline.status.detail, contains('No relay server is reachable'));
      expect(offline.status.connectedPeerCount, 0);

      await offline.dispose();
    },
  );

  test('a relayed peer is not reported as nearby', () {
    transport.addRoute('bob', bob.publicKeyHex);

    // The radar draws by hop distance. Reporting 1 would put someone on the
    // other side of the country next to you on the screen.
    expect(transport.peers.single.isDirect, isFalse);
  });
}
