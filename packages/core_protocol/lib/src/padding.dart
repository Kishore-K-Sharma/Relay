import 'dart:math';
import 'dart:typed_data';

import 'frame.dart';

/// Rounds payloads up to a small set of sizes, so the length of a frame stops
/// describing the message inside it.
///
/// Encryption hides what was said. It does not hide how much was said, and on
/// a radio anyone can measure that: a one-word reply and a paragraph are
/// visibly different, the long message everyone forwards is easy to follow
/// across the mesh, and a conversation has a rhythm of sizes that identifies
/// it. Padding costs airtime — a fifteen-byte "on my way" becomes a block — so
/// it is a policy the caller chooses rather than something baked into the
/// codec.
///
/// The block is `uint32 length | payload | random filler`. The length prefix
/// travels *inside* the encryption, so the filler is indistinguishable from
/// the message to anyone who cannot already read it.
class PaddingPolicy {
  const PaddingPolicy({this.enabled = true, this.random});

  /// Leaves payloads exactly as they are.
  static const disabled = PaddingPolicy(enabled: false);

  /// Sizes a padded block may take. Powers of two from 64: coarse enough that
  /// most messages land on the first two, fine enough that a long one is not
  /// rounded up to something absurd.
  static const List<int> buckets = [64, 128, 256, 512, 1024, 2048, 4096];

  /// Above the largest bucket, padding steps in fixed blocks instead of
  /// doubling. Doubling would round a 5 KiB voice note up to 8 KiB.
  static const int blockAbove = 1024;

  static const int _lengthPrefix = 4;

  final bool enabled;

  /// Injectable for tests. `Random.secure()` otherwise: the filler should not
  /// be predictable, since a predictable pattern is a way to recognise padded
  /// blocks without decrypting them.
  final Random? random;

  /// The block size a payload of [length] bytes will occupy.
  int paddedLength(int length) {
    final needed = length + _lengthPrefix;
    for (final bucket in buckets) {
      if (needed <= bucket) return bucket;
    }
    final over = needed - buckets.last;
    return buckets.last + ((over + blockAbove - 1) ~/ blockAbove) * blockAbove;
  }

  Uint8List pad(Uint8List payload) {
    if (!enabled) return payload;

    final size = paddedLength(payload.length);
    final out = Uint8List(size);
    ByteData.view(out.buffer).setUint32(0, payload.length, Endian.big);
    out.setRange(_lengthPrefix, _lengthPrefix + payload.length, payload);

    final rng = random ?? Random.secure();
    for (var i = _lengthPrefix + payload.length; i < size; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  /// Recovers the payload from a padded block.
  ///
  /// Throws [FrameFormatException] on anything that does not describe itself
  /// consistently. That only happens with a corrupt or hostile peer, and the
  /// caller drops the frame.
  Uint8List strip(Uint8List block) {
    if (!enabled) return block;

    if (block.length < _lengthPrefix) {
      throw const FrameFormatException(
        'padded block is too short to hold a '
        'length',
      );
    }
    final length = ByteData.view(
      block.buffer,
      block.offsetInBytes,
      block.length,
    ).getUint32(0, Endian.big);

    if (_lengthPrefix + length > block.length) {
      throw FrameFormatException(
        'padded block declares $length bytes but holds '
        '${block.length - _lengthPrefix}',
      );
    }
    return Uint8List.sublistView(block, _lengthPrefix, _lengthPrefix + length);
  }
}
