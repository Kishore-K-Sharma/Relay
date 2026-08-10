import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// Carrying other people's mail.
///
/// Almost every test here is about refusing something. An unbounded courier
/// store is a free disk-filling attack on every phone in range, and an
/// unbounded copy budget turns one envelope into a broadcast storm — both
/// reachable by anybody standing nearby with a modified client.
void main() {
  late LocalStore store;
  late CourierStore couriers;
  var now = DateTime.utc(2026, 7, 26, 12);

  setUp(() {
    store = LocalStore.open();
    couriers = CourierStore(store: store, clock: () => now);
  });

  tearDown(() => store.close());

  Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));
  Uint8List tag(int fill) =>
      Uint8List.fromList(List.filled(CourierEnvelope.tagLength, fill));

  var nextCipher = 0;
  CourierEnvelope envelope({
    int? tagFill,
    int copies = 1,
    DateTime? expiresAt,
    Uint8List? ciphertext,
  }) {
    nextCipher++;
    return CourierEnvelope(
      recipientTag: tag(tagFill ?? 9),
      expiresAt: (expiresAt ?? now.add(const Duration(hours: 6)))
          .millisecondsSinceEpoch,
      ciphertext:
          ciphertext ??
          Uint8List.fromList([nextCipher, nextCipher >> 8, 3, 4, 5]),
      copies: copies,
    );
  }

  group('accepting mail', () {
    test('takes an envelope and remembers it', () {
      expect(couriers.deposit(envelope(), depositor: key(1)), isTrue);
      expect(couriers.count, 1);
    });

    test('refuses one that has already expired', () {
      final stale = envelope(
        expiresAt: now.subtract(const Duration(minutes: 1)),
      );

      expect(couriers.deposit(stale, depositor: key(1)), isFalse);
      expect(couriers.count, 0);
    });

    test('refuses a deadline further out than the policy lifetime', () {
      // Otherwise a depositor pins this device's storage for a week by
      // claiming a week-long expiry.
      final greedy = envelope(expiresAt: now.add(const Duration(days: 7)));

      expect(couriers.deposit(greedy, depositor: key(1)), isFalse);
    });

    test('allows an hour of slack for a wrong clock', () {
      final slightly = envelope(
        expiresAt: now.add(const Duration(hours: 24, minutes: 30)),
      );

      expect(couriers.deposit(slightly, depositor: key(1)), isTrue);
    });

    test('refuses an empty ciphertext', () {
      final empty = CourierEnvelope(
        recipientTag: tag(9),
        expiresAt: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        ciphertext: Uint8List(0),
      );

      expect(couriers.deposit(empty, depositor: key(1)), isFalse);
    });

    test('the same envelope twice is not two envelopes', () {
      final same = Uint8List.fromList([1, 2, 3]);
      couriers.deposit(envelope(ciphertext: same), depositor: key(1));
      couriers.deposit(envelope(ciphertext: same), depositor: key(2));

      expect(couriers.count, 1);
    });
  });

  group('quotas', () {
    test('one favourite cannot deposit more than their share', () {
      for (var i = 0; i < CourierStore.maxPerFavourite; i++) {
        expect(couriers.deposit(envelope(), depositor: key(1)), isTrue);
      }

      expect(couriers.deposit(envelope(), depositor: key(1)), isFalse);
    });

    test('a merely-verified depositor gets a smaller share', () {
      for (var i = 0; i < CourierStore.maxPerVerified; i++) {
        expect(
          couriers.deposit(
            envelope(),
            depositor: key(2),
            tier: CourierTier.verified,
          ),
          isTrue,
        );
      }

      expect(
        couriers.deposit(
          envelope(),
          depositor: key(2),
          tier: CourierTier.verified,
        ),
        isFalse,
      );
    });

    test('the quota is per depositor, not global', () {
      for (var i = 0; i < CourierStore.maxPerFavourite; i++) {
        couriers.deposit(envelope(), depositor: key(1));
      }

      expect(couriers.deposit(envelope(), depositor: key(2)), isTrue);
    });

    test('verified mail cannot fill the whole store', () {
      // Generosity to people the user merely met must never lock out mail
      // from the people they actually chose.
      for (var i = 0; i < CourierStore.maxVerifiedEnvelopes; i++) {
        couriers.deposit(
          envelope(),
          depositor: key(100 + i),
          tier: CourierTier.verified,
        );
      }

      expect(
        couriers.deposit(
          envelope(),
          depositor: key(200),
          tier: CourierTier.verified,
        ),
        isFalse,
      );
      expect(couriers.deposit(envelope(), depositor: key(201)), isTrue);
    });

    test('a full store evicts verified mail before a favourite\'s', () {
      couriers.deposit(
        envelope(ciphertext: Uint8List.fromList([9, 9, 9])),
        depositor: key(50),
        tier: CourierTier.verified,
      );
      for (var i = 0; i < CourierStore.maxEnvelopes - 1; i++) {
        couriers.deposit(envelope(), depositor: key(i));
      }

      expect(couriers.count, CourierStore.maxEnvelopes);
      expect(couriers.deposit(envelope(), depositor: key(300)), isTrue);
      expect(
        store.couriered().any(
          (e) => e.ciphertext.length == 3 && e.ciphertext[0] == 9,
        ),
        isFalse,
        reason: 'the verified envelope was the one shed',
      );
    });

    test('a verified deposit never displaces a favourite', () {
      for (var i = 0; i < CourierStore.maxEnvelopes; i++) {
        couriers.deposit(envelope(), depositor: key(i));
      }

      expect(
        couriers.deposit(
          envelope(),
          depositor: key(999),
          tier: CourierTier.verified,
        ),
        isFalse,
      );
      expect(couriers.count, CourierStore.maxEnvelopes);
    });
  });

  group('expiry', () {
    test('sweeps anything past its deadline', () {
      couriers.deposit(
        envelope(expiresAt: now.add(const Duration(hours: 1))),
        depositor: key(1),
      );

      now = now.add(const Duration(hours: 2));

      expect(couriers.pruneExpired(), 1);
      expect(couriers.count, 0);
    });

    test('expired mail is never handed over', () {
      couriers.deposit(
        envelope(expiresAt: now.add(const Duration(hours: 1))),
        depositor: key(1),
      );
      now = now.add(const Duration(hours: 2));

      expect(couriers.envelopesFor([tag(9)]), isEmpty);
    });
  });

  group('delivery', () {
    test('finds mail addressed to a recipient', () {
      couriers.deposit(envelope(tagFill: 3), depositor: key(1));
      couriers.deposit(envelope(tagFill: 4), depositor: key(1));

      expect(couriers.envelopesFor([tag(3)]), hasLength(1));
    });

    test('matches any of the candidate days', () {
      // An envelope sealed just before midnight is tagged for yesterday.
      couriers.deposit(envelope(tagFill: 5), depositor: key(1));

      expect(couriers.envelopesFor([tag(4), tag(5), tag(6)]), hasLength(1));
    });

    test('finds nothing for somebody with no mail', () {
      couriers.deposit(envelope(tagFill: 3), depositor: key(1));

      expect(couriers.envelopesFor([tag(88)]), isEmpty);
    });

    test('is forgotten only once it has actually arrived', () {
      // Deleting on the attempt rather than the acceptance would drop mail on
      // a dropped connection — which is exactly when carrying it mattered.
      couriers.deposit(envelope(tagFill: 3), depositor: key(1));
      final carried = couriers.envelopesFor([tag(3)]).single;

      expect(couriers.count, 1, reason: 'still held after being offered');

      couriers.delivered(carried);

      expect(couriers.count, 0);
    });
  });

  group('spray and wait', () {
    test('offers half the budget to another courier', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));

      expect(couriers.spraysFor(key(2), courierTags: []).single.copies, 4);
    });

    test('keeps the other half here', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));
      final copy = couriers.spraysFor(key(2), courierTags: []).single;

      couriers.sprayed(copy, courierKey: key(2));

      expect(store.couriered().single.copies, 4);
    });

    test('the budget only ever shrinks, so it terminates', () {
      // The property that stops one envelope becoming a broadcast storm.
      couriers.deposit(envelope(copies: 8), depositor: key(1));

      var courier = 2;
      while (couriers.spraysFor(key(courier), courierTags: []).isNotEmpty) {
        final copy = couriers.spraysFor(key(courier), courierTags: []).single;
        couriers.sprayed(copy, courierKey: key(courier));
        courier++;
        expect(courier, lessThan(20), reason: 'must converge');
      }

      expect(store.couriered().single.copies, 1);
    });

    test('a carry-only envelope is never sprayed', () {
      couriers.deposit(envelope(), depositor: key(1));

      expect(couriers.spraysFor(key(2), courierTags: []), isEmpty);
    });

    test('the same courier is not sprayed twice', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));
      final copy = couriers.spraysFor(key(2), courierTags: []).single;
      couriers.sprayed(copy, courierKey: key(2));

      expect(couriers.spraysFor(key(2), courierTags: []), isEmpty);
    });

    test('mail is never sprayed back at the person who deposited it', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));

      expect(couriers.spraysFor(key(1), courierTags: []), isEmpty);
    });

    test('mail addressed to the courier is delivered, not sprayed', () {
      // Otherwise the recipient gets a copy to carry rather than a message to
      // read, which is absurd and also loses it.
      couriers.deposit(envelope(tagFill: 3, copies: 8), depositor: key(1));

      expect(couriers.spraysFor(key(2), courierTags: [tag(3)]), isEmpty);
    });

    test('nothing is spent until the other courier takes it', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));

      couriers.spraysFor(key(2), courierTags: []);

      expect(
        store.couriered().single.copies,
        8,
        reason: 'a mesh is mostly failed connections',
      );
    });

    test('a replayed deposit cannot refill a spent budget', () {
      // The attack this defends: hand an envelope to a courier, wait for it to
      // spray, then hand the original packet back to top it up again. Left
      // open, one envelope sprays forever.
      final same = Uint8List.fromList([7, 7, 7]);
      couriers.deposit(
        envelope(ciphertext: same, copies: 8),
        depositor: key(1),
      );
      final copy = couriers.spraysFor(key(2), courierTags: []).single;
      couriers.sprayed(copy, courierKey: key(2));

      couriers.deposit(
        envelope(ciphertext: same, copies: 8),
        depositor: key(1),
      );

      expect(store.couriered().single.copies, 4);
    });

    test('a bigger budget still wins before anything has been sprayed', () {
      // A carry-only copy can legitimately arrive ahead of the original.
      final same = Uint8List.fromList([8, 8, 8]);
      couriers.deposit(envelope(ciphertext: same), depositor: key(1));
      couriers.deposit(
        envelope(ciphertext: same, copies: 8),
        depositor: key(1),
      );

      expect(store.couriered().single.copies, 8);
    });

    test('committing a stale copy is refused', () {
      couriers.deposit(envelope(copies: 8), depositor: key(1));
      final first = couriers.spraysFor(key(2), courierTags: []).single;
      final second = couriers.spraysFor(key(3), courierTags: []).single;
      couriers.sprayed(first, courierKey: key(2));

      // The second handover was computed against the old budget; committing it
      // unchanged would spend copies twice.
      expect(couriers.sprayed(second, courierKey: key(3)), isFalse);
    });
  });

  test('a panic wipe destroys other people\'s mail too', () {
    couriers.deposit(envelope(), depositor: key(1));

    store.wipe();

    expect(couriers.count, 0);
  });
}
