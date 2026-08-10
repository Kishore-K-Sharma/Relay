import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Envelopes handed to strangers to carry.
///
/// Every byte here was chosen by somebody with no relationship to this device,
/// so most of these tests are about refusing input rather than accepting it.
void main() {
  Uint8List tag([int fill = 7]) =>
      Uint8List.fromList(List.filled(CourierEnvelope.tagLength, fill));

  Uint8List cipher([int length = 40]) =>
      Uint8List.fromList(List.generate(length, (i) => i % 256));

  CourierEnvelope envelope({int copies = 1, int? expiresAt}) => CourierEnvelope(
    recipientTag: tag(),
    expiresAt: expiresAt ?? 1800000000000,
    ciphertext: cipher(),
    copies: copies,
  );

  group('encoding', () {
    test('survives a round trip', () {
      final decoded = CourierEnvelope.decode(envelope().encode()!)!;

      expect(decoded.recipientTag, tag());
      expect(decoded.expiresAt, 1800000000000);
      expect(decoded.ciphertext, cipher());
      expect(decoded.copies, 1);
    });

    test('carries a spray budget', () {
      expect(CourierEnvelope.decode(envelope(copies: 6).encode()!)!.copies, 6);
    });

    test('a carry-only envelope spends no bytes saying so', () {
      // The common case. One is the default on decode, so writing it would be
      // three wasted bytes on every envelope in the network.
      expect(
        envelope().encode()!.length,
        lessThan(envelope(copies: 2).encode()!.length),
      );
    });

    test('an unknown field is carried, not rejected', () {
      // The entire job of a courier is to carry what it does not understand.
      // A build that refused a newer envelope would stop being useful the
      // first time the format grew.
      final original = envelope().encode()!;
      final extended = Uint8List(original.length + 5)
        ..setRange(0, original.length, original)
        ..[original.length] = 0x7E
        ..[original.length + 1] = 0x00
        ..[original.length + 2] = 0x02
        ..[original.length + 3] = 0xAB
        ..[original.length + 4] = 0xCD;

      expect(CourierEnvelope.decode(extended)!.ciphertext, cipher());
    });

    test('refuses a tag of the wrong length', () {
      final bad = CourierEnvelope(
        recipientTag: Uint8List(4),
        expiresAt: 1,
        ciphertext: cipher(),
      );

      expect(bad.encode(), isNull);
    });

    test('refuses an empty or oversized ciphertext', () {
      expect(
        CourierEnvelope(
          recipientTag: tag(),
          expiresAt: 1,
          ciphertext: Uint8List(0),
        ).encode(),
        isNull,
      );
      expect(
        CourierEnvelope(
          recipientTag: tag(),
          expiresAt: 1,
          ciphertext: cipher(CourierEnvelope.maxCiphertextBytes + 1),
        ).encode(),
        isNull,
      );
    });

    test('refuses a length that runs off the end', () {
      final bytes = envelope().encode()!;
      bytes[1] = 0xFF;

      expect(CourierEnvelope.decode(bytes), isNull);
    });

    test('refuses a truncated header', () {
      expect(CourierEnvelope.decode(Uint8List.fromList([0x01, 0x00])), isNull);
    });

    test('refuses an envelope missing a required field', () {
      expect(CourierEnvelope.decode(Uint8List(0)), isNull);
      // Tag only.
      final tagOnly = Uint8List.fromList([
        0x01,
        0x00,
        CourierEnvelope.tagLength,
        ...tag(),
      ]);
      expect(CourierEnvelope.decode(tagOnly), isNull);
    });
  });

  group('the copy budget', () {
    test('is clamped so an envelope cannot become an amplifier', () {
      // Without the ceiling, one deposited envelope floods every phone in a
      // city. The depositor does not get to choose how much of the network
      // they consume.
      expect(envelope(copies: 200).copies, CourierEnvelope.maxCopies);
    });

    test('is never below one', () {
      expect(envelope(copies: 0).copies, 1);
      expect(envelope(copies: -5).copies, 1);
    });

    test('is clamped on decode too, not only on construction', () {
      // A hostile depositor writes the bytes directly.
      final bytes = envelope(copies: 8).encode()!;
      bytes[bytes.length - 1] = 250;

      expect(CourierEnvelope.decode(bytes)!.copies, CourierEnvelope.maxCopies);
    });

    test('splitting halves it', () {
      expect(envelope(copies: 8).withCopies(4).copies, 4);
    });
  });

  group('expiry', () {
    test('knows when it is past', () {
      final at = DateTime.utc(2026, 7, 26, 12);
      final live = envelope(
        expiresAt: at.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      final dead = envelope(
        expiresAt: at.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );

      expect(live.isExpiredAt(at), isFalse);
      expect(dead.isExpiredAt(at), isTrue);
    });

    test('the moment of expiry counts as expired', () {
      final at = DateTime.utc(2026, 7, 26, 12);

      expect(
        envelope(expiresAt: at.millisecondsSinceEpoch).isExpiredAt(at),
        isTrue,
      );
    });
  });

  group('rotating tags', () {
    test('the day changes at midnight UTC', () {
      expect(
        CourierEnvelope.epochDay(DateTime.utc(2026, 7, 26, 23, 59)),
        CourierEnvelope.epochDay(DateTime.utc(2026, 7, 26, 0, 1)),
      );
      expect(
        CourierEnvelope.epochDay(DateTime.utc(2026, 7, 27)),
        CourierEnvelope.epochDay(DateTime.utc(2026, 7, 26)) + 1,
      );
    });

    test('the tag input differs every day', () {
      // This is what stops two envelopes for the same person, sent on
      // different days, being linked by anybody watching.
      final days = {
        for (var day = 100; day < 110; day++)
          String.fromCharCodes(CourierEnvelope.tagInput(day)),
      };

      expect(days, hasLength(10));
    });

    test('the tag input is stable for one day', () {
      expect(CourierEnvelope.tagInput(500), CourierEnvelope.tagInput(500));
    });

    test('the input is domain-separated', () {
      // So a tag can never be confused with, or replayed as, any other HMAC
      // this app computes over the same key.
      expect(
        String.fromCharCodes(CourierEnvelope.tagInput(1)),
        startsWith('relay-courier-tag-v1'),
      );
    });

    test('yesterday and tomorrow are both accepted', () {
      // An envelope sealed just before midnight, or on a phone whose clock is
      // an hour out, must still be recognised while it is being carried.
      final now = DateTime.utc(2026, 7, 26, 12);
      final days = CourierEnvelope.candidateDays(now);

      expect(days, hasLength(3));
      expect(days, contains(CourierEnvelope.epochDay(now)));
      expect(days, contains(CourierEnvelope.epochDay(now) - 1));
      expect(days, contains(CourierEnvelope.epochDay(now) + 1));
    });

    test('does not produce a negative day at the epoch', () {
      expect(
        CourierEnvelope.candidateDays(
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
        everyElement(greaterThanOrEqualTo(0)),
      );
    });
  });
}
