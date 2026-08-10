import 'dart:math';

import 'package:meta/meta.dart';

/// How hard this device works to make its traffic pattern say less.
///
/// Encryption hides what is said. It does not hide that something was said, to
/// roughly whom, or when — and in a crowd, "these two phones exchanged frames
/// within a second of each other, twice" is frequently the fact that matters.
/// Two cheap countermeasures help: delay each message by a random moment so it
/// does not coincide with a keystroke or with a reply, and emit an occasional
/// frame that means nothing so that silence and conversation look alike.
///
/// **What this does not do.** A determined observer watching a quiet mesh for
/// long enough still wins: dummies are never replied to, a real conversation
/// has a shape, and two people in a room with nobody else are not hidden by any
/// amount of noise. It is a cost imposed on an observer, not a guarantee — and
/// the cost is paid in battery and airtime by everyone nearby, which is why it
/// is off unless the user turns it on.
@immutable
class CoverTrafficPolicy {
  const CoverTrafficPolicy({
    this.enabled = false,
    this.minDelay = const Duration(milliseconds: 50),
    this.maxDelay = const Duration(milliseconds: 500),
    this.dummyInterval = const Duration(minutes: 2),
  });

  /// The default: nothing at all.
  const CoverTrafficPolicy.off() : this();

  final bool enabled;

  /// A real message waits a random moment inside this range before it goes.
  final Duration minDelay;
  final Duration maxDelay;

  /// Roughly how often a meaningless frame is emitted.
  final Duration dummyInterval;

  /// Roughly how many extra frames an hour this costs.
  ///
  /// Stated on the policy so that no screen can present cover traffic as a
  /// free win. Every one of these is radio time and battery, on this phone and
  /// on every phone that relays it.
  int get extraFramesPerHour =>
      enabled ? (Duration.secondsPerHour / dummyInterval.inSeconds).ceil() : 0;

  /// How long to hold a real message before sending it.
  Duration nextDelay(Random random) {
    if (!enabled) return Duration.zero;
    final spread = maxDelay.inMilliseconds - minDelay.inMilliseconds;
    return Duration(
      milliseconds:
          minDelay.inMilliseconds +
          (spread <= 0 ? 0 : random.nextInt(spread + 1)),
    );
  }

  /// When to emit the next meaningless frame, or null if never.
  ///
  /// Spread across half an interval either side of the target. Dummies
  /// arriving on a metronome are the easiest thing in the world to filter back
  /// out, which would leave the cost and remove the benefit.
  Duration? nextDummyDelay(Random random) {
    if (!enabled) return null;
    final half = dummyInterval.inMilliseconds ~/ 2;
    return Duration(
      milliseconds: half + random.nextInt(dummyInterval.inMilliseconds) + 1,
    );
  }
}
