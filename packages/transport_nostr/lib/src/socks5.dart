import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Where to find a SOCKS5 proxy, if the user wants one.
///
/// Written for Tor, which listens on 9050 by default, but nothing here is
/// Tor-specific: any SOCKS5 proxy works, including one on another machine.
@immutable
class ProxyConfig {
  const ProxyConfig({
    required this.host,
    required this.port,
    this.enabled = true,
  });

  /// The default: no proxy at all.
  const ProxyConfig.none() : host = '', port = 0, enabled = false;

  /// Tor's usual listener.
  const ProxyConfig.tor({this.port = 9050})
    : host = '127.0.0.1',
      enabled = true;

  final String host;
  final int port;
  final bool enabled;

  bool get isUsable => enabled && host.isNotEmpty && port > 0;
}

/// Thrown when a proxy refuses or mishandles a connection.
class Socks5Exception implements Exception {
  const Socks5Exception(this.message);

  final String message;

  @override
  String toString() => 'Socks5Exception: $message';
}

/// A minimal SOCKS5 client, enough to reach a relay through Tor.
///
/// The one rule that matters here: the destination is sent to the proxy as a
/// **name**, never as an address this device resolved. Resolving it locally
/// would send a DNS query straight to the network the proxy exists to avoid,
/// which leaks exactly the fact the user was trying to hide — and it is the
/// classic way a proxied application is deanonymised.
///
/// Only the "no authentication" method is offered. Tor accepts it, and
/// username/password over a local socket buys nothing.
abstract final class Socks5 {
  static const int _version = 0x05;
  static const int _noAuth = 0x00;
  static const int _connect = 0x01;
  static const int _addressTypeDomain = 0x03;
  static const int _reserved = 0x00;

  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Opens a TCP connection to [host]:[port] through the proxy.
  static Future<Socket> connect({
    required ProxyConfig proxy,
    required String host,
    required int port,
    Duration timeout = defaultTimeout,
  }) async {
    if (!proxy.isUsable) {
      throw const Socks5Exception('no proxy configured');
    }
    if (host.isEmpty || host.length > 255) {
      throw const Socks5Exception('host name must be 1-255 bytes');
    }
    if (port < 1 || port > 65535) {
      throw const Socks5Exception('port out of range');
    }

    final socket = await Socket.connect(
      proxy.host,
      proxy.port,
      timeout: timeout,
    );

    try {
      final reader = _ByteReader(socket);

      // Greeting: one method on offer, "no authentication".
      socket.add([_version, 1, _noAuth]);
      await socket.flush();

      final greeting = await reader.take(2, timeout);
      if (greeting[0] != _version) {
        throw const Socks5Exception('proxy is not SOCKS5');
      }
      if (greeting[1] != _noAuth) {
        throw Socks5Exception(
          'proxy wants an authentication method we do not offer '
          '(0x${greeting[1].toRadixString(16)})',
        );
      }

      // CONNECT, addressed by name. See the class comment.
      final name = utf8.encode(host);
      final request = BytesBuilder()
        ..add([_version, _connect, _reserved, _addressTypeDomain, name.length])
        ..add(name)
        ..add([port >> 8, port & 0xFF]);
      socket.add(request.takeBytes());
      await socket.flush();

      final reply = await reader.take(4, timeout);
      if (reply[0] != _version) {
        throw const Socks5Exception('malformed reply from proxy');
      }
      if (reply[1] != 0x00) {
        throw Socks5Exception(_describe(reply[1]));
      }

      // The bound address, which is of no use to us but has to be consumed
      // before the tunnel carries anything else.
      await _skipBoundAddress(reader, reply[3], timeout);

      // Hand back the socket with whatever the reader has already buffered
      // put back in front of it.
      return reader.release();
    } on Socks5Exception {
      socket.destroy();
      rethrow;
    } on Object {
      socket.destroy();
      rethrow;
    }
  }

  static Future<void> _skipBoundAddress(
    _ByteReader reader,
    int type,
    Duration timeout,
  ) async {
    switch (type) {
      case 0x01: // IPv4
        await reader.take(4 + 2, timeout);
      case 0x04: // IPv6
        await reader.take(16 + 2, timeout);
      case _addressTypeDomain:
        final length = (await reader.take(1, timeout))[0];
        await reader.take(length + 2, timeout);
      default:
        throw const Socks5Exception('proxy returned an unknown address type');
    }
  }

  /// The standard reply codes, in words a user could act on.
  static String _describe(int code) => switch (code) {
    0x01 => 'the proxy failed',
    0x02 => 'the proxy refused the connection',
    0x03 => 'the network is unreachable through the proxy',
    0x04 => 'the host is unreachable through the proxy',
    0x05 => 'the destination refused the connection',
    0x06 => 'the connection through the proxy timed out',
    0x07 => 'the proxy does not support this kind of connection',
    0x08 => 'the proxy does not support this kind of address',
    _ => 'the proxy refused (code 0x${code.toRadixString(16)})',
  };
}

