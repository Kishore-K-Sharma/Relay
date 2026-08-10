import 'dart:collection';
import 'dart:math';

import 'package:meta/meta.dart';

import 'fragmentation.dart' show FragmentHeader, ProtocolClock;
import 'frame.dart';

/// How long a message id is remembered for deduplication.
const Duration dedupExpiry = Duration(minutes: 10);

/// Capacity of the deduplication table.
const int dedupMaxEntries = 2000;

/// Lower bound of the random delay applied before relaying.
const Duration relayJitterMin = Duration(milliseconds: 20);

/// Upper bound of the random delay applied before relaying.
const Duration relayJitterMax = Duration(milliseconds: 150);

/// Number of *other* peers that must be heard carrying a frame before this
/// device concludes the frame is already well covered and stays quiet.
const int suppressionThreshold = 2;

/// How long witness observations are retained.
const Duration witnessExpiry = Duration(seconds: 30);

/// Produces a delay inside the given window. Injected so tests are deterministic.
typedef JitterSource = Duration Function(Duration min, Duration max);

/// Identifies a frame for deduplication.
///
/// Keying on [MsgId] alone is wrong: every fragment of a message deliberately
/// carries the same id so the destination can group them, which means a
/// msgId-only dedup table would discard every fragment after the first and no
/// multi-fragment message would ever cross a relay. The fragment index is
/// therefore part of the key.
@immutable
class FrameKey {
  const FrameKey(this.msgId, this.fragmentIndex);

  /// Key for a frame that is not fragmented.
  const FrameKey.whole(this.msgId) : fragmentIndex = -1;

  /// Derives the key from a received frame.
  ///
  /// A fragmented frame with an unreadable sub-header falls back to the whole
  /// message key; the reassembler rejects it separately.
  factory FrameKey.of(Frame frame) {
    if (!frame.flags.fragmented) return FrameKey.whole(frame.msgId);
    try {
      return FrameKey(frame.msgId, FragmentHeader.parse(frame.payload).index);
    } on FrameFormatException {
      return FrameKey.whole(frame.msgId);
    }
  }

  final MsgId msgId;

  /// -1 when the frame is not fragmented.
  final int fragmentIndex;

  @override
  bool operator ==(Object other) =>
      other is FrameKey &&
      other.msgId == msgId &&
      other.fragmentIndex == fragmentIndex;

  @override
  int get hashCode => Object.hash(msgId, fragmentIndex);

  @override
  String toString() => fragmentIndex < 0
      ? 'FrameKey(${msgId.toHex()})'
      : 'FrameKey(${msgId.toHex()}#$fragmentIndex)';
}

/// Default jitter source, backed by a non-cryptographic RNG.
JitterSource randomJitter([Random? random]) {
  final rng = random ?? Random();
  return (min, max) {
    final span = max.inMicroseconds - min.inMicroseconds;
    return Duration(microseconds: min.inMicroseconds + rng.nextInt(span + 1));
  };
}

/// Why a frame was not acted on.
enum RelayDrop {
  /// Already seen; the mesh has handled it.
  duplicate,

  /// This device originated the frame and is hearing its own echo.
  ownFrame,

  /// The hop counter is exhausted.
  hopLimitReached,
}

/// The outcome of receiving one frame. Purely descriptive — the caller performs
/// the I/O, which keeps this class testable with no transport present.
@immutable
class RelayDecision {
  const RelayDecision({
    required this.deliverLocally,
    required this.relayFrame,
    required this.jitter,
    required this.excludePeer,
    required this.drop,
  });

  const RelayDecision.dropped(RelayDrop reason)
    : deliverLocally = false,
      relayFrame = null,
      jitter = Duration.zero,
      excludePeer = null,
      drop = reason;

  /// Whether this frame should be handed up for decryption.
  final bool deliverLocally;

  /// The frame to rebroadcast, already hop-decremented. Null means do not relay.
  final Frame? relayFrame;

  /// How long to wait before rebroadcasting, to avoid synchronised collisions.
  final Duration jitter;

  /// Peer that must be excluded from the rebroadcast — the one it arrived from.
  final String? excludePeer;

  /// Set when the frame was not acted on at all.
  final RelayDrop? drop;

  bool get isDropped => drop != null;
}

/// Bounded, time-expiring set of message ids.
///
/// A duplicate arrival deliberately does *not* refresh an entry's position. If
/// it did, a peer repeating one id could pin the table and evict everything
/// else.
class DedupSet {
  DedupSet({
    required ProtocolClock clock,
    this.maxEntries = dedupMaxEntries,
    this.expiry = dedupExpiry,
  }) : _clock = clock;

  final ProtocolClock _clock;
  final int maxEntries;
  final Duration expiry;

