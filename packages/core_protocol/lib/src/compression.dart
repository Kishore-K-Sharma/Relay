import 'dart:typed_data';

import 'frame.dart';

/// Payloads at or below this size are not worth compressing: the CPU cost and
/// the risk of expansion outweigh the saving on a few dozen bytes.
const int compressionThreshold = 128;

/// Frame types whose payload is already compressed, so a second pass only
/// burns battery.
const Set<FrameType> incompressibleTypes = {FrameType.voice};

/// A pluggable compression backend.
///
/// Kept abstract so [core_protocol] stays pure Dart with no native dependency,
/// and so the policy below can be tested deterministically.
abstract class PayloadCompressor {
  Uint8List compress(Uint8List input);
  Uint8List decompress(Uint8List input);
}

/// Backend that does nothing. Used where compression is not wired up yet.
class NoopCompressor implements PayloadCompressor {
  const NoopCompressor();

  @override
  Uint8List compress(Uint8List input) => input;

  @override
  Uint8List decompress(Uint8List input) => input;
}

/// Result of applying the compression policy to a payload.
typedef CompressionResult = ({Uint8List payload, bool compressed});

/// Decides whether a given payload should travel compressed.
///
/// The rule is deliberately conservative: compress only when the payload is
/// large enough to matter, is not already a compressed format, and the attempt
/// actually produced something smaller.
class CompressionPolicy {
  const CompressionPolicy({
    required this.compressor,
    this.threshold = compressionThreshold,
  });

  final PayloadCompressor compressor;
  final int threshold;

  CompressionResult apply(
    Uint8List payload, {
    FrameType type = FrameType.message,
  }) {
    if (payload.length <= threshold || incompressibleTypes.contains(type)) {
      return (payload: payload, compressed: false);
    }

    final Uint8List candidate;
    try {
      candidate = compressor.compress(payload);
    } on Object {
      // A compressor failure must never block a message from being sent.
      return (payload: payload, compressed: false);
    }

    if (candidate.length >= payload.length) {
      return (payload: payload, compressed: false);
    }
    return (payload: candidate, compressed: true);
  }

  /// Reverses [apply]. Throws [FrameFormatException] when the payload claims to
  /// be compressed but cannot be decoded, so the caller drops the frame.
  Uint8List restore(Uint8List payload, {required bool compressed}) {
    if (!compressed) return payload;
    try {
      return compressor.decompress(payload);
    } on Object catch (error) {
      throw FrameFormatException('cannot decompress payload: $error');
    }
  }
}
