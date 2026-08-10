import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Several payloads carried as one.
///
/// Every frame on a radio costs a connection event, a 14-byte header, a nonce
/// and a 16-byte authentication tag — and, since padding landed, a round up to
/// the next block size. For a mesh whose typical message is a handful of words
/// that overhead is most of the airtime, and combining what is already queued
/// for the same recipient removes it without changing what is said.
///
/// Wire format:
/// ```
/// batch := uint8 count | ( uint16 length | payload )*
/// ```
@immutable
class PayloadBatch {
  const PayloadBatch({required this.items});

  final List<Uint8List> items;

  /// The most that ever travels in one batch.
  ///
  /// A ceiling on both axes: too many items and a single lost frame costs the
  /// lot, too many bytes and it fragments into more frames than it saved.
  static const int maxItems = 16;
  static const int maxBytes = 4 * 1024;

  static const int _lengthPrefix = 2;

  /// Groups [payloads] into batches, in order, respecting both ceilings.
  ///
  /// Anything too large to batch is emitted alone rather than dropped. A
  /// batching layer that silently loses messages is worse than none.
  static List<PayloadBatch> plan(
    List<Uint8List> payloads, {
    int maxBytes = maxBytes,
    int maxItems = maxItems,
  }) {
    final batches = <PayloadBatch>[];
    var current = <Uint8List>[];
    var bytes = 1;

    void flush() {
      if (current.isEmpty) return;
      batches.add(PayloadBatch(items: current));
      current = <Uint8List>[];
      bytes = 1;
    }

    for (final payload in payloads) {
      final size = _lengthPrefix + payload.length;

      // Too big to share a frame with anything. It still has to go, so it goes
      // by itself and the accumulated batch is flushed first to keep order.
      if (size + 1 > maxBytes) {
        flush();
        batches.add(PayloadBatch(items: [payload]));
        continue;
      }

      if (current.length >= maxItems || bytes + size > maxBytes) flush();
      current.add(payload);
      bytes += size;
    }

    flush();
    return batches;
  }

  Uint8List encode() {
    final total =
        1 + items.fold<int>(0, (sum, i) => sum + _lengthPrefix + i.length);
    final out = Uint8List(total);
    final view = ByteData.view(out.buffer);

    out[0] = items.length;
    var at = 1;
    for (final item in items) {
      view.setUint16(at, item.length, Endian.big);
      at += _lengthPrefix;
      out.setRange(at, at + item.length, item);
      at += item.length;
    }
    return out;
  }

  /// Reads a batch, or null if the bytes are not exactly one.
  ///
  /// Null rather than an exception: this is decoded from attacker-chosen input
  /// on the inbound path, and one dropped frame is the right cost for a bad
  /// one.
  static PayloadBatch? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    final count = bytes[0];
    // Zero would cost a frame to say nothing, and is more likely to be a bug
    // or a probe than a real sender.
    if (count == 0) return null;

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final items = <Uint8List>[];
    var at = 1;

    for (var i = 0; i < count; i++) {
      if (at + _lengthPrefix > bytes.length) return null;
      final length = view.getUint16(at, Endian.big);
      at += _lengthPrefix;
      if (at + length > bytes.length) return null;
      items.add(Uint8List.fromList(bytes.sublist(at, at + length)));
      at += length;
    }

    if (at != bytes.length) return null;
    return PayloadBatch(items: items);
  }
}
