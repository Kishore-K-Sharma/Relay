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
class LinkReader {
  final _buffer = BytesBuilder(copy: true);

  /// Everything that became complete after adding [chunk].
  ///
  /// Throws [LinkProtocolException] on anything malformed. The caller must
  /// close the connection when that happens; this object is not usable
  /// afterwards because its position in the stream is unknown.
  Iterable<LinkMessage> offer(Uint8List chunk) sync* {
    _buffer.add(chunk);

    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < LinkCodec._headerLength) return;

      final length = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
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
      if (bytes.length < total) return;

      yield _decodeBody(
        Uint8List.sublistView(bytes, LinkCodec._headerLength, total),
      );

      _buffer
        ..clear()
        ..add(Uint8List.sublistView(bytes, total));
    }
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
