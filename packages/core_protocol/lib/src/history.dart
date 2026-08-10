import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A request to be caught up on a room.
///
/// Sent on joining. Encrypted with the room key like everything else in a room,
/// so only members can read it — though the fact that *somebody* asked is
/// visible to anyone relaying the frame, in the same way a message is.
@immutable
class HistoryRequest {
  const HistoryRequest({this.since = defaultWindow});

  /// How far back the asker wants.
  final Duration since;

  /// What a fresh join asks for.
  static const Duration defaultWindow = Duration(hours: 12);

  /// The furthest back anyone is allowed to ask.
  ///
  /// Not politeness — a clamp. Without it a peer can ask for a thousand years
  /// and make this device read its whole message table into memory to answer.
  static const Duration maxWindow = Duration(days: 7);

  static const int _length = 4;

  Uint8List encode() {
    final out = Uint8List(_length);
    ByteData.view(out.buffer).setUint32(0, _clamped().inSeconds, Endian.big);
    return out;
  }

  Duration _clamped() => since > maxWindow ? maxWindow : since;

  static HistoryRequest? decode(Uint8List bytes) {
    if (bytes.length < _length) return null;
    final seconds = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      _length,
    ).getUint32(0, Endian.big);

    // Clamped on the way in as well as on the way out. The sender's copy of
    // this class is not the one that has to survive the answer.
    final asked = Duration(seconds: seconds);
    return HistoryRequest(since: asked > maxWindow ? maxWindow : asked);
  }
}

/// One remembered message, as shared with someone catching up.
@immutable
class HistoryEntry {
  const HistoryEntry({
    required this.senderKey,
    required this.sequence,
    required this.sentAt,
    required this.body,
  });

  /// Four identity bytes, the same hint an [AppEnvelope] carries. Enough to
  /// deduplicate against and to put a name on, never enough to trust.
  final Uint8List senderKey;

  final int sequence;

  /// When the *sharing* device recorded it.
  ///
  /// Not the original sender's clock, which nothing on the mesh carries. Two
  /// people catching up from different sharers can therefore see slightly
  /// different times for the same message, which is honest: nobody knows the
  /// real one.
  final DateTime sentAt;

  final String body;

  /// 4-byte key + 4-byte sequence + 8-byte timestamp + 2-byte body length.
  static const int headerLength = 18;
}

/// A batch of remembered messages.
///
/// Bounded twice over, by count and by bytes. An unbounded answer would either
/// exhaust the asker's memory or fragment into hundreds of frames and flood the
/// room — and both are reachable by asking politely, so neither can be left to
/// good behaviour.
@immutable
class HistoryBundle {
  const HistoryBundle({required this.entries});

  final List<HistoryEntry> entries;

  static const int maxEntries = 100;
  static const int maxBytes = 8 * 1024;

  /// The newest of [candidates] that fit, oldest first.
  ///
  /// Anything outside [since] is dropped before the size limits apply, so a
  /// narrow request is answered narrowly rather than being padded out with old
  /// messages that happen to fit.
  static HistoryBundle of(
    List<HistoryEntry> candidates, {
    Duration? since,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final cutoff = since == null ? null : at.subtract(since);

    final eligible = [
      for (final entry in candidates)
        if (cutoff == null || entry.sentAt.isAfter(cutoff)) entry,
    ]..sort((a, b) => a.sentAt.compareTo(b.sentAt));

    // Filled from the newest backwards, then reversed. Choosing from the old
    // end would fill the bundle with the least useful messages.
    final kept = <HistoryEntry>[];
    var bytes = 1;

    for (final entry in eligible.reversed) {
      if (kept.length >= maxEntries) break;
      final size = HistoryEntry.headerLength + utf8.encode(entry.body).length;
      // A single message too large to ever fit is skipped rather than
      // truncated: truncating would silently corrupt what somebody said.
      if (size > maxBytes) continue;
      if (bytes + size > maxBytes) break;
      bytes += size;
      kept.add(entry);
    }

    return HistoryBundle(entries: kept.reversed.toList());
  }

  Uint8List encode() {
    final bodies = [for (final entry in entries) utf8.encode(entry.body)];
    final total =
        1 +
        entries.length * HistoryEntry.headerLength +
        bodies.fold<int>(0, (sum, b) => sum + b.length);

    final out = Uint8List(total);
    final view = ByteData.view(out.buffer);
    out[0] = entries.length;

    var at = 1;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      out.setRange(at, at + 4, entry.senderKey);
      view.setUint32(at + 4, entry.sequence, Endian.big);
      view.setUint64(at + 8, entry.sentAt.millisecondsSinceEpoch, Endian.big);
      view.setUint16(at + 16, bodies[i].length, Endian.big);
      at += HistoryEntry.headerLength;
      out.setRange(at, at + bodies[i].length, bodies[i]);
      at += bodies[i].length;
    }

    return out;
  }

  /// Reads a bundle, or null if the bytes are not exactly one.
  ///
  /// Null rather than an exception: this decodes attacker-chosen input on the
  /// inbound path, and one dropped bundle is the right cost for a bad one.
  static HistoryBundle? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.length > maxBytes) return null;

    final count = bytes[0];
    if (count > maxEntries) return null;

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final entries = <HistoryEntry>[];
    var at = 1;

    for (var i = 0; i < count; i++) {
      if (at + HistoryEntry.headerLength > bytes.length) return null;

      final length = view.getUint16(at + 16, Endian.big);
      final start = at + HistoryEntry.headerLength;
      if (start + length > bytes.length) return null;

      entries.add(
        HistoryEntry(
          senderKey: Uint8List.fromList(bytes.sublist(at, at + 4)),
          sequence: view.getUint32(at + 4, Endian.big),
          sentAt: DateTime.fromMillisecondsSinceEpoch(
            view.getUint64(at + 8, Endian.big),
            isUtc: true,
          ),
          body: utf8.decode(
            bytes.sublist(start, start + length),
            allowMalformed: true,
          ),
        ),
      );
      at = start + length;
    }

    // Bytes left over means this is not the bundle that was sent, and there is
    // no way to know which half to believe.
    if (at != bytes.length) return null;

    return HistoryBundle(entries: entries);
  }
}
