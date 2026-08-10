import 'dart:typed_data';

import 'compression.dart';

/// LZ4 block format, in pure Dart.
///
/// Written out rather than taken from pub because every LZ4 package there is an
/// FFI binding to the C library, and `core_protocol` is deliberately free of
/// native dependencies — that is what makes it deterministic, testable
/// anywhere, and buildable on both platforms without a toolchain per target.
///
/// This is the *block* format, not the frame format: no magic number, no
/// checksum, and no stored uncompressed length. The frame header already says
/// whether a payload is compressed, so a second layer of framing would be pure
/// overhead on a protocol counting bytes against a 185-byte MTU.
///
/// ```
/// sequence := token | [literal length extension] | literals
///                   | offset (uint16 LE) | [match length extension]
/// token    := high nibble = literal length, low nibble = match length - 4
/// ```
///
/// A nibble of 15 means "keep reading bytes and adding them until one is not
/// 255". The final sequence in a block is literals only, with no offset.
class Lz4Compressor implements PayloadCompressor {
  const Lz4Compressor();

  /// Hard ceiling on what one block may expand to.
  ///
  /// The decompressor is fed bytes chosen by a stranger with a radio, and a few
  /// of them can ask for an unbounded copy. Without this, one frame exhausts
  /// memory. Set to match the reassembly cap, which is far above anything the
  /// protocol can legitimately carry.
  static const int maxDecompressedLength = 1 << 20;

  /// Shortest run worth encoding as a match. Fixed by the format.
  static const int _minMatch = 4;

  /// The last five bytes of a block are always literals, and the last match
  /// must end at least twelve bytes from the end. Both are format rules, and
  /// both exist so a decoder can copy in wide chunks without bounds checks.
  static const int _lastLiterals = 5;
  static const int _matchFindLimit = 12;

  /// 2^16 buckets of a 4-byte hash. Bigger finds more matches and costs more
  /// memory; this is the size the reference implementation uses at level 1.
  static const int _hashLog = 16;

  @override
  Uint8List compress(Uint8List input) {
    final out = BytesBuilder(copy: true);

    if (input.length < _matchFindLimit) {
      // Too short for any match to be legal. Emit it as one literal run.
      _emitLastLiterals(out, input, 0);
      return out.toBytes();
    }

    // Position of the last occurrence of each 4-byte hash, or -1.
    final table = Int32List(1 << _hashLog)..fillRange(0, 1 << _hashLog, -1);

    final limit = input.length - _matchFindLimit;
    var anchor = 0; // start of the literals not yet emitted
    var cursor = 0;

    while (cursor < limit) {
      final hash = _hash(input, cursor);
      final candidate = table[hash];
      table[hash] = cursor;

      // A candidate is only usable if it is inside the 64 KiB window the
      // 16-bit offset can express, and if it genuinely matches.
      if (candidate < 0 ||
          cursor - candidate > 0xFFFF ||
          !_matchesAt(input, candidate, cursor)) {
        cursor++;
        continue;
      }

      // Extend the match as far as it goes, stopping short of the tail the
      // format reserves for literals.
      var length = _minMatch;
      final maxLength = input.length - _lastLiterals - cursor;
      while (length < maxLength &&
          input[candidate + length] == input[cursor + length]) {
        length++;
      }

      _emitSequence(
        out,
        input,
        literalStart: anchor,
        literalEnd: cursor,
        offset: cursor - candidate,
        matchLength: length,
      );

      cursor += length;
      anchor = cursor;
    }

    _emitLastLiterals(out, input, anchor);
    return out.toBytes();
  }

  @override
  Uint8List decompress(Uint8List input) {
    // A single growable buffer rather than a BytesBuilder, because a match
    // copies from what has already been decoded. Reading that back out of a
    // builder on every sequence would make the whole decode quadratic.
    final out = _Output();
    var read = 0;

    while (read < input.length) {
      final token = input[read++];

      // ---- literals
      var literalLength = token >> 4;
      if (literalLength == 15) {
        final extension = _readExtension(input, read);
        literalLength += extension.value;
        read = extension.next;
      }
      if (read + literalLength > input.length) {
        throw const FormatException('lz4: literal run runs past the block');
      }
      out.addRange(input, read, literalLength);
      read += literalLength;

      // The final sequence is literals only, so anything less than the two
      // bytes of an offset means the block ends here.
      if (read >= input.length) break;
      if (read + 2 > input.length) {
        throw const FormatException('lz4: truncated match offset');
      }

      // ---- match
      final offset = input[read] | (input[read + 1] << 8);
      read += 2;
      if (offset == 0) {
        throw const FormatException('lz4: zero match offset');
      }

      var matchLength = (token & 0x0F) + _minMatch;
      if ((token & 0x0F) == 15) {
        final extension = _readExtension(input, read);
        matchLength += extension.value;
        read = extension.next;
      }

      if (offset > out.length) {
        throw const FormatException('lz4: match points before the output');
      }
      out.copyBack(offset, matchLength);
    }

    return out.toBytes();
  }

