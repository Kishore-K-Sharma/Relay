import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A link spoke something other than this protocol.
///
/// Always fatal to the connection. A link that has produced one byte we cannot
/// account for has no recoverable position in the stream, and guessing where
/// the next message starts is how a parser becomes an attack surface.
class LinkProtocolException implements Exception {
  const LinkProtocolException(this.reason);

  final String reason;

  @override
  String toString() => 'LinkProtocolException: $reason';
}

/// Anything that arrived whole on a link.
@immutable
sealed class LinkMessage {
  const LinkMessage();
}

/// The first thing each side sends: who I am, in mesh terms.
///
/// The transport is otherwise blind to identity — it moves opaque bytes — but
/// it needs *something* stable to key a peer on, and it needs it before the
/// mesh layer has said a word, so that two devices dialling each other at the
/// same moment can agree which of the two connections to keep.
@immutable
class HelloMessage extends LinkMessage {
  const HelloMessage(this.addressHash);

  final int addressHash;

  @override
  bool operator ==(Object other) =>
      other is HelloMessage && other.addressHash == addressHash;

  @override
  int get hashCode => addressHash.hashCode;
}

/// An opaque mesh frame. This layer never looks inside one.
@immutable
class FrameMessage extends LinkMessage {
  const FrameMessage(this.bytes);

  final Uint8List bytes;
}

/// The wire format for a Wi-Fi link.
///
/// ```
/// message := uint32 length | uint8 kind | body
/// hello   := 'SWRM' | uint8 version | uint32 addressHash
/// frame   := opaque bytes
/// ```
///
/// Length-prefixed because TCP has no message boundaries: without a length the
/// receiver cannot tell one frame from two, and a mesh frame is not
/// self-delimiting.
abstract final class LinkCodec {
  static const magic = 'SWRM';
  static const version = 1;

  static const _kindHello = 1;
  static const _kindFrame = 2;

  static const _headerLength = 4;
  static const _helloBodyLength = 1 + 4 + 1 + 4;

  /// The largest mesh frame this link will carry, and the reason the reader can
  /// trust a declared length.
  ///
  /// Mesh frames are sized for Bluetooth, where the practical ceiling is a few
  /// hundred bytes after fragmentation. 64 KiB is far above anything the
  /// protocol produces and far below what an attacker would need to exhaust
  /// memory by opening sockets and declaring huge frames.
  static const maxFrameLength = 64 * 1024;

  static Uint8List encodeHello(int addressHash) {
    final out = Uint8List(_headerLength + _helloBodyLength);
    final view = ByteData.view(out.buffer);
    view.setUint32(0, _helloBodyLength, Endian.big);
    out[4] = _kindHello;
    out.setRange(5, 9, magic.codeUnits);
    out[9] = version;
    view.setUint32(10, addressHash & 0xFFFFFFFF, Endian.big);
    return out;
  }

  static Uint8List encodeFrame(Uint8List frame) {
    if (frame.isEmpty) {
      throw const LinkProtocolException('refusing to send an empty frame');
    }
    if (frame.length > maxFrameLength) {
      // Caught here rather than on the far side, so the bug is attributed to
      // the sender that produced an impossible frame.
      throw LinkProtocolException(
        'frame of ${frame.length} bytes exceeds the $maxFrameLength cap',
      );
    }

    final out = Uint8List(_headerLength + 1 + frame.length);
    ByteData.view(out.buffer).setUint32(0, 1 + frame.length, Endian.big);
    out[4] = _kindFrame;
    out.setRange(5, out.length, frame);
    return out;
  }
}

/// Turns a TCP byte stream back into whole messages.
///
/// One reader per connection. It holds a buffer across reads because a message
/// routinely arrives in pieces, and two messages routinely arrive in one.
///
/// The buffer is a plain byte array with a read cursor rather than a
/// `BytesBuilder`. A builder has to be flattened to be inspected, and
/// flattening copies everything accumulated so far — on *every* read, whether
/// or not a message completed. That made the cost of receiving one message
/// quadratic in how many pieces it arrived in, which is a number the sender
/// chooses: dribbling a 64 KiB frame in one-byte writes cost the receiver
/// about 130 ms of CPU, before the peer had said who it was. Nothing here is
/// authenticated, so that is an unauthenticated remote amplification.
class LinkReader {
  /// Starting buffer size, doubled as needed.
  static const int _initialCapacity = 1024;

