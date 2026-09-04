import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/src/lan_link.dart';
import 'package:transport_wifi/src/link_codec.dart';

/// Real sockets on loopback, not mocks.
///
/// The whole value of this class is how it behaves against a real TCP stack —
/// partial reads, a peer vanishing mid-write, a close arriving while a frame is
/// in flight. A fake socket would agree with whatever the implementation does
/// and prove nothing.
void main() {
  late ServerSocket server;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async => server.close());

  /// A connected pair, both ends wrapped.
  Future<(LanLink dialer, LanLink listener)> pair({
    int dialerHash = 0x1111,
    int listenerHash = 0x2222,
  }) async {
    final accepted = server.first;
    final connected = await Socket.connect(server.address, server.port);
    final dialer = LanLink(
      connected,
      localAddressHash: dialerHash,
      dialedByUs: true,
    );
    final listener = LanLink(
      await accepted,
      localAddressHash: listenerHash,
      dialedByUs: false,
    );
    return (dialer, listener);
  }

  test('both ends learn the other address hash from the hello', () async {
    final (dialer, listener) = await pair();
    addTearDown(() async {
      await dialer.close();
      await listener.close();
    });

    expect(await dialer.ready, 0x2222);
    expect(await listener.ready, 0x1111);
    expect(dialer.peerHash, 0x2222);
  });

  test('frames cross in both directions, byte for byte', () async {
    final (dialer, listener) = await pair();
    addTearDown(() async {
      await dialer.close();
      await listener.close();
    });
    await dialer.ready;
    await listener.ready;

    final atListener = listener.frames.first;
    final atDialer = dialer.frames.first;

    dialer.send(Uint8List.fromList([1, 2, 3]));
    listener.send(Uint8List.fromList([9, 8]));

    expect(await atListener, [1, 2, 3]);
    expect(await atDialer, [9, 8]);
  });

  test('a hello is never surfaced as a mesh frame', () async {
    // The mesh layer would try to decode it as a Frame and log a malformed
    // frame on every single connection.
    final (dialer, listener) = await pair();
    addTearDown(() async {
      await dialer.close();
      await listener.close();
    });

    final frames = <Uint8List>[];
    listener.frames.listen(frames.add);
    await listener.ready;
    await pumpEventQueue();

    expect(frames, isEmpty);
  });

  test('a peer speaking nonsense gets hung up on', () async {
    final accepted = server.first;
    final raw = await Socket.connect(server.address, server.port);
    addTearDown(() => raw.destroy());

    final link = LanLink(
      await accepted,
      localAddressHash: 1,
      dialedByUs: false,
    );

    raw.add('GET / HTTP/1.1\r\n\r\n'.codeUnits);

    // Not an exception thrown at the caller: a stranger on the Wi-Fi sending
    // rubbish is expected, and must cost one closed socket, not a crash.
    await link.done.timeout(const Duration(seconds: 5));
    expect(link.isClosed, isTrue);
  });

  test('a link never completes ready when the peer never says hello', () async {
    final accepted = server.first;
    final raw = await Socket.connect(server.address, server.port);
    addTearDown(() => raw.destroy());

    final link = LanLink(
      await accepted,
      localAddressHash: 1,
      dialedByUs: false,
    );
    addTearDown(link.close);

    var settled = false;
    unawaited(link.ready.then((_) => settled = true, onError: (_) {}));
    await pumpEventQueue();

    expect(settled, isFalse);
  });

  test('the far end going away ends the link', () async {
    final (dialer, listener) = await pair();
    await dialer.ready;

    await listener.close();

    await dialer.done.timeout(const Duration(seconds: 5));
    expect(dialer.isClosed, isTrue);
  });

  test('closing ends the frame stream so listeners are released', () async {
    final (dialer, listener) = await pair();
    addTearDown(listener.close);

    var closed = false;
    dialer.frames.listen(null, onDone: () => closed = true);
    await dialer.close();
    await pumpEventQueue();

    expect(closed, isTrue);
  });

  test('sending after close is ignored rather than thrown', () async {
    // A peer disappearing while a send is in flight is ordinary. Making callers
    // guard every send would mean every call site gets it wrong once.
    final (dialer, listener) = await pair();
    addTearDown(listener.close);
    await dialer.close();

    expect(() => dialer.send(Uint8List.fromList([1])), returnsNormally);
  });

  test('an oversized frame is refused without killing the link', () async {
    final (dialer, listener) = await pair();
    addTearDown(() async {
      await dialer.close();
      await listener.close();
    });
    await dialer.ready;

    expect(
      () => dialer.send(Uint8List(LinkCodec.maxFrameLength + 1)),
      throwsA(isA<LinkProtocolException>()),
    );
    expect(dialer.isClosed, isFalse);
  });

  test('it reports which side dialled, for the duplicate-link rule', () async {
    final (dialer, listener) = await pair();
    addTearDown(() async {
      await dialer.close();
      await listener.close();
    });

    expect(dialer.dialedByUs, isTrue);
    expect(listener.dialedByUs, isFalse);
  });

  group('the hello boundary', () {
    /// A raw peer we control byte for byte, so a packet can be composed exactly.
    Future<(Socket peer, LanLink link)> rawPeer() async {
      final accepted = server.first;
      final peer = await Socket.connect(server.address, server.port);
      return (
        peer,
        LanLink(await accepted, localAddressHash: 0x2222, dialedByUs: false),
      );
    }

    test('a frame sharing a packet with the hello is delivered', () async {
      // This was silently dropped. `frames` was a broadcast stream, which
      // discards events while nobody is listening, and the transport can only
      // subscribe after awaiting the hello — but everything sharing a socket
      // read with the hello is delivered synchronously, before the awaiting
      // code resumes. The first frame of a connection went in the bin, and the
      // outbox retry made it look like latency rather than loss.
      final (peer, link) = await rawPeer();
      addTearDown(() async {
        await link.close();
        peer.destroy();
      });

      peer
        ..add(LinkCodec.encodeHello(0xAAAAAAAA))
        ..add(LinkCodec.encodeFrame(Uint8List.fromList([1, 2, 3, 4])));
      await peer.flush();

      expect(await link.ready, 0xAAAAAAAA);

      // Subscribed only now, exactly as WifiTransport._adopt does.
      final received = <Uint8List>[];
      link.frames.listen(received.add);
      await pumpEventQueue();

      expect(received.single, [1, 2, 3, 4]);
    });

    test('a frame before any hello hangs up the link', () async {
      // Buffering frames for a peer that has not said who it is means holding
      // memory a stranger controls for a peer that may never arrive, and there
      // would be nowhere to attribute them to in any case.
      final (peer, link) = await rawPeer();
      addTearDown(() => peer.destroy());

      peer.add(LinkCodec.encodeFrame(Uint8List.fromList([7, 7])));
      await peer.flush();

      await link.done.timeout(const Duration(seconds: 5));
      expect(link.isClosed, isTrue);
    });

    test('closing a link nobody subscribed to still completes', () async {
      // A single-subscription controller only finishes closing once a listener
      // has consumed the done event. A link dropped before the transport ever
      // subscribed — a hello timeout, or the losing side of a duplicate dial —
      // must not hang here.
      final (peer, link) = await rawPeer();
      addTearDown(() => peer.destroy());

      await link.close().timeout(const Duration(seconds: 5));
      expect(link.isClosed, isTrue);
    });
  });
}
