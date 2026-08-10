import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Wire protocol version. Receivers drop frames carrying an unknown version
/// rather than guessing, so a future incompatible revision degrades to silence
/// instead of corruption.
const int protocolVersion = 0x01;

/// Fixed header size in bytes. See ARCHITECTURE.md section 3.1.
const int frameHeaderLength = 20;

/// Maximum hop count. A frame is dropped when its ttl reaches zero.
const int maxTtl = 7;

/// A destination hash of zero addresses every device in range.
const int broadcastHash = 0x00000000;

/// Conservative BLE ATT MTU assumed across all chipsets.
const int assumedMtu = 185;

/// Largest payload that fits one frame inside [assumedMtu].
const int maxPayloadLength = assumedMtu - frameHeaderLength;

const int _maxUint32 = 0xFFFFFFFF;

/// Thrown when a buffer cannot be interpreted as a frame.
class FrameFormatException implements Exception {
  const FrameFormatException(this.message);
  final String message;

  @override
  String toString() => 'FrameFormatException: $message';
}

/// Thrown when a frame carries a protocol version this build cannot parse.
class UnsupportedVersionException extends FrameFormatException {
  const UnsupportedVersionException(this.version)
    : super('unsupported protocol version $version');
  final int version;
}

enum FrameType {
  announce(0x01),
  handshake(0x02),
  message(0x03),
  ack(0x04),
  fragment(0x05),
  room(0x06),
  voice(0x07),
  leave(0x08),

  /// "I have just joined this room — what did I miss?" and the answer.
  ///
  /// Both are encrypted with the room key, so only members can read them. That
  /// a request happened is visible to anyone relaying it, exactly as an
  /// ordinary room message is.
  historyRequest(0x09),
  historyReply(0x0A),

  /// A signed statement by a room's owner. Advisory; see [RoomControl].
  roomControl(0x0B),

  /// Several messages to one person, carried in a single encrypted frame.
  /// See [PayloadBatch] for why.
  batch(0x0C),

  /// One [CourierEnvelope]: a message for somebody who is not here, handed to
  /// a device that might meet them.
  ///
  /// Always sent with `ttl: 1`. Flooding it would be wrong twice over — if the
  /// mesh could reach the recipient there would be no need to carry it, and
  /// relaying would replicate the envelope outside the spray budget that is
  /// the only thing bounding how much of the network one message consumes.
  courier(0x0D);

  const FrameType(this.wireValue);

  /// The byte written to the wire. Never reuse or renumber these.
  final int wireValue;

  static FrameType fromWire(int value) {
    for (final type in FrameType.values) {
      if (type.wireValue == value) return type;
    }
    throw FrameFormatException(
      'unknown frame type 0x${value.toRadixString(16)}',
    );
  }
}

/// The four defined header flag bits. Bits 4-7 are reserved and must be zero.
@immutable
class FrameFlags {
  const FrameFlags({
    this.encrypted = false,
    this.fragmented = false,
    this.compressed = false,
    this.urgent = false,
  });

  factory FrameFlags.fromByte(int byte) => FrameFlags(
    encrypted: byte & _encrypted != 0,
    fragmented: byte & _fragmented != 0,
    compressed: byte & _compressed != 0,
    urgent: byte & _urgent != 0,
  );

  static const int _encrypted = 1 << 0;
  static const int _fragmented = 1 << 1;
  static const int _compressed = 1 << 2;
  static const int _urgent = 1 << 3;

  final bool encrypted;
  final bool fragmented;
  final bool compressed;
  final bool urgent;

  int toByte() =>
      (encrypted ? _encrypted : 0) |
      (fragmented ? _fragmented : 0) |
      (compressed ? _compressed : 0) |
      (urgent ? _urgent : 0);

  FrameFlags copyWith({
    bool? encrypted,
    bool? fragmented,
    bool? compressed,
    bool? urgent,
  }) => FrameFlags(
    encrypted: encrypted ?? this.encrypted,
    fragmented: fragmented ?? this.fragmented,
    compressed: compressed ?? this.compressed,
    urgent: urgent ?? this.urgent,
  );

  @override
  bool operator ==(Object other) =>
      other is FrameFlags &&
      other.encrypted == encrypted &&
      other.fragmented == fragmented &&
      other.compressed == compressed &&
      other.urgent == urgent;

  @override
  int get hashCode => Object.hash(encrypted, fragmented, compressed, urgent);

  @override
  String toString() {
    final set = <String>[
      if (encrypted) 'encrypted',
      if (fragmented) 'fragmented',
      if (compressed) 'compressed',
      if (urgent) 'urgent',
    ];
    return 'FrameFlags(${set.isEmpty ? 'none' : set.join('|')})';
  }
}