  /// Above this, an idle reader releases its buffer instead of holding it for
  /// the life of the link. One large message on each of many links is
  /// otherwise megabytes of memory nothing is using.
  static const int _maxIdleCapacity = 64 * 1024;

  Uint8List _buffer = Uint8List(0);

  /// First unconsumed byte.
  int _start = 0;

  /// One past the last byte received.
  int _end = 0;

  int get _available => _end - _start;

  /// Everything that became complete after adding [chunk].
  ///
  /// Throws [LinkProtocolException] on anything malformed. The caller must
  /// close the connection when that happens; this object is not usable
  /// afterwards because its position in the stream is unknown.
  ///
  /// Returns a list rather than a lazy iterable so that the throw above
  /// happens when this is called, which is what the sentence promises and what
  /// a caller wrapping the call in a `try` expects.
  List<LinkMessage> offer(Uint8List chunk) {
    _append(chunk);

    final messages = <LinkMessage>[];
    while (_available >= LinkCodec._headerLength) {
      final length = ByteData.view(
        _buffer.buffer,
        _buffer.offsetInBytes + _start,
        LinkCodec._headerLength,
      ).getUint32(0, Endian.big);

      if (length < 1) {
        throw const LinkProtocolException('message declares no body');
      }
      // Checked before waiting for the body, so a hostile length is refused
      // without buffering a single byte of what it asked for.
      if (length > 1 + LinkCodec.maxFrameLength) {
        throw LinkProtocolException('message declares $length bytes');
      }

      final total = LinkCodec._headerLength + length;
      if (_available < total) break;

      messages.add(
        _decodeBody(
          Uint8List.sublistView(
            _buffer,
            _start + LinkCodec._headerLength,
            _start + total,
          ),
        ),
      );
      _start += total;
    }

    if (_start == _end) {
      _start = 0;
      _end = 0;
      if (_buffer.length > _maxIdleCapacity) _buffer = Uint8List(0);
    }
    return messages;
  }

  void _append(Uint8List chunk) {
    if (chunk.isEmpty) return;

    final needed = _available + chunk.length;
    if (needed > _buffer.length) {
      var capacity = _buffer.isEmpty ? _initialCapacity : _buffer.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      _buffer = Uint8List(capacity)..setRange(0, _available, _buffer, _start);
      _end = _available;
      _start = 0;
    } else if (_end + chunk.length > _buffer.length) {
      // The space exists but is behind the cursor. Slide the live bytes down
      // rather than reallocating.
      _buffer.setRange(0, _available, _buffer, _start);
      _end = _available;
      _start = 0;
    }

    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  static LinkMessage _decodeBody(Uint8List body) {
    switch (body[0]) {
      case LinkCodec._kindHello:
        if (body.length != LinkCodec._helloBodyLength) {
          throw const LinkProtocolException('hello is the wrong size');
        }
        final magic = String.fromCharCodes(body.sublist(1, 5));
        if (magic != LinkCodec.magic) {
          throw LinkProtocolException('not a Relay link (saw "$magic")');
        }
        if (body[5] != LinkCodec.version) {
          throw LinkProtocolException('link version ${body[5]} not supported');
        }
        return HelloMessage(
          ByteData.view(
            body.buffer,
            body.offsetInBytes + 6,
            4,
          ).getUint32(0, Endian.big),
        );

      case LinkCodec._kindFrame:
        if (body.length < 2) {
          throw const LinkProtocolException('empty frame');
        }
        return FrameMessage(Uint8List.fromList(body.sublist(1)));

      default:
        throw LinkProtocolException('unknown message kind ${body[0]}');
    }
  }
}
