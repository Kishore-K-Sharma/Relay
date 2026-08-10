import 'dart:math';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Padding exists so the size of a frame stops describing the message inside
/// it.
///
/// Without it, an observer with a radio reads message lengths off the air. That
/// is enough to tell a one-word reply from a paragraph, to spot the long
/// message everyone forwards, and to fingerprint a conversation by its rhythm
/// of sizes — none of which the encryption hides.
///
/// It is not free. A fifteen-byte "on my way" becomes a padded block, which
/// costs airtime in a crowd where everyone is transmitting. That trade is why
/// the policy is a value the caller passes rather than something baked in.
void main() {
  const padding = PaddingPolicy();

  test('a short payload is padded up to the smallest bucket', () {
    expect(padding.paddedLength(1), PaddingPolicy.buckets.first);
    expect(padding.paddedLength(20), PaddingPolicy.buckets.first);
  });

  test('a payload that exactly fills a bucket stays in it', () {
    // The block carries a four-byte length prefix, so a bucket holds four
    // fewer bytes than its size. Off by one here pushes every full block up to
    // the next size and doubles the airtime of the commonest message length.
    for (final bucket in PaddingPolicy.buckets) {
      expect(
        padding.paddedLength(bucket - 4),
        bucket,
        reason: 'a payload filling the $bucket bucket',
      );
      expect(
        padding.paddedLength(bucket - 3),
        greaterThan(bucket),
        reason: 'one byte more than the $bucket bucket holds',
      );
    }
  });

  test('a payload one byte over a bucket moves to the next', () {
    expect(padding.paddedLength(65), 128);
    expect(padding.paddedLength(129), 256);
  });

  test('payloads above the largest bucket step in fixed blocks', () {
    // Unbounded buckets would mean one enormous message rounds up to something
    // absurd. Past the top bucket the step is constant instead.
    final top = PaddingPolicy.buckets.last;

    expect(padding.paddedLength(top + 1), top + PaddingPolicy.blockAbove);
    expect(
      padding.paddedLength(top + PaddingPolicy.blockAbove + 1),
      top + 2 * PaddingPolicy.blockAbove,
    );
  });

  test('padding then stripping returns the original bytes', () {
    final random = Random(4);
    for (final length in [0, 1, 63, 64, 65, 200, 1000, 5000]) {
      final original = Uint8List.fromList(
        List.generate(length, (_) => random.nextInt(256)),
      );

      final padded = padding.pad(original);
      expect(padding.strip(padded), original, reason: 'length $length');
    }
  });

  test('the padded block is the bucket size', () {
    expect(padding.pad(Uint8List(20)).length, PaddingPolicy.buckets.first);
  });

  test('messages of different lengths become the same size on the wire', () {
    // The entire point, stated as one assertion.
    final short = padding.pad(Uint8List.fromList([1]));
    final longer = padding.pad(Uint8List.fromList(List.filled(50, 2)));

    expect(short.length, longer.length);
  });

  test('the padding is random, not zeros', () {
    // Zeros are free to compress away and make padded blocks recognisable as
    // padded. Random bytes cost nothing extra and look like everything else.
    final first = padding.pad(Uint8List.fromList([1, 2, 3]));
    final second = padding.pad(Uint8List.fromList([1, 2, 3]));

    expect(first, isNot(second));
    expect(padding.strip(first), padding.strip(second));
  });

  test('a block whose declared length exceeds it is refused', () {
    // Reached only via a corrupt or hostile peer, and it must not read past
    // the end of the buffer.
    final block = Uint8List(16);
    ByteData.view(block.buffer).setUint32(0, 9999, Endian.big);

    expect(() => padding.strip(block), throwsA(isA<FrameFormatException>()));
  });

  test('a block too short to hold a length is refused', () {
    expect(
      () => padding.strip(Uint8List(2)),
      throwsA(isA<FrameFormatException>()),
    );
  });

  test('padding can be switched off entirely', () {
    // The cost is real in a dense crowd, so it has to be possible to decline
    // it. Off means off: no length prefix, no block, nothing added.
    const none = PaddingPolicy.disabled;
    final original = Uint8List.fromList([1, 2, 3]);

    expect(none.pad(original), original);
    expect(none.strip(original), original);
  });
}