/// An 8-byte random identifier. This is the sole deduplication key in the mesh,
/// so it must be generated with a cryptographic RNG by the sender.
@immutable
class MsgId {
  MsgId(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != length) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'message id must be $length bytes',
      );
    }
  }

  factory MsgId.fromHex(String hex) {
    if (hex.length != length * 2) {
      throw ArgumentError.value(
        hex,
        'hex',
        'expected ${length * 2} hex characters',
      );
    }
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw ArgumentError.value(hex, 'hex', 'not hexadecimal');
      }
      out[i] = byte;
    }
    return MsgId(out);
  }

  static const int length = 8;

  final Uint8List bytes;

  String toHex() =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  bool operator ==(Object other) {
    if (other is! MsgId) return false;
    for (var i = 0; i < length; i++) {
      if (other.bytes[i] != bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'MsgId(${toHex()})';
}

/// One unit on the wire: a fixed 20-byte header followed by an opaque payload.
///
/// A relay only ever reads the header. The payload is encrypted for every type
/// except [FrameType.announce] and [FrameType.leave].
@immutable
class Frame {
  Frame({
    required this.type,
    required this.ttl,
    required this.flags,
    required this.msgId,
    required this.srcHash,
    required this.dstHash,
    required Uint8List payload,
    this.version = protocolVersion,
  }) : payload = Uint8List.fromList(payload) {
    if (ttl < 0 || ttl > maxTtl) {
      throw ArgumentError.value(ttl, 'ttl', 'must be between 0 and $maxTtl');
    }
    _checkHash(srcHash, 'srcHash');
    _checkHash(dstHash, 'dstHash');
  }

  static void _checkHash(int value, String name) {
    if (value < 0 || value > _maxUint32) {
      throw ArgumentError.value(
        value,
        name,
        'must be an unsigned 32-bit value',
      );
    }
  }

  final int version;
  final FrameType type;
  final int ttl;
  final FrameFlags flags;
  final MsgId msgId;
  final int srcHash;
  final int dstHash;
  final Uint8List payload;

  bool get isBroadcast => dstHash == broadcastHash;

  /// Total wire size this frame will occupy.
  int get wireLength => frameHeaderLength + payload.length;

  Frame copyWith({int? ttl, FrameFlags? flags, Uint8List? payload}) => Frame(
    version: version,
    type: type,
    ttl: ttl ?? this.ttl,
    flags: flags ?? this.flags,
    msgId: msgId,
    srcHash: srcHash,
    dstHash: dstHash,
    payload: payload ?? this.payload,
  );

  /// Returns this frame with its hop counter decremented.
  ///
  /// Throws [StateError] when the frame is already expired, because relaying an
  /// expired frame is a bug rather than a recoverable condition.
  Frame decrementTtl() {
    if (ttl == 0) throw StateError('cannot decrement ttl of an expired frame');
    return copyWith(ttl: ttl - 1);
  }

  Uint8List encode() {
    if (payload.length > maxPayloadLength) {
      throw FrameFormatException(
        'payload of ${payload.length} bytes exceeds the $maxPayloadLength byte limit; '
        'fragment it before encoding',
      );
    }

    final out = Uint8List(wireLength);
    final view = ByteData.view(out.buffer);

    out[0] = version;
    out[1] = type.wireValue;
    out[2] = ttl;
    out[3] = flags.toByte();
    out.setRange(4, 12, msgId.bytes);
    view.setUint32(12, srcHash, Endian.big);
    view.setUint32(16, dstHash, Endian.big);
    out.setRange(frameHeaderLength, out.length, payload);

    return out;
  }

  static Frame decode(Uint8List bytes) {
    if (bytes.length < frameHeaderLength) {
      throw FrameFormatException(
        'buffer of ${bytes.length} bytes is shorter than the $frameHeaderLength byte header',
      );
    }

    final version = bytes[0];
    if (version != protocolVersion) throw UnsupportedVersionException(version);

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final ttl = bytes[2];
    if (ttl > maxTtl) {
      throw FrameFormatException(
        'ttl $ttl exceeds the protocol maximum of $maxTtl',
      );
    }

    return Frame(
      version: version,
      type: FrameType.fromWire(bytes[1]),
      ttl: ttl,
      flags: FrameFlags.fromByte(bytes[3]),
      msgId: MsgId(Uint8List.sublistView(bytes, 4, 12)),
      srcHash: view.getUint32(12, Endian.big),
      dstHash: view.getUint32(16, Endian.big),
      payload: Uint8List.sublistView(bytes, frameHeaderLength),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Frame &&
      other.version == version &&
      other.type == type &&
      other.ttl == ttl &&
      other.flags == flags &&
      other.msgId == msgId &&
      other.srcHash == srcHash &&
      other.dstHash == dstHash &&
      _bytesEqual(other.payload, payload);

  @override
  int get hashCode => Object.hash(
    version,
    type,
    ttl,
    flags,
    msgId,
    srcHash,
    dstHash,
    Object.hashAll(payload),
  );

  @override
  String toString() =>
      'Frame(${type.name}, ttl=$ttl, id=${msgId.toHex()}, '
      'src=${srcHash.toRadixString(16)}, dst=${dstHash.toRadixString(16)}, '
      '${payload.length}B)';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