  // --------------------------------------------------------------- encoding

  static void _emitSequence(
    BytesBuilder out,
    Uint8List input, {
    required int literalStart,
    required int literalEnd,
    required int offset,
    required int matchLength,
  }) {
    final literalLength = literalEnd - literalStart;
    final encodedMatch = matchLength - _minMatch;

    final token =
        (literalLength >= 15 ? 15 << 4 : literalLength << 4) |
        (encodedMatch >= 15 ? 15 : encodedMatch);
    out.addByte(token);

    if (literalLength >= 15) _writeExtension(out, literalLength - 15);
    out.add(Uint8List.sublistView(input, literalStart, literalEnd));

    out
      ..addByte(offset & 0xFF)
      ..addByte((offset >> 8) & 0xFF);

    if (encodedMatch >= 15) _writeExtension(out, encodedMatch - 15);
  }

  static void _emitLastLiterals(BytesBuilder out, Uint8List input, int from) {
    final length = input.length - from;
    out.addByte(length >= 15 ? 15 << 4 : length << 4);
    if (length >= 15) _writeExtension(out, length - 15);
    if (length > 0) {
      out.add(Uint8List.sublistView(input, from, input.length));
    }
  }

  static void _writeExtension(BytesBuilder out, int remaining) {
    var value = remaining;
    while (value >= 255) {
      out.addByte(255);
      value -= 255;
    }
    out.addByte(value);
  }

  // --------------------------------------------------------------- decoding

  /// Reads a `255, 255, ..., n` length extension starting at [from].
  static ({int value, int next}) _readExtension(Uint8List input, int from) {
    var at = from;
    var total = 0;
    while (true) {
      if (at >= input.length) {
        throw const FormatException('lz4: truncated length extension');
      }
      final byte = input[at++];
      total += byte;
      if (byte != 255) break;
      // Checked inside the loop, not after it: a block of nothing but 0xFF
      // asks for an unbounded length, and waiting until the end to notice
      // means the loop has already run for as long as the attacker chose.
      if (total > maxDecompressedLength) {
        throw const FormatException(
          'lz4: length extension exceeds the ceiling',
        );
      }
    }
    return (value: total, next: at);
  }

  static int _hash(Uint8List input, int at) {
    final value =
        input[at] |
        (input[at + 1] << 8) |
        (input[at + 2] << 16) |
        (input[at + 3] << 24);
    // Knuth's multiplicative hash, masked to 32 bits for the web target.
    return ((value * 2654435761) & 0xFFFFFFFF) >>> (32 - _hashLog);
  }

  static bool _matchesAt(Uint8List input, int candidate, int cursor) {
    for (var i = 0; i < _minMatch; i++) {
      if (input[candidate + i] != input[cursor + i]) return false;
    }
    return true;
  }
}

/// A growable output buffer that can copy from itself.
///
/// Separate from `BytesBuilder` for one reason: an LZ4 match references bytes
/// already decoded, and a builder gives no way to read them back without
/// flattening the whole thing, which turns the decode quadratic.
class _Output {
  Uint8List _buffer = Uint8List(256);
  int length = 0;

  void _reserve(int extra) {
    if (length + extra > Lz4Compressor.maxDecompressedLength) {
      throw const FormatException('lz4: output exceeds the ceiling');
    }
    if (length + extra <= _buffer.length) return;

    var capacity = _buffer.length;
    while (capacity < length + extra) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, length, _buffer);
  }

  void addRange(Uint8List source, int start, int count) {
    if (count == 0) return;
    _reserve(count);
    _buffer.setRange(length, length + count, source, start);
    length += count;
  }

  /// Copies [count] bytes from [offset] back in the output to the end.
  ///
  /// Byte by byte, deliberately. An offset smaller than the count is legal and
  /// common — `abababab` is one match at offset two — so the copy has to read
  /// bytes this same loop is writing. `setRange` would read stale data.
  void copyBack(int offset, int count) {
    _reserve(count);
    final from = length - offset;
    for (var i = 0; i < count; i++) {
      _buffer[length + i] = _buffer[from + i];
    }
    length += count;
  }

  Uint8List toBytes() => Uint8List.sublistView(_buffer, 0, length);
}