/// Reads an exact number of bytes from a socket, buffering the remainder.
///
/// A socket delivers whatever arrived, not what was asked for; a handshake
/// that assumes one read per message works locally and fails on a real
/// network. [release] hands back a stream with any over-read bytes restored,
/// so the tunnel does not lose the first thing the far end said.
class _ByteReader {
  _ByteReader(this._socket) {
    _socket.listen(
      (chunk) {
        // Once released, everything belongs to whoever took over the socket.
        if (_released) {
          _out.add(chunk);
        } else {
          _buffer.add(chunk);
        }
      },
      onError: (Object error) {
        _error = error;
        if (_released) _out.addError(error);
      },
      onDone: () {
        _done = true;
        if (_released) _out.close();
      },
      cancelOnError: false,
    );
  }

  final Socket _socket;
  final _buffer = BytesBuilder();
  final _out = StreamController<Uint8List>();
  bool _released = false;
  bool _done = false;
  Object? _error;

  Future<Uint8List> take(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      if (_error != null) {
        throw Socks5Exception('proxy connection failed: $_error');
      }
      if (_done) throw const Socks5Exception('proxy closed the connection');
      if (DateTime.now().isAfter(deadline)) {
        throw const Socks5Exception('proxy did not answer in time');
      }
      // Polling rather than a completer per read: the handshake is a handful
      // of small reads, and this keeps all the buffering in one place.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }

  /// The socket, with anything already read put back in front of it.
  ///
  /// The original subscription is never cancelled and re-established: a
  /// [Socket] is single-subscription, so listening twice throws. Instead this
  /// keeps the one subscription and forwards everything after this point.
  Socket release() {
    _released = true;
    final leftover = _buffer.takeBytes();
    if (leftover.isNotEmpty) _out.add(leftover);
    if (_done) unawaited(_out.close());
    return _PrefixedSocket(_socket, _out.stream);
  }
}

/// A socket reading from a stream someone else is feeding.
///
/// Writes go straight to the real socket; reads come from the reader that
/// already consumed the handshake, so nothing is lost and nothing is read
/// twice.
class _PrefixedSocket extends StreamView<Uint8List> implements Socket {
  _PrefixedSocket(this._inner, super.stream);

  final Socket _inner;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  InternetAddress get address => _inner.address;
  @override
  Future<void> close() => _inner.close();
  @override
  void destroy() => _inner.destroy();
  @override
  Future<void> get done => _inner.done;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  Future<void> flush() => _inner.flush();
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  int get port => _inner.port;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

/// Opens a relay WebSocket through a SOCKS5 proxy.
///
/// Dart's `HttpClient` can only be pointed at an HTTP proxy, so the upgrade is
/// performed by hand over the tunnelled socket and then handed to the platform
/// WebSocket for framing. The alternative — resolving the relay's address
/// locally and connecting normally — would defeat the entire purpose.
Future<WebSocketChannel> connectThroughProxy(
  Uri url, {
  required ProxyConfig proxy,
  Duration timeout = Socks5.defaultTimeout,
  Random? random,
}) async {
  final secure = url.scheme == 'wss' || url.scheme == 'https';
  final port = url.hasPort ? url.port : (secure ? 443 : 80);

  final tunnel = await Socks5.connect(
    proxy: proxy,
    host: url.host,
    port: port,
    timeout: timeout,
  );

  // TLS *inside* the tunnel, verified against the relay's own name. Doing it
  // outside, or skipping the name, would let the proxy read everything.
  final socket = secure
      ? await SecureSocket.secure(tunnel, host: url.host)
      : tunnel;

  final key = base64Encode(
    List.generate(16, (_) => (random ?? Random.secure()).nextInt(256)),
  );
  final path = url.path.isEmpty ? '/' : url.path;
  final target = url.hasQuery ? '$path?${url.query}' : path;

  socket.write(
    'GET $target HTTP/1.1\r\n'
    'Host: ${url.host}:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: $key\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    '\r\n',
  );
  await socket.flush();

  final reader = _ByteReader(socket);
  final header = await _readHeaders(reader, timeout);
  if (!header.contains(' 101 ')) {
    socket.destroy();
    throw Socks5Exception(
      'relay refused the upgrade: ${header.split('\r\n').first}',
    );
  }

  return IOWebSocketChannel(
    WebSocket.fromUpgradedSocket(reader.release(), serverSide: false),
  );
}

Future<String> _readHeaders(_ByteReader reader, Duration timeout) async {
  final buffer = StringBuffer();
  // One byte at a time. The response is a few hundred bytes and over-reading
  // past the header would swallow the first WebSocket frame.
  while (!buffer.toString().endsWith('\r\n\r\n')) {
    buffer.write(String.fromCharCode((await reader.take(1, timeout))[0]));
    if (buffer.length > 16384) {
      throw const Socks5Exception('relay sent an absurd response header');
    }
  }
  return buffer.toString();
}
