import 'dart:math';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Making traffic patterns say less.
///
/// Encryption hides what is said. It does not hide that something was said, to
/// roughly whom, or when — and in a crowd, "these two phones exchanged frames
/// within a second of each other, twice" is often the fact that matters.
///
/// What this buys is real but partial, and the tests say so where they can:
/// it costs battery and airtime, and a determined observer watching a quiet
/// mesh for long enough can still separate the two.
void main() {
  final random = Random(7);

  group('off by default', () {
    test('a disabled policy adds no delay', () {
      expect(const CoverTrafficPolicy.off().nextDelay(random), Duration.zero);
    });

    test('a disabled policy never asks for a dummy', () {
      expect(const CoverTrafficPolicy.off().nextDummyDelay(random), isNull);
    });

    test('the default is off', () {
      // It costs battery. Turning it on for everyone would drain phones to
      // protect against something most users are not facing.
      expect(const CoverTrafficPolicy().enabled, isFalse);
    });
  });

  group('send delay', () {
    const policy = CoverTrafficPolicy(
      enabled: true,
      minDelay: Duration(milliseconds: 50),
      maxDelay: Duration(milliseconds: 500),
    );

    test('stays inside the range', () {
      for (var i = 0; i < 200; i++) {
        final delay = policy.nextDelay(random);
        expect(delay, greaterThanOrEqualTo(policy.minDelay));
        expect(delay, lessThanOrEqualTo(policy.maxDelay));
      }
    });

    test('actually varies', () {
      // A constant delay is not cover, it is a constant offset — and an
      // observer subtracts it in one step.
      final seen = {for (var i = 0; i < 50; i++) policy.nextDelay(random)};

      expect(seen.length, greaterThan(5));
    });

    test('a zero-width range is allowed and produces that delay', () {
      const fixed = CoverTrafficPolicy(
        enabled: true,
        minDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 100),
      );

      expect(fixed.nextDelay(random), const Duration(milliseconds: 100));
    });
  });

  group('dummy traffic', () {
    const policy = CoverTrafficPolicy(
      enabled: true,
      dummyInterval: Duration(seconds: 60),
    );

    test('is scheduled around the interval, not exactly on it', () {
      // Dummies arriving on a metronome are the easiest thing in the world to
      // filter out.
      final seen = {for (var i = 0; i < 50; i++) policy.nextDummyDelay(random)};

      expect(seen.length, greaterThan(5));
    });

    test('never schedules a negative or zero delay', () {
      for (var i = 0; i < 200; i++) {
        expect(policy.nextDummyDelay(random)!.inMilliseconds, greaterThan(0));
      }
    });

    test('stays within half an interval of the target', () {
      for (var i = 0; i < 200; i++) {
        final delay = policy.nextDummyDelay(random)!;
        expect(delay, greaterThanOrEqualTo(const Duration(seconds: 30)));
        expect(delay, lessThanOrEqualTo(const Duration(seconds: 90)));
      }
    });
  });

  test('the cost is stated on the policy itself', () {
    // So that no UI can offer this as a free win.
    expect(
      const CoverTrafficPolicy(enabled: true).extraFramesPerHour,
      greaterThan(0),
    );
  });
}
