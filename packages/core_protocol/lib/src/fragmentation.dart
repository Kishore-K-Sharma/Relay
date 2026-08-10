import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'frame.dart';

/// Size of the sub-header that precedes each fragment body inside the frame
/// payload: 2 bytes index, 2 bytes total, 1 byte original frame type.
const int fragmentHeaderLength = 5;

/// Body carried by one fragment. Sized so header + sub-header + body fits the
/// conservative MTU exactly.
const int fragmentPayloadLength = maxPayloadLength - fragmentHeaderLength;

/// Largest number of fragments addressable by the 16-bit count.
const int maxFragmentCount = 0xFFFF;

/// How long a partially reassembled message is retained before being discarded.
const Duration reassemblyExpiry = Duration(seconds: 120);

/// Default ceiling on concurrently reassembling messages.
const int defaultMaxPartialMessages = 64;

/// Default ceiling on total bytes held across all partial messages.
const int defaultMaxBufferedBytes = 2 * 1024 * 1024;

/// Supplies the current time. Injected so expiry is deterministic under test.
typedef ProtocolClock = Duration Function();

/// The 5-byte sub-header carried at the start of every fragment payload.
@immutable
class FragmentHeader {
  const FragmentHeader({
    required this.index,
    required this.total,
    required this.originalType,
  });

  /// Reads a fragment sub-header from the start of a frame payload.
  ///
  /// Throws [FrameFormatException] when the payload is too short or the header
  /// is internally inconsistent. Callers treat that as "drop the frame".
  factory FragmentHeader.parse(Uint8List payload) {
    if (payload.length < fragmentHeaderLength) {
      throw FrameFormatException(
        'fragment payload of ${payload.length} bytes cannot hold a '
        '$fragmentHeaderLength byte fragment header',
      );
    }
    final view = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
      payload.length,
    );
    final index = view.getUint16(0, Endian.big);
    final total = view.getUint16(2, Endian.big);

    if (total == 0) {
      throw const FrameFormatException('fragment declares a total of zero');
    }
    if (index >= total) {
      throw FrameFormatException(
        'fragment index $index is outside a total of $total',
      );
    }

    return FragmentHeader(
      index: index,
      total: total,
      originalType: FrameType.fromWire(payload[4]),
    );
  }

  final int index;
  final int total;
  final FrameType originalType;

  /// Returns [body] with this sub-header prepended.
  Uint8List prepend(Uint8List body) {
    final out = Uint8List(fragmentHeaderLength + body.length);
    final view = ByteData.view(out.buffer);
    view.setUint16(0, index, Endian.big);
    view.setUint16(2, total, Endian.big);
    out[4] = originalType.wireValue;
    out.setRange(fragmentHeaderLength, out.length, body);
    return out;
  }

  /// Returns the fragment body that follows this sub-header in [payload].
  static Uint8List bodyOf(Uint8List payload) =>
      Uint8List.sublistView(payload, fragmentHeaderLength);

  @override
  bool operator ==(Object other) =>
      other is FragmentHeader &&
      other.index == index &&
      other.total == total &&
      other.originalType == originalType;

  @override
  int get hashCode => Object.hash(index, total, originalType);
}

/// A message rebuilt from one or more frames, ready for decryption.
@immutable
class ReassembledMessage {
  const ReassembledMessage({
    required this.type,
    required this.msgId,
    required this.srcHash,
    required this.dstHash,
    required this.flags,
    required this.payload,
  });

  final FrameType type;
  final MsgId msgId;
  final int srcHash;
  final int dstHash;
  final FrameFlags flags;
  final Uint8List payload;
}

/// Splits [logical] into frames that each fit the conservative MTU.
///
/// Every fragment carries the same [Frame.msgId] so relays deduplicate and
/// forward each one independently — the mesh never reassembles, only the
/// destination does.
List<Frame> fragmentFrame(Frame logical) {
  final body = logical.payload;

  if (body.length <= maxPayloadLength) {
    return [logical];
  }

  final total =
      (body.length + fragmentPayloadLength - 1) ~/ fragmentPayloadLength;
  if (total > maxFragmentCount) {
    throw FrameFormatException(
      'payload of ${body.length} bytes needs $total fragments, '
      'above the $maxFragmentCount limit',
    );
  }

  final frames = <Frame>[];
  for (var index = 0; index < total; index++) {
    final start = index * fragmentPayloadLength;
    final end = (start + fragmentPayloadLength).clamp(0, body.length);
    final header = FragmentHeader(
      index: index,
      total: total,
      originalType: logical.type,
    );

    frames.add(
      Frame(
        type: FrameType.fragment,
        ttl: logical.ttl,
        flags: logical.flags.copyWith(fragmented: true),
        msgId: logical.msgId,
        srcHash: logical.srcHash,
        dstHash: logical.dstHash,
        payload: header.prepend(Uint8List.sublistView(body, start, end)),
      ),
    );
  }
  return frames;
}

