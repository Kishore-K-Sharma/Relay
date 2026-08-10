import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_nostr/transport_nostr.dart';

/// A SOCKS5 proxy, in-process, on loopback.
///
/// Real sockets rather than a mock: the whole point of this code is byte-exact
/// conformance to somebody else's protocol, and a mock would only assert that
/// the implementation agrees with itself.
class FakeProxy {
  FakeProxy._(this._server);

  static Future<FakeProxy> start({
    int replyCode = 0x00,
    int method = 0x00,
    int version = 0x05,
    int boundAddressType = 0x01,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FakeProxy._(server)
      .._replyCode = replyCode
      .._method = method
      .._version = version
      .._boundAddressType = boundAddressType;
    proxy._accept();
    return proxy;
  }

  final ServerSocket _server;
  int _replyCode = 0x00;
  int _method = 0x00;
  int _version = 0x05;
  int _boundAddressType = 0x01;

  /// Where the client asked to go, once it has asked.
  final requested = Completer<({String host, int port})>();

  /// Somewhere to forward to, for the end-to-end test.
  int? forwardPort;

  int get port => _server.port;

  ProxyConfig get config =>
      ProxyConfig(host: InternetAddress.loopbackIPv4.address, port: port);

  void _accept() {
    _server.listen((socket) async {
      // One subscription, a byte buffer, and a poll loop — the same shape the
      // client uses, because a socket delivers whatever arrived rather than
      // what was asked for.
      final buffer = BytesBuilder();
      Socket? upstream;
      var done = false;

      socket.listen(
        (chunk) {
          if (upstream != null) {
            upstream.add(chunk);
          } else {
            buffer.add(chunk);
          }
        },
        onDone: () => done = true,
        onError: (Object _) => done = true,
      );

      Future<Uint8List> take(int count) async {
        while (buffer.length < count) {
          if (done) throw StateError('client went away');
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        final all = buffer.takeBytes();
        buffer.add(all.sublist(count));
        return Uint8List.sublistView(all, 0, count);
      }

      try {
        final greeting = await take(2);
        await take(greeting[1]);
        socket.add([_version, _method]);
        await socket.flush();
        if (_method != 0x00 || _version != 0x05) return;

        final head = await take(4);
        expect(head[1], 0x01, reason: 'must be a CONNECT');
        final nameLength = (await take(1))[0];
        final name = utf8.decode(await take(nameLength));
        final portBytes = await take(2);
        if (!requested.isCompleted) {
          requested.complete((
            host: name,
            port: (portBytes[0] << 8) | portBytes[1],
          ));
        }

        socket.add([
          0x05,
          _replyCode,
          0x00,
          _boundAddressType,
          if (_boundAddressType == 0x01) ...[0, 0, 0, 0],
          if (_boundAddressType == 0x04) ...List.filled(16, 0),
          0,
          0,
        ]);
        await socket.flush();
        if (_replyCode != 0x00) {
          await socket.close();
          return;
        }

        final target = forwardPort;
        if (target == null) return;

        final connected = await Socket.connect(
          InternetAddress.loopbackIPv4,
          target,
        );
        connected.listen(
          socket.add,
          onDone: socket.close,
          onError: (Object _) => socket.destroy(),
        );

        // Anything typed before the tunnel opened goes first, in order.
        final pending = buffer.takeBytes();
        if (pending.isNotEmpty) connected.add(pending);
        upstream = connected;
      } on StateError {
        // The client hung up mid-handshake; nothing to clean up beyond this.
      }
    });
  }

  Future<void> close() => _server.close();
}

void main() {
  group('ProxyConfig', () {
    test('none is not usable', () {
      expect(const ProxyConfig.none().isUsable, isFalse);
    });

    test('Tor defaults to the usual local listener', () {
      const tor = ProxyConfig.tor();

      expect(tor.host, '127.0.0.1');
      expect(tor.port, 9050);
      expect(tor.isUsable, isTrue);
    });

    test('a disabled proxy is not usable even when configured', () {
      const off = ProxyConfig(host: '127.0.0.1', port: 9050, enabled: false);

      expect(off.isUsable, isFalse);
    });
  });

  group('Socks5.connect', () {
    test('reaches the destination through the proxy', () async {
      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);

      final socket = await Socks5.connect(
        proxy: proxy.config,
        host: 'relay.example.com',
        port: 443,
      );
      addTearDown(socket.destroy);

      final asked = await proxy.requested.future;
      expect(asked.host, 'relay.example.com');
      expect(asked.port, 443);
    });

    test('sends the destination as a name, never as an address', () async {
      // The rule that matters. Resolving locally would send a DNS query to the
      // network the proxy exists to avoid, which is the classic way a proxied
      // application is deanonymised.
      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);

      final socket = await Socks5.connect(
        proxy: proxy.config,
        host: 'somewhere.onion',
        port: 80,
      );
      addTearDown(socket.destroy);

      expect((await proxy.requested.future).host, 'somewhere.onion');
    });

    test('refuses when no proxy is configured', () async {
      expect(
        () => Socks5.connect(
          proxy: const ProxyConfig.none(),
          host: 'example.com',
          port: 80,
        ),
        throwsA(isA<Socks5Exception>()),
      );
    });

    test('rejects an empty or oversized host name', () async {
      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);

      expect(
        () => Socks5.connect(proxy: proxy.config, host: '', port: 80),
        throwsA(isA<Socks5Exception>()),
      );
      expect(
        () => Socks5.connect(proxy: proxy.config, host: 'a' * 256, port: 80),
        throwsA(isA<Socks5Exception>()),
      );
    });

    test('rejects a port out of range', () async {
      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);

      expect(
        () => Socks5.connect(proxy: proxy.config, host: 'a.com', port: 0),
        throwsA(isA<Socks5Exception>()),
      );
    });

