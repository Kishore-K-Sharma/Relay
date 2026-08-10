import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// LZ4 block format, implemented rather than pulled in.
///
/// `core_protocol` is pure Dart with no native dependency, which is what makes
/// it deterministic and testable on any machine. Every LZ4 package on pub is an
/// FFI binding to the C library, so taking one would have put a native
/// dependency underneath the most correctness-critical package in the project.
///
/// The decompressor matters more than the compressor. It is fed bytes chosen by
/// a stranger with a radio, so half these tests are about what it does with
/// input that was never produced by the compressor at all.
void main() {
  final codec = const Lz4Compressor();

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  Uint8List roundTrip(Uint8List input) =>
      codec.decompress(codec.compress(input));

  group('round trips', () {
    test('empty input', () {
      expect(roundTrip(Uint8List(0)), isEmpty);
    });

    test('a single byte', () {
      expect(roundTrip(bytes([42])), [42]);
    });

    test('input shorter than the minimum match', () {
      // Below four bytes there is nothing a match could reference, so this is
      // the path where the compressor has to emit pure literals.
      expect(roundTrip(bytes([1, 2, 3])), [1, 2, 3]);
    });

    test('highly repetitive input', () {
      final input = Uint8List.fromList(List.filled(4000, 0x41));

      expect(roundTrip(input), input);
    });

    test('and repetitive input actually gets smaller', () {
      final input = Uint8List.fromList(List.filled(4000, 0x41));

      // The whole reason this exists. A compressor that round-trips but never
      // shrinks anything is an expensive no-op.
      expect(codec.compress(input).length, lessThan(input.length ~/ 10));
    });

    test('real chat traffic', () {
      final input = Uint8List.fromList(
        utf8.encode(
          'meeting by the north gate at nine. meeting by the north gate at '
          'nine. bring water, bring water, bring water. see you there.',
        ),
      );

      expect(roundTrip(input), input);
      expect(codec.compress(input).length, lessThan(input.length));
    });

    test('incompressible input survives even though it grows', () {
      // Random bytes cannot be compressed. The block format still has to encode
      // them, and the policy above decides not to use the result.
      final random = Random(7);
      final input = Uint8List.fromList(
        List.generate(2000, (_) => random.nextInt(256)),
      );

      expect(roundTrip(input), input);
    });

    test('every length from 0 to 300', () {
      // The block format has awkward edges: the last sequence must be literals
      // only, and it must end with at least five of them. Off-by-one there
      // shows up at specific lengths and nowhere else.
      final random = Random(11);
      for (var length = 0; length <= 300; length++) {
        final input = Uint8List.fromList(
          List.generate(length, (i) => random.nextInt(4) + i % 3),
        );

        expect(roundTrip(input), input, reason: 'length $length');
      }
    });

    test('a long run of overlapping matches', () {
      // 'abababab...' compresses to a match whose offset is smaller than its
      // length. Copying it with a bulk move instead of byte by byte silently
      // produces the wrong output.
      final input = Uint8List.fromList(
        List.generate(1000, (i) => i.isEven ? 0x61 : 0x62),
      );

      expect(roundTrip(input), input);
    });

    test('an offset of one, repeated far beyond the match length', () {
      final input = Uint8List.fromList([1, ...List.filled(500, 9), 2]);

      expect(roundTrip(input), input);
    });
  });

  group('decoding input we did not produce', () {
    test('a literals-only block, built by hand from the spec', () {
      // Token 0x50: five literals, no match. The last sequence in a block is
      // literals only, which is exactly this.
      final block = bytes([0x50, 1, 2, 3, 4, 5]);

      expect(codec.decompress(block), [1, 2, 3, 4, 5]);
    });

    test('a block with a match, built by hand from the spec', () {
      // Token 0x54: five literals, then a match of 4 + 4 = 8 bytes at offset 5,
      // then a final token 0x50 with five literals.
      final block = bytes([
        0x54, 1, 2, 3, 4, 5, // literals
        0x05, 0x00, // little-endian offset of 5
        0x50, 6, 7, 8, 9, 10, // final literals
      ]);

      expect(codec.decompress(block), [
        1, 2, 3, 4, 5, // literals
        1, 2, 3, 4, 5, 1, 2, 3, // the match, wrapping round
        6, 7, 8, 9, 10,
      ]);
    });

    test('a length escape of 15 plus continuation bytes', () {
      // Literal length nibble 15 means "read more bytes until one is not 255".
      final block = bytes([0xF0, 5, ...List.filled(20, 0x7A)]);

      expect(codec.decompress(block), hasLength(20));
    });
  });

  group('hostile input', () {
    test('a truncated block throws rather than reading past the end', () {
      // Claims five literals and supplies two.
      expect(
        () => codec.decompress(bytes([0x50, 1, 2])),
        throwsA(isA<FormatException>()),
      );
    });

    test('a match offset pointing before the start of the output', () {
      expect(
        () => codec.decompress(bytes([0x04, 0x10, 0x00, 0x50, 1, 2, 3, 4, 5])),
        throwsA(isA<FormatException>()),
      );
    });

    test('a zero match offset', () {
      // Zero is not a legal offset and would be an infinite copy loop.
      expect(
        () => codec.decompress(bytes([0x14, 9, 0x00, 0x00])),
        throwsA(isA<FormatException>()),
      );
    });

    test('a truncated length escape', () {
      expect(
        () => codec.decompress(bytes([0xF0, 0xFF, 0xFF])),
        throwsA(isA<FormatException>()),
      );
    });

    test('a decompression bomb is refused', () {
      // A few bytes that expand without limit. Unbounded, a stranger on the
      // radio could exhaust memory with one frame, so the decoder stops at a
      // ceiling far above any real payload.
      // One literal, then a match at offset 1 — so every copied byte is the
      // same one — with a length escape that keeps saying 255. Enough of them
      // to ask for well over the ceiling from about five kilobytes of input.
      final bomb = BytesBuilder()
        ..add([0x1F, 0x41, 0x01, 0x00])
        ..add(List.filled(5000, 0xFF))
        ..add([0x00]);

      expect(
        () => codec.decompress(bomb.toBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('the ceiling is above anything the protocol can carry', () {
      // 1 MiB matches the reassembly cap. A legitimate message can never reach
      // it, so the guard cannot fire on real traffic.
      expect(
        Lz4Compressor.maxDecompressedLength,
        greaterThanOrEqualTo(1 << 20),
      );
    });
  });

  group('the policy uses it', () {
    test('a large repetitive payload travels compressed', () {
      const policy = CompressionPolicy(compressor: Lz4Compressor());
      final payload = Uint8List.fromList(List.filled(1000, 0x41));

      final result = policy.apply(payload);

      expect(result.compressed, isTrue);
      expect(result.payload.length, lessThan(payload.length));
      expect(policy.restore(result.payload, compressed: true), payload);
    });

    test('a small payload is left alone', () {
      const policy = CompressionPolicy(compressor: Lz4Compressor());
      final payload = Uint8List.fromList(List.filled(64, 0x41));

      expect(policy.apply(payload).compressed, isFalse);
    });

    test('random data is left alone rather than sent larger', () {
      const policy = CompressionPolicy(compressor: Lz4Compressor());
      final random = Random(3);
      final payload = Uint8List.fromList(
        List.generate(1000, (_) => random.nextInt(256)),
      );

      expect(policy.apply(payload).compressed, isFalse);
    });

    test('a corrupt compressed payload is a frame error, not a crash', () {
      const policy = CompressionPolicy(compressor: Lz4Compressor());

      expect(
        () => policy.restore(bytes([0x50, 1, 2]), compressed: true),
        throwsA(isA<FrameFormatException>()),
      );
    });
  });
}