class _Partial {
  _Partial({
    required this.total,
    required this.originalType,
    required this.template,
    required this.createdAt,
  }) : parts = List<Uint8List?>.filled(total, null);

  final int total;
  final FrameType originalType;
  final Frame template;
  final Duration createdAt;
  final List<Uint8List?> parts;

  int bufferedBytes = 0;

  bool get isComplete => parts.every((p) => p != null);

  /// Returns true when the fragment was newly stored, false when duplicate.
  bool store(int index, Uint8List body) {
    if (parts[index] != null) return false;
    parts[index] = body;
    bufferedBytes += body.length;
    return true;
  }

  Uint8List assemble() {
    final out = Uint8List(bufferedBytes);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part!.length, part);
      offset += part.length;
    }
    return out;
  }
}

/// Rebuilds fragmented messages under strict resource bounds.
///
/// The bounds are mandatory, not defensive: without them any nearby device can
/// exhaust memory by sending fragment 0 of a large message repeatedly and never
/// completing it.
class Reassembler {
  Reassembler({
    required ProtocolClock clock,
    this.maxPartialMessages = defaultMaxPartialMessages,
    this.maxBufferedBytes = defaultMaxBufferedBytes,
    this.expiry = reassemblyExpiry,
  }) : _clock = clock;

  final ProtocolClock _clock;
  final int maxPartialMessages;
  final int maxBufferedBytes;
  final Duration expiry;

  /// Insertion-ordered, so the first entry is always the oldest.
  final LinkedHashMap<MsgId, _Partial> _partials =
      LinkedHashMap<MsgId, _Partial>();

  int _bufferedBytes = 0;
  int _expiredCount = 0;
  int _evictedCount = 0;
  int _rejectedCount = 0;

  int get partialCount => _partials.length;
  int get bufferedBytes => _bufferedBytes;

  /// Partial messages dropped because they aged out.
  int get expiredCount => _expiredCount;

  /// Partial messages dropped to stay inside the resource bounds.
  int get evictedCount => _evictedCount;

  /// Frames dropped because they were malformed or inconsistent.
  int get rejectedCount => _rejectedCount;

  /// Feeds one received frame in. Returns the rebuilt message when this frame
  /// completed it, otherwise null.
  ///
  /// Never throws. A malformed fragment increments [rejectedCount] and is
  /// dropped, because a hostile or corrupted frame must not disturb traffic
  /// that is arriving correctly.
  ReassembledMessage? offer(Frame frame) {
    _sweepExpired();

    if (!frame.flags.fragmented) {
      return ReassembledMessage(
        type: frame.type,
        msgId: frame.msgId,
        srcHash: frame.srcHash,
        dstHash: frame.dstHash,
        flags: frame.flags,
        payload: frame.payload,
      );
    }

    final FragmentHeader header;
    try {
      header = FragmentHeader.parse(frame.payload);
    } on FrameFormatException {
      _rejectedCount++;
      return null;
    }

    final existing = _partials[frame.msgId];
    if (existing != null && existing.total != header.total) {
      _rejectedCount++;
      return null;
    }

    final partial =
        existing ??
        _Partial(
          total: header.total,
          originalType: header.originalType,
          template: frame,
          createdAt: _clock(),
        );
    if (existing == null) _partials[frame.msgId] = partial;

    final body = FragmentHeader.bodyOf(frame.payload);
    if (partial.store(header.index, body)) {
      _bufferedBytes += body.length;
    }

    if (!partial.isComplete) {
      _enforceBounds(protect: frame.msgId);
      return null;
    }

    _partials.remove(frame.msgId);
    _bufferedBytes -= partial.bufferedBytes;

    return ReassembledMessage(
      type: partial.originalType,
      msgId: frame.msgId,
      srcHash: partial.template.srcHash,
      dstHash: partial.template.dstHash,
      flags: partial.template.flags.copyWith(fragmented: false),
      payload: partial.assemble(),
    );
  }

  void _sweepExpired() {
    final cutoff = _clock() - expiry;
    final stale = _partials.entries
        .where((e) => e.value.createdAt <= cutoff)
        .map((e) => e.key)
        .toList(growable: false);

    for (final id in stale) {
      _bufferedBytes -= _partials.remove(id)!.bufferedBytes;
      _expiredCount++;
    }
  }

  void _enforceBounds({required MsgId protect}) {
    while (_partials.length > maxPartialMessages ||
        _bufferedBytes > maxBufferedBytes) {
      final oldest = _partials.keys.firstWhere(
        (id) => id != protect,
        orElse: () => protect,
      );
      final removed = _partials.remove(oldest);
      if (removed == null) return;
      _bufferedBytes -= removed.bufferedBytes;
      _evictedCount++;
      if (_partials.isEmpty) return;
    }
  }

  /// Drops every partial message. Used on transport restart and panic wipe.
  void clear() {
    _partials.clear();
    _bufferedBytes = 0;
  }
}