    test('reports a refusal in words', () async {
      final proxy = await FakeProxy.start(replyCode: 0x05);
      addTearDown(proxy.close);

      await expectLater(
        Socks5.connect(proxy: proxy.config, host: 'a.com', port: 80),
        throwsA(
          isA<Socks5Exception>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    });

    test('reports an unreachable host distinctly', () async {
      final proxy = await FakeProxy.start(replyCode: 0x04);
      addTearDown(proxy.close);

      await expectLater(
        Socks5.connect(proxy: proxy.config, host: 'a.com', port: 80),
        throwsA(
          isA<Socks5Exception>().having(
            (e) => e.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
    });

    test('refuses a proxy that is not SOCKS5', () async {
      final proxy = await FakeProxy.start(version: 0x04);
      addTearDown(proxy.close);

      await expectLater(
        Socks5.connect(proxy: proxy.config, host: 'a.com', port: 80),
        throwsA(
          isA<Socks5Exception>().having(
            (e) => e.message,
            'message',
            contains('not SOCKS5'),
          ),
        ),
      );
    });

    test('refuses a proxy demanding authentication', () async {
      // We offer only "none". A proxy insisting on a password is misconfigured
      // for this use, and guessing would hang.
      final proxy = await FakeProxy.start(method: 0x02);
      addTearDown(proxy.close);

      await expectLater(
        Socks5.connect(proxy: proxy.config, host: 'a.com', port: 80),
        throwsA(
          isA<Socks5Exception>().having(
            (e) => e.message,
            'message',
            contains('authentication'),
          ),
        ),
      );
    });

    test('handles an IPv6 bound address in the reply', () async {
      // Consuming the wrong number of bytes here would corrupt the first thing
      // the far end says, which is the kind of bug that only shows up against
      // one particular proxy.
      final proxy = await FakeProxy.start(boundAddressType: 0x04);
      addTearDown(proxy.close);

      final socket = await Socks5.connect(
        proxy: proxy.config,
        host: 'a.com',
        port: 80,
      );
      addTearDown(socket.destroy);

      expect(await proxy.requested.future, isNotNull);
    });

    test('gives up rather than hanging when the proxy says nothing', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      silent.listen((_) {});

      await expectLater(
        Socks5.connect(
          proxy: ProxyConfig(
            host: InternetAddress.loopbackIPv4.address,
            port: silent.port,
          ),
          host: 'a.com',
          port: 80,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<Socks5Exception>()),
      );
    });
  });

  group('connectThroughProxy', () {
    test('carries a WebSocket end to end', () async {
      // The whole path: SOCKS5 handshake, HTTP upgrade written by hand, and
      // the platform WebSocket doing the framing on top.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) => socket.add('echo:$message'));
      });

      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);
      proxy.forwardPort = server.port;

      final channel = await connectThroughProxy(
        Uri.parse('ws://relay.example.com:${server.port}/'),
        proxy: proxy.config,
      );

      channel.sink.add('hello');
      expect(await channel.stream.first, 'echo:hello');

      expect(
        (await proxy.requested.future).host,
        'relay.example.com',
        reason: 'the relay name went to the proxy, not to a resolver',
      );
      await channel.sink.close();
    });

    test('reports a relay that refuses the upgrade', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) {
        request.response.statusCode = 404;
        request.response.close();
      });

      final proxy = await FakeProxy.start();
      addTearDown(proxy.close);
      proxy.forwardPort = server.port;

      await expectLater(
        connectThroughProxy(
          Uri.parse('ws://relay.example.com:${server.port}/'),
          proxy: proxy.config,
        ),
        throwsA(
          isA<Socks5Exception>().having(
            (e) => e.message,
            'message',
            contains('refused the upgrade'),
          ),
        ),
      );
    });
  });
}
