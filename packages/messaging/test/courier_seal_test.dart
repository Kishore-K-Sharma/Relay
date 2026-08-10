import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// A message handed to a stranger, carried, and delivered.
void main() {
  final now = DateTime.utc(2026, 7, 26, 12);
  final payload = Uint8List.fromList('bring water'.codeUnits);

  Uint8List secret(int fill) => Uint8List.fromList(List.filled(32, fill));

  late Uint8List alicePrivate;
  late Uint8List bobPrivate;
  late Uint8List bobStatic;
  late Uint8List carolPrivate;
  late Uint8List carolStatic;

  setUp(() async {
    alicePrivate = secret(1);
    bobPrivate = secret(2);
    carolPrivate = secret(3);
    bobStatic = await publicKeyOf(bobPrivate);
    carolStatic = await publicKeyOf(carolPrivate);
  });

  Future<CourierEnvelope> forBob({int copies = 1}) => CourierSeal.build(
    senderNoisePrivate: alicePrivate,
    recipientNoiseStatic: bobStatic,
    payload: payload,
    now: now,
    copies: copies,
  );

  test('the recipient reads it', () async {
    final opened = await CourierSeal.open(
      recipientNoisePrivate: bobPrivate,
      envelope: await forBob(),
    );

    expect(opened!.payload, payload);
    expect(opened.senderStatic, await publicKeyOf(alicePrivate));
  });

  test('the courier carrying it cannot', () async {
    expect(
      await CourierSeal.open(
        recipientNoisePrivate: carolPrivate,
        envelope: await forBob(),
      ),
      isNull,
    );
  });

  test('it expires within the policy lifetime', () async {
    final envelope = await forBob();

    expect(
      envelope.expiresAt,
      lessThanOrEqualTo(
        now.add(CourierEnvelope.maxLifetime).millisecondsSinceEpoch,
      ),
    );
  });

  test('a caller cannot ask for longer than the policy allows', () async {
    final greedy = await CourierSeal.build(
      senderNoisePrivate: alicePrivate,
      recipientNoiseStatic: bobStatic,
      payload: payload,
      now: now,
      lifetime: const Duration(days: 30),
    );

    expect(
      greedy.expiresAt,
      now.add(CourierEnvelope.maxLifetime).millisecondsSinceEpoch,
    );
  });

  group('the recipient tag', () {
    test('is recognised by the recipient', () async {
      final envelope = await forBob();
      final tags = await CourierSeal.candidateTags(bobStatic, now: now);

      expect(tags.any((t) => _same(t, envelope.recipientTag)), isTrue);
    });

    test('means nothing to somebody else', () async {
      final envelope = await forBob();
      final tags = await CourierSeal.candidateTags(carolStatic, now: now);

      expect(tags.any((t) => _same(t, envelope.recipientTag)), isFalse);
    });

    test('changes from one day to the next', () async {
      // Two envelopes for the same person on different days must not be
      // linkable by anybody who does not already know their key.
      final today = await CourierSeal.tagFor(bobStatic, day: 20000);
      final tomorrow = await CourierSeal.tagFor(bobStatic, day: 20001);

      expect(today, isNot(tomorrow));
    });

    test('is still recognised the next morning', () async {
      // Sealed at 23:59, delivered at 00:05. Without the adjacent-day window
      // this envelope becomes silently undeliverable.
      final lastNight = DateTime.utc(2026, 7, 26, 23, 59);
      final envelope = await CourierSeal.build(
        senderNoisePrivate: alicePrivate,
        recipientNoiseStatic: bobStatic,
        payload: payload,
        now: lastNight,
      );

      final tags = await CourierSeal.candidateTags(
        bobStatic,
        now: DateTime.utc(2026, 7, 27, 0, 5),
      );

      expect(tags.any((t) => _same(t, envelope.recipientTag)), isTrue);
    });

    test('is the right length', () async {
      expect(
        (await CourierSeal.tagFor(bobStatic, day: 1)).length,
        CourierEnvelope.tagLength,
      );
    });
  });

  test('end to end: deposited, carried, sprayed and delivered', () async {
    // Alice cannot reach Bob. Carol takes the envelope, meets Dave, gives him
    // a copy, and Dave meets Bob.
    final carolStore = LocalStore.open();
    final daveStore = LocalStore.open();
    addTearDown(carolStore.close);
    addTearDown(daveStore.close);

    final carol = CourierStore(store: carolStore, clock: () => now);
    final dave = CourierStore(store: daveStore, clock: () => now);

    final envelope = await forBob(copies: 4);
    expect(
      carol.deposit(envelope, depositor: await publicKeyOf(alicePrivate)),
      isTrue,
    );

    // Carol meets Dave and hands him half the budget.
    final daveKey = secret(4);
    final copy = carol.spraysFor(daveKey, courierTags: []).single;
    expect(dave.deposit(copy, depositor: secret(9)), isTrue);
    expect(carol.sprayed(copy, courierKey: daveKey), isTrue);

    expect(copy.copies, 2);
    expect(carolStore.couriered().single.copies, 2);

    // Dave meets Bob.
    final bobTags = await CourierSeal.candidateTags(bobStatic, now: now);
    final delivered = dave.envelopesFor(bobTags).single;

    final opened = await CourierSeal.open(
      recipientNoisePrivate: bobPrivate,
      envelope: delivered,
    );
    expect(opened!.payload, payload);

    dave.delivered(delivered);
    expect(dave.count, 0);
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
