import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Compressor that always shrinks by dropping every second byte, and restores
/// by duplicating. Lossy, but deterministic and obviously "smaller", which is
/// all the policy under test cares about.
class HalvingCompressor implements PayloadCompressor {
  @override
  Uint8List compress(Uint8List input) =>
      Uint8List.fromList([for (var i = 0; i < input.length; i += 2) input[i]]);

  @override
  Uint8List decompress(Uint8List input) => Uint8List.fromList([
    for (final b in input) ...[b, b],
  ]);
}

/// Compressor that always makes the payload bigger, as real compressors do on
/// already-compressed input such as Opus audio.
class ExpandingCompressor implements PayloadCompressor {
  @override
  Uint8List compress(Uint8List input) =>
      Uint8List.fromList([...input, ...input]);

  @override
  Uint8List decompress(Uint8List input) =>
      Uint8List.sublistView(input, 0, input.length ~/ 2);
}

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i & 0xFF));

void main() {
  group('CompressionPolicy', () {
    test('leaves a payload below the threshold untouched', () {
      final policy = CompressionPolicy(compressor: HalvingCompressor());

      final result = policy.apply(_bytes(compressionThreshold));

      expect(result.compressed, isFalse);
      expect(result.payload, _bytes(compressionThreshold));
    });

    test('compresses a payload above the threshold when it gets smaller', () {
      final policy = CompressionPolicy(compressor: HalvingCompressor());

      final result = policy.apply(_bytes(compressionThreshold + 1));

      expect(result.compressed, isTrue);
      expect(result.payload.length, lessThan(compressionThreshold + 1));
    });

    test('keeps the original when compression does not shrink the payload', () {
      final policy = CompressionPolicy(compressor: ExpandingCompressor());
      final original = _bytes(compressionThreshold + 10);

      final result = policy.apply(original);

      expect(
        result.compressed,
        isFalse,
        reason: 'sending an expanded payload would waste scarce mesh bandwidth',
      );
      expect(result.payload, original);
    });

    test('restores a compressed payload', () {
      final policy = CompressionPolicy(compressor: HalvingCompressor());
      final result = policy.apply(_bytes(compressionThreshold + 1));

      final restored = policy.restore(
        result.payload,
        compressed: result.compressed,
      );

      expect(
        restored.length,
        (compressionThreshold + 1) + ((compressionThreshold + 1) % 2),
      );
    });

    test('returns an uncompressed payload unchanged on restore', () {
      final policy = CompressionPolicy(compressor: HalvingCompressor());
      final original = _bytes(10);

      expect(policy.restore(original, compressed: false), original);
    });

    test(
      'skips compression entirely for payload types that are already compressed',
      () {
        final policy = CompressionPolicy(compressor: HalvingCompressor());

        final result = policy.apply(
          _bytes(compressionThreshold + 50),
          type: FrameType.voice,
        );

        expect(
          result.compressed,
          isFalse,
          reason:
              'Opus output does not compress and the attempt costs CPU on a '
              'battery-constrained device',
        );
      },
    );

    test('surfaces a corrupt compressed payload as a format exception', () {
      final policy = CompressionPolicy(compressor: _ThrowingCompressor());

      expect(
        () => policy.restore(_bytes(10), compressed: true),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });
}

class _ThrowingCompressor implements PayloadCompressor {
  @override
  Uint8List compress(Uint8List input) => input;

  @override
  Uint8List decompress(Uint8List input) => throw StateError('corrupt stream');
}
