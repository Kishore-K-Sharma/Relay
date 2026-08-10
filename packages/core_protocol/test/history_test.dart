import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// Catching up on a group you have just joined.
///
/// Everything here is decoded from bytes a stranger chose, so roughly half of
/// these tests are about refusing malformed input rather than about the happy
/// path.
void main() {
  Uint8List key(int b) => Uint8List.fromList([b, b, b, b]);

  HistoryEntry entry(int n, {String body = 'hello'}) => HistoryEntry(
    senderKey: key(n),
    sequence: n,
    sentAt: DateTime.fromMillisecondsSinceEpoch(1000 * n, isUtc: true),
    body: body,
  );

  group('HistoryRequest', () {
    test('survives a round trip', () {
      final decoded = HistoryRequest.decode(
        const HistoryRequest(since: Duration(hours: 6)).encode(),
      );

      expect(decoded!.since, const Duration(hours: 6));
    });

    test('is refused when truncated', () {
      expect(HistoryRequest.decode(Uint8List(2)), isNull);
    });

    test('caps an absurd window rather than trusting it', () {
      // A request for a thousand years is either a bug or an attempt to make
      // this device read its whole database into memory.
      final decoded = HistoryRequest.decode(
        const HistoryRequest(since: Duration(days: 400000)).encode(),
      );

      expect(decoded!.since, HistoryRequest.maxWindow);
    });
  });

  group('HistoryBundle', () {
    test('survives a round trip', () {
      final bundle = HistoryBundle(entries: [entry(1), entry(2)]);

      final decoded = HistoryBundle.decode(bundle.encode())!;

      expect(decoded.entries, hasLength(2));
      expect(decoded.entries.first.body, 'hello');
      expect(decoded.entries.first.sequence, 1);
      expect(decoded.entries.last.sentAt, entry(2).sentAt);
      expect(decoded.entries.first.senderKey, key(1));
    });

    test('carries an empty answer, which is different from no answer', () {
      // "I am in this room and I have nothing" stops the asker waiting.
      final decoded = HistoryBundle.decode(
        const HistoryBundle(entries: []).encode(),
      );

      expect(decoded!.entries, isEmpty);
    });

    test('keeps text in any script intact', () {
      final decoded = HistoryBundle.decode(
        HistoryBundle(entries: [entry(1, body: 'привет こんにちは')]).encode(),
      );

      expect(decoded!.entries.single.body, 'привет こんにちは');
    });

    test('refuses a bundle that claims more entries than it holds', () {
      final bytes = HistoryBundle(entries: [entry(1)]).encode();
      bytes[0] = 40;

      expect(HistoryBundle.decode(bytes), isNull);
    });

    test('refuses a body length that runs off the end', () {
      final bytes = HistoryBundle(entries: [entry(1)]).encode();
      // The two length bytes sit after the 4-byte key, 4-byte sequence and
      // 8-byte timestamp of the first entry.
      bytes[1 + 4 + 4 + 8] = 0xFF;
      bytes[1 + 4 + 4 + 8 + 1] = 0xFF;

      expect(HistoryBundle.decode(bytes), isNull);
    });

    test('refuses an empty input', () {
      expect(HistoryBundle.decode(Uint8List(0)), isNull);
    });

    test('refuses trailing rubbish', () {
      // A bundle that decodes and then has bytes left over is not the bundle
      // that was sent, and guessing which half to believe is not an option.
      final bytes = HistoryBundle(entries: [entry(1)]).encode();
      final padded = Uint8List(bytes.length + 3)
        ..setRange(0, bytes.length, bytes);

      expect(HistoryBundle.decode(padded), isNull);
    });
  });

  group('what is worth sharing', () {
    test('keeps only the newest entries', () {
      final many = [for (var i = 0; i < 200; i++) entry(i)];

      final trimmed = HistoryBundle.of(many);

      expect(trimmed.entries, hasLength(HistoryBundle.maxEntries));
      expect(trimmed.entries.last.sequence, 199);
    });

    test('stops at the byte ceiling even with few entries', () {
      // A handful of long messages must not produce a bundle that fragments
      // into a hundred frames and floods the room.
      final fat = [for (var i = 0; i < 40; i++) entry(i, body: 'x' * 1000)];

      final trimmed = HistoryBundle.of(fat);

      expect(
        trimmed.encode().length,
        lessThanOrEqualTo(HistoryBundle.maxBytes),
      );
      expect(trimmed.entries, isNotEmpty);
    });

    test('keeps the newest when it has to choose', () {
      final fat = [for (var i = 0; i < 40; i++) entry(i, body: 'x' * 1000)];

      expect(HistoryBundle.of(fat).entries.last.sequence, 39);
    });

    test('drops anything older than the window asked for', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      final old = HistoryEntry(
        senderKey: key(1),
        sequence: 1,
        sentAt: now.subtract(const Duration(days: 2)),
        body: 'ancient',
      );
      final fresh = HistoryEntry(
        senderKey: key(2),
        sequence: 2,
        sentAt: now.subtract(const Duration(minutes: 5)),
        body: 'recent',
      );

      final trimmed = HistoryBundle.of(
        [old, fresh],
        since: const Duration(hours: 1),
        now: now,
      );

      expect(trimmed.entries.map((e) => e.body), ['recent']);
    });

    test('a single oversized message is dropped, not truncated', () {
      // Truncating would silently corrupt what someone said. Dropping it is
      // visible in the count and honest.
      final huge = entry(1, body: 'x' * (HistoryBundle.maxBytes * 2));

      expect(HistoryBundle.of([huge]).entries, isEmpty);
    });
  });
}