  final LinkedHashMap<FrameKey, Duration> _entries =
      LinkedHashMap<FrameKey, Duration>();

  int get length {
    _sweep();
    return _entries.length;
  }

  bool contains(FrameKey id) {
    _sweep();
    return _entries.containsKey(id);
  }

  /// Records [id]. Returns true when it had not been seen, false when it had.
  bool addIfNew(FrameKey id) {
    _sweep();
    if (_entries.containsKey(id)) return false;

    _entries[id] = _clock();
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  void clear() => _entries.clear();

  void _sweep() {
    final cutoff = _clock() - expiry;
    // Insertion order is chronological, so stop at the first live entry.
    while (_entries.isNotEmpty && _entries.values.first <= cutoff) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// Decides what to do with each received frame.
///
/// This is the reference implementation of the relay algorithm in
/// ARCHITECTURE.md section 3.5. `RelayEngine.kt` and `RelayEngine.swift` must
/// reproduce it exactly, verified by the shared vectors in `testvectors/relay`.
///
/// It never inspects or decrypts a payload.
class RelayEngine {
  RelayEngine({
    required this.localHash,
    required ProtocolClock clock,
    JitterSource? jitter,
    DedupSet? dedup,
  }) : _clock = clock,
       _jitter = jitter ?? randomJitter(),
       _seen = dedup ?? DedupSet(clock: clock);

  /// This device's truncated address hash.
  final int localHash;

  final ProtocolClock _clock;
  final JitterSource _jitter;
  final DedupSet _seen;

  /// Peers heard carrying each in-flight message id, with the time observed.
  final Map<FrameKey, Map<String, Duration>> _witnesses =
      <FrameKey, Map<String, Duration>>{};

  int _relayedCount = 0;
  int _droppedCount = 0;

  int get relayedCount => _relayedCount;
  int get droppedCount => _droppedCount;

  /// Applies the relay algorithm to one received frame.
  RelayDecision receive(Frame frame, {required String fromPeer}) {
    _sweepWitnesses();

    if (frame.srcHash == localHash) {
      _droppedCount++;
      return const RelayDecision.dropped(RelayDrop.ownFrame);
    }

    final key = FrameKey.of(frame);

    if (!_seen.addIfNew(key)) {
      // A duplicate from a distinct peer is the signal that this frame is
      // already circulating well, so record it and stay quiet.
      _recordWitness(key, fromPeer);
      _droppedCount++;
      return const RelayDecision.dropped(RelayDrop.duplicate);
    }

    _recordWitness(key, fromPeer);

    final isForUs = frame.dstHash == localHash;
    final deliverLocally = isForUs || frame.isBroadcast;

    // A frame addressed specifically to us has arrived; forwarding it further
    // would only add traffic.
    if (isForUs) {
      return RelayDecision(
        deliverLocally: true,
        relayFrame: null,
        jitter: Duration.zero,
        excludePeer: fromPeer,
        drop: null,
      );
    }

    if (frame.ttl == 0) {
      _droppedCount++;
      return RelayDecision(
        deliverLocally: deliverLocally,
        relayFrame: null,
        jitter: Duration.zero,
        excludePeer: fromPeer,
        drop: deliverLocally ? null : RelayDrop.hopLimitReached,
      );
    }

    _relayedCount++;
    return RelayDecision(
      deliverLocally: deliverLocally,
      relayFrame: frame.decrementTtl(),
      jitter: _jitter(relayJitterMin, relayJitterMax),
      excludePeer: fromPeer,
      drop: null,
    );
  }

  /// Records that [fromPeer] was also heard carrying [id].
  void witness(FrameKey id, {required String fromPeer}) =>
      _recordWitness(id, fromPeer);

  /// Whether the pending relay of [id] should be abandoned because enough other
  /// peers were heard carrying it during the jitter window.
  ///
  /// [origin] is the peer the frame arrived from and never counts toward the
  /// threshold — hearing it once from the sender proves nothing about coverage.
  bool shouldSuppress(FrameKey id, {required String origin}) {
    _sweepWitnesses();
    final heard = _witnesses[id];
    if (heard == null) return false;

    final others = heard.keys.where((peer) => peer != origin).length;
    return others >= suppressionThreshold;
  }

  void _recordWitness(FrameKey id, String peer) {
    (_witnesses[id] ??= <String, Duration>{})[peer] = _clock();
  }

  void _sweepWitnesses() {
    final cutoff = _clock() - witnessExpiry;
    _witnesses.removeWhere((_, peers) {
      peers.removeWhere((_, at) => at <= cutoff);
      return peers.isEmpty;
    });
  }

  void clear() {
    _seen.clear();
    _witnesses.clear();
  }
}
