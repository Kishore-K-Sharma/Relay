import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length, {int seed = 0}) => Uint8List.fromList(
  List<int>.generate(length, (i) => (i * 31 + seed) & 0xFF),
);

MsgId _id(int seed) => MsgId(Uint8List.fromList(List<int>.filled(8, seed)));

Frame _logical(
  int payloadLength, {
  MsgId? id,
  FrameType type = FrameType.message,
}) => Frame(
  type: type,
  ttl: maxTtl,
  flags: const FrameFlags(encrypted: true),
  msgId: id ?? _id(1),
  srcHash: 0xAAAA0001,
  dstHash: 0xBBBB0002,
  payload: _bytes(payloadLength),
);

/// A clock the test drives by hand, so expiry is deterministic.
class FakeClock {
  Duration now = Duration.zero;
  Duration call() => now;
  void advance(Duration d) => now += d;
}

void main() {
  group('fragmentation', () {
    test(
      'leaves a payload that already fits as a single unfragmented frame',
      () {
        final frames = fragmentFrame(_logical(fragmentPayloadLength));

        expect(frames, hasLength(1));
        expect(frames.single.flags.fragmented, isFalse);
        expect(frames.single.payload, hasLength(fragmentPayloadLength));
      },
    );

    test(
      'splits an oversized payload into ceil(size / fragmentPayloadLength) frames',
      () {
        final frames = fragmentFrame(_logical(fragmentPayloadLength * 3 + 1));

        expect(frames, hasLength(4));
        for (final frame in frames) {
          expect(frame.flags.fragmented, isTrue);
          expect(frame.type, FrameType.fragment);
          expect(frame.wireLength, lessThanOrEqualTo(assumedMtu));
        }
      },
    );

    test(
      'gives every fragment the same message id so relays dedupe them independently',
      () {
        final frames = fragmentFrame(
          _logical(fragmentPayloadLength * 3, id: _id(7)),
        );

        expect(frames.map((f) => f.msgId).toSet(), {_id(7)});
      },
    );

    test('numbers fragments from zero and records the total on each', () {
      final frames = fragmentFrame(_logical(fragmentPayloadLength * 3));

      for (var i = 0; i < frames.length; i++) {
        expect(FragmentHeader.parse(frames[i].payload).index, i);
        expect(FragmentHeader.parse(frames[i].payload).total, 3);
      }
    });

    test('preserves the original frame type inside the fragment header', () {
      final frames = fragmentFrame(
        _logical(fragmentPayloadLength * 2, type: FrameType.voice),
      );

      expect(
        FragmentHeader.parse(frames.first.payload).originalType,
        FrameType.voice,
      );
    });

    test(
      'refuses a payload too large to address with a 16-bit fragment count',
      () {
        final tooBig = _logical(0xFFFF * fragmentPayloadLength + 1);

        expect(
          () => fragmentFrame(tooBig),
          throwsA(isA<FrameFormatException>()),
        );
      },
    );
  });

  group('reassembly', () {
    late FakeClock clock;
    late Reassembler reassembler;

    setUp(() {
      clock = FakeClock();
      reassembler = Reassembler(clock: clock.call);
    });

    test('returns the original payload once the last fragment arrives', () {
      final original = _logical(fragmentPayloadLength * 3 + 17);
      final frames = fragmentFrame(original);

      Uint8List? completed;
      for (final frame in frames) {
        completed = reassembler.offer(frame)?.payload;
      }

      expect(completed, original.payload);
    });

    test('returns null until the message is complete', () {
      final frames = fragmentFrame(_logical(fragmentPayloadLength * 3));

      expect(reassembler.offer(frames[0]), isNull);
      expect(reassembler.offer(frames[1]), isNull);
      expect(reassembler.offer(frames[2]), isNotNull);
    });

    test('reassembles fragments delivered out of order', () {
      final original = _logical(fragmentPayloadLength * 4 + 5);
      final frames = fragmentFrame(original)..shuffle();

      ReassembledMessage? completed;
      for (final frame in frames) {
        completed = reassembler.offer(frame) ?? completed;
      }

      expect(completed?.payload, original.payload);
    });

    test('restores the original frame type and addressing', () {
      final original = _logical(
        fragmentPayloadLength * 2,
        type: FrameType.voice,
      );

      ReassembledMessage? completed;
      for (final frame in fragmentFrame(original)) {
        completed = reassembler.offer(frame) ?? completed;
      }

      expect(completed!.type, FrameType.voice);
      expect(completed.msgId, original.msgId);
      expect(completed.srcHash, original.srcHash);
      expect(completed.dstHash, original.dstHash);
    });

    test('ignores a duplicate fragment without corrupting the payload', () {
      final original = _logical(fragmentPayloadLength * 3);
      final frames = fragmentFrame(original);

      reassembler.offer(frames[0]);
      reassembler.offer(frames[0]);
      reassembler.offer(frames[1]);
      final completed = reassembler.offer(frames[2]);

      expect(completed?.payload, original.payload);
    });

    test('passes a single unfragmented frame straight through', () {
      final frame = _logical(40);

      expect(
        reassembler.offer(fragmentFrame(frame).single)?.payload,
        frame.payload,
      );
    });

    test('drops a partial message once it exceeds the expiry window', () {
      final frames = fragmentFrame(_logical(fragmentPayloadLength * 3));
      reassembler.offer(frames[0]);

      clock.advance(reassemblyExpiry + const Duration(seconds: 1));

      expect(reassembler.offer(frames[1]), isNull);
      expect(
        reassembler.offer(frames[2]),
        isNull,
        reason:
            'the expired first fragment must not silently complete the message',
      );
      expect(reassembler.expiredCount, 1);
    });

    test(
      'evicts the oldest partial when the concurrent message limit is reached',
      () {
        final small = Reassembler(clock: clock.call, maxPartialMessages: 2);
        final a = fragmentFrame(
          _logical(fragmentPayloadLength * 2, id: _id(1)),
        );
        final b = fragmentFrame(
          _logical(fragmentPayloadLength * 2, id: _id(2)),
        );
        final c = fragmentFrame(
          _logical(fragmentPayloadLength * 2, id: _id(3)),
        );

        small.offer(a[0]);
        clock.advance(const Duration(seconds: 1));
        small.offer(b[0]);
        clock.advance(const Duration(seconds: 1));
        small.offer(c[0]);

        expect(small.partialCount, 2);
        expect(small.evictedCount, 1);
        expect(
          small.offer(b[1]),
          isNotNull,
          reason: 'b was not the oldest and must survive',
        );
        expect(
          small.offer(a[1]),
          isNull,
          reason: 'a was the oldest and must have been evicted',
        );
      },
    );

    test('evicts partials when the total buffered byte budget is exceeded', () {
      final tiny = Reassembler(
        clock: clock.call,
        maxBufferedBytes: fragmentPayloadLength * 3,
      );
      final a = fragmentFrame(_logical(fragmentPayloadLength * 4, id: _id(1)));
      final b = fragmentFrame(_logical(fragmentPayloadLength * 4, id: _id(2)));

      tiny.offer(a[0]);
      tiny.offer(a[1]);
      clock.advance(const Duration(seconds: 1));
      tiny.offer(b[0]);
      tiny.offer(b[1]);

      expect(tiny.bufferedBytes, lessThanOrEqualTo(fragmentPayloadLength * 3));
      expect(tiny.evictedCount, greaterThan(0));
    });

    test(
      'rejects a fragment whose total disagrees with the partial already held',
      () {
        final frames = fragmentFrame(_logical(fragmentPayloadLength * 3));
        reassembler.offer(frames[0]);

        final lying = frames[1].copyWith(
          payload: const FragmentHeader(
            index: 1,
            total: 99,
            originalType: FrameType.message,
          ).prepend(_bytes(fragmentPayloadLength)),
        );

        expect(reassembler.offer(lying), isNull);
        expect(reassembler.rejectedCount, 1);
      },
    );

    test('rejects a fragment whose index is outside the declared total', () {
      final bad = _logical(1).copyWith(
        flags: const FrameFlags(encrypted: true, fragmented: true),
        payload: const FragmentHeader(
          index: 5,
          total: 3,
          originalType: FrameType.message,
        ).prepend(_bytes(10)),
      );

      expect(reassembler.offer(bad), isNull);
      expect(reassembler.rejectedCount, 1);
    });

    test('rejects a fragmented frame too short to hold a fragment header', () {
      final truncated = _logical(1).copyWith(
        flags: const FrameFlags(fragmented: true),
        payload: Uint8List(2),
      );

      expect(reassembler.offer(truncated), isNull);
      expect(reassembler.rejectedCount, 1);
    });

    test('rejects a fragment declaring a total of zero', () {
      final bad = _logical(1).copyWith(
        flags: const FrameFlags(fragmented: true),
        payload: const FragmentHeader(
          index: 0,
          total: 0,
          originalType: FrameType.message,
        ).prepend(_bytes(10)),
      );

      expect(reassembler.offer(bad), isNull);
      expect(reassembler.rejectedCount, 1);
    });
  });
}
