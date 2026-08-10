import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Several messages travelling as one.
///
/// Each frame on a radio costs a connection event, a header, a nonce and a
/// 16-byte authentication tag. For a mesh where most messages are a handful of
/// words, that overhead is the majority of the airtime.
void main() {
  Uint8List body(int n, [int length = 4]) =>
      Uint8List.fromList(List.filled(length, n));

  test('a batch survives a round trip', () {
    final batch = PayloadBatch(items: [body(1), body(2, 10)]);

    final decoded = PayloadBatch.decode(batch.encode())!;

    expect(decoded.items, hasLength(2));
    expect(decoded.items.first, body(1));
    expect(decoded.items.last, body(2, 10));
  });

  test('a batch of one is legal', () {
    expect(
      PayloadBatch.decode(PayloadBatch(items: [body(1)]).encode())!.items,
      hasLength(1),
    );
  });

  test('an empty batch is refused', () {
    // Nothing sensible to do with it, and it would cost a frame to say
    // nothing.
    expect(PayloadBatch.decode(const PayloadBatch(items: []).encode()), isNull);
  });

  test('refuses a length that runs off the end', () {
    final bytes = PayloadBatch(items: [body(1)]).encode();
    bytes[1] = 0xFF;
    bytes[2] = 0xFF;

    expect(PayloadBatch.decode(bytes), isNull);
  });

  test('refuses trailing rubbish', () {
    final bytes = PayloadBatch(items: [body(1)]).encode();
    final padded = Uint8List(bytes.length + 2)
      ..setRange(0, bytes.length, bytes);

    expect(PayloadBatch.decode(padded), isNull);
  });

  test('refuses an empty input', () {
    expect(PayloadBatch.decode(Uint8List(0)), isNull);
  });

  group('deciding what to combine', () {
    test('combines several small items', () {
      final planned = PayloadBatch.plan([body(1), body(2), body(3)]);

      expect(planned, hasLength(1));
      expect(planned.single.items, hasLength(3));
    });

    test('never exceeds the size ceiling', () {
      final big = [for (var i = 0; i < 8; i++) body(i, 400)];

      final planned = PayloadBatch.plan(big, maxBytes: 1000);

      for (final batch in planned) {
        expect(batch.encode().length, lessThanOrEqualTo(1000));
      }
      // Nothing may be silently dropped: a batching layer that loses messages
      // is worse than no batching layer.
      expect(
        planned.fold<int>(0, (sum, b) => sum + b.items.length),
        big.length,
      );
    });

    test('keeps order', () {
      final planned = PayloadBatch.plan([
        for (var i = 0; i < 6; i++) body(i, 400),
      ], maxBytes: 1000);

      final flat = [for (final b in planned) ...b.items];
      for (var i = 0; i < 6; i++) {
        expect(flat[i].first, i);
      }
    });

    test('an item too large to batch travels on its own', () {
      final planned = PayloadBatch.plan([
        body(1, 4),
        body(2, 5000),
        body(3, 4),
      ], maxBytes: 1000);

      expect(
        planned.expand((b) => b.items).map((i) => i.length),
        [4, 5000, 4],
        reason: 'oversized items must still be sent, just not combined',
      );
    });

    test('nothing in, nothing out', () {
      expect(PayloadBatch.plan(const []), isEmpty);
    });

    test('never puts more than the count ceiling in one batch', () {
      final many = [for (var i = 0; i < 40; i++) body(1)];

      for (final batch in PayloadBatch.plan(many)) {
        expect(batch.items.length, lessThanOrEqualTo(PayloadBatch.maxItems));
      }
    });
  });
}
