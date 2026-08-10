import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

MsgId _id(int seed) => MsgId(Uint8List.fromList(List<int>.filled(8, seed)));

class FakeClock {
  Duration now = Duration.zero;
  Duration call() => now;
  void advance(Duration d) => now += d;
}

/// Deterministic stand-in for the jitter source.
class FixedJitter {
  FixedJitter(this.value);
  final Duration value;
  Duration call(Duration min, Duration max) => value;
}

const int myHash = 0x0000AAAA;
const int peerHash = 0x0000BBBB;

Frame _frame({
  int ttl = 5,
  int src = peerHash,
  int dst = myHash,
  MsgId? id,
  FrameType type = FrameType.message,
}) => Frame(
  type: type,
  ttl: ttl,
  flags: const FrameFlags(encrypted: true),
  msgId: id ?? _id(1),
  srcHash: src,
  dstHash: dst,
  payload: Uint8List.fromList([1, 2, 3]),
);

void main() {
  group('DedupSet', () {
    late FakeClock clock;
    late DedupSet seen;

    setUp(() {
      clock = FakeClock();
      seen = DedupSet(clock: clock.call);
    });

    test('reports a message as new the first time and seen afterwards', () {
      expect(seen.addIfNew(FrameKey.whole(_id(1))), isTrue);
      expect(seen.addIfNew(FrameKey.whole(_id(1))), isFalse);
      expect(seen.contains(FrameKey.whole(_id(1))), isTrue);
      expect(seen.contains(FrameKey.whole(_id(2))), isFalse);
    });

    test('forgets an entry once the expiry window passes', () {
      seen.addIfNew(FrameKey.whole(_id(1)));

      clock.advance(dedupExpiry + const Duration(seconds: 1));

      expect(seen.contains(FrameKey.whole(_id(1))), isFalse);
      expect(
        seen.addIfNew(FrameKey.whole(_id(1))),
        isTrue,
        reason: 'an expired id must be treated as new',
      );
    });

    test('keeps an entry that is still inside the expiry window', () {
      seen.addIfNew(FrameKey.whole(_id(1)));

      clock.advance(dedupExpiry - const Duration(seconds: 1));

      expect(seen.contains(FrameKey.whole(_id(1))), isTrue);
    });

    test('evicts the oldest entry when the capacity limit is reached', () {
      final small = DedupSet(clock: clock.call, maxEntries: 3);

      for (var i = 1; i <= 4; i++) {
        small.addIfNew(FrameKey.whole(_id(i)));
        clock.advance(const Duration(milliseconds: 1));
      }

      expect(small.length, 3);
      expect(
        small.contains(FrameKey.whole(_id(1))),
        isFalse,
        reason: 'oldest evicted',
      );
      expect(small.contains(FrameKey.whole(_id(4))), isTrue);
    });

    test('re-adding a known id does not refresh its position', () {
      final small = DedupSet(clock: clock.call, maxEntries: 2);
      small.addIfNew(FrameKey.whole(_id(1)));
      small.addIfNew(FrameKey.whole(_id(2)));

      small.addIfNew(FrameKey.whole(_id(1)));
      small.addIfNew(FrameKey.whole(_id(3)));

      expect(
        small.contains(FrameKey.whole(_id(1))),
        isFalse,
        reason:
            'a duplicate must not extend an entry lifetime, or a flood '
            'of repeats would pin the table',
      );
    });
  });

  group('RelayEngine decisions', () {
    late FakeClock clock;
    late RelayEngine engine;

    setUp(() {
      clock = FakeClock();
      engine = RelayEngine(
        localHash: myHash,
        clock: clock.call,
        jitter: FixedJitter(const Duration(milliseconds: 50)).call,
      );
    });

    test('delivers a frame addressed to this device and does not relay it', () {
      final decision = engine.receive(_frame(dst: myHash), fromPeer: 'p1');

      expect(decision.deliverLocally, isTrue);
      expect(decision.relayFrame, isNull);
      expect(decision.drop, isNull);
    });

    test('delivers and relays a broadcast frame', () {
      final decision = engine.receive(
        _frame(dst: broadcastHash),
        fromPeer: 'p1',
      );

      expect(decision.deliverLocally, isTrue);
      expect(decision.relayFrame, isNotNull);
    });

    test('relays a frame for someone else without delivering it locally', () {
      final decision = engine.receive(_frame(dst: 0x0000CCCC), fromPeer: 'p1');

      expect(decision.deliverLocally, isFalse);
      expect(decision.relayFrame, isNotNull);
    });

    test('decrements the hop counter on the relayed copy', () {
      final decision = engine.receive(
        _frame(ttl: 5, dst: 0x0000CCCC),
        fromPeer: 'p1',
      );

      expect(decision.relayFrame!.ttl, 4);
    });

    test('never sends a relayed frame back to the peer it came from', () {
      final decision = engine.receive(_frame(dst: 0x0000CCCC), fromPeer: 'p1');

      expect(decision.excludePeer, 'p1');
    });

    test('stops relaying once the hop counter reaches zero', () {
      final decision = engine.receive(
        _frame(ttl: 0, dst: 0x0000CCCC),
        fromPeer: 'p1',
      );

      expect(decision.relayFrame, isNull);
      expect(decision.drop, RelayDrop.hopLimitReached);
    });

    test(
      'still delivers a frame for this device that arrived with no hops left',
      () {
        final decision = engine.receive(
          _frame(ttl: 0, dst: myHash),
          fromPeer: 'p1',
        );

        expect(decision.deliverLocally, isTrue);
        expect(decision.relayFrame, isNull);
      },
    );

    test('drops a frame it has already seen', () {
      engine.receive(_frame(id: _id(9), dst: 0x0000CCCC), fromPeer: 'p1');

      final second = engine.receive(
        _frame(id: _id(9), dst: 0x0000CCCC),
        fromPeer: 'p2',
      );

      expect(second.drop, RelayDrop.duplicate);
      expect(second.deliverLocally, isFalse);
      expect(second.relayFrame, isNull);
    });

    test('drops an echo of a frame this device originated', () {
      final decision = engine.receive(
        _frame(src: myHash, dst: 0x0000CCCC),
        fromPeer: 'p1',
      );

      expect(decision.drop, RelayDrop.ownFrame);
      expect(decision.relayFrame, isNull);
    });

    test('applies jitter before relaying so dense clusters do not collide', () {
      final decision = engine.receive(_frame(dst: 0x0000CCCC), fromPeer: 'p1');

      expect(decision.jitter, const Duration(milliseconds: 50));
    });

    test('draws jitter from the configured window', () {
      final windows = <Duration>[];
      final probing = RelayEngine(
        localHash: myHash,
        clock: clock.call,
        jitter: (min, max) {
          windows.add(min);
          windows.add(max);
          return min;
        },
      );

      probing.receive(_frame(dst: 0x0000CCCC), fromPeer: 'p1');

      expect(windows, [relayJitterMin, relayJitterMax]);
    });
  });

  group('RelayEngine and fragments', () {
    late FakeClock clock;
    late RelayEngine engine;

    setUp(() {
      clock = FakeClock();
      engine = RelayEngine(
        localHash: myHash,
        clock: clock.call,
        jitter: FixedJitter(const Duration(milliseconds: 50)).call,
      );
    });

    test(
      'relays every fragment of a message even though they share one id',
      () {
        final big = Frame(
          type: FrameType.message,
          ttl: 5,
          flags: const FrameFlags(encrypted: true),
          msgId: _id(42),
          srcHash: peerHash,
          dstHash: 0x0000CCCC,
          payload: Uint8List(fragmentPayloadLength * 3),
        );
        final fragments = fragmentFrame(big);
        expect(fragments, hasLength(3));

        final decisions = fragments
            .map((f) => engine.receive(f, fromPeer: 'p1'))
            .toList(growable: false);

        expect(
          decisions.map((d) => d.relayFrame != null),
          everyElement(isTrue),
          reason:
              'fragments share a msgId by design, so deduplication must key '
              'on the fragment as well or only the first one ever propagates',
        );
      },
    );

    test('still drops a genuine duplicate of one fragment', () {
      final fragments = fragmentFrame(
        Frame(
          type: FrameType.message,
          ttl: 5,
          flags: const FrameFlags(encrypted: true),
          msgId: _id(43),
          srcHash: peerHash,
          dstHash: 0x0000CCCC,
          payload: Uint8List(fragmentPayloadLength * 2),
        ),
      );

      engine.receive(fragments[0], fromPeer: 'p1');
      final repeat = engine.receive(fragments[0], fromPeer: 'p2');

      expect(repeat.drop, RelayDrop.duplicate);
    });
  });

  group('RelayEngine flood suppression', () {
    late FakeClock clock;
    late RelayEngine engine;

    setUp(() {
      clock = FakeClock();
      engine = RelayEngine(
        localHash: myHash,
        clock: clock.call,
        jitter: FixedJitter(const Duration(milliseconds: 50)).call,
      );
    });

    test(
      'relays when only one other peer was also heard carrying the frame',
      () {
        final decision = engine.receive(
          _frame(id: _id(4), dst: 0x0000CCCC),
          fromPeer: 'p1',
        );
        engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p2');

        expect(
          engine.shouldSuppress(FrameKey.whole(_id(4)), origin: 'p1'),
          isFalse,
        );
        expect(decision.relayFrame, isNotNull);
      },
    );

    test(
      'suppresses the relay once two other peers were heard carrying it',
      () {
        engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p1');
        engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p2');
        engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p3');

        expect(
          engine.shouldSuppress(FrameKey.whole(_id(4)), origin: 'p1'),
          isTrue,
        );
      },
    );

    test(
      'does not count the originating peer toward the suppression threshold',
      () {
        engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p1');
        engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p1');
        engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p1');

        expect(
          engine.shouldSuppress(FrameKey.whole(_id(4)), origin: 'p1'),
          isFalse,
        );
      },
    );

    test('does not count the same peer twice', () {
      engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p1');
      engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p2');
      engine.witness(FrameKey.whole(_id(4)), fromPeer: 'p2');

      expect(
        engine.shouldSuppress(FrameKey.whole(_id(4)), origin: 'p1'),
        isFalse,
      );
    });

    test('records a duplicate arrival as a witness automatically', () {
      engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p1');
      engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p2');
      engine.receive(_frame(id: _id(4), dst: 0x0000CCCC), fromPeer: 'p3');

      expect(
        engine.shouldSuppress(FrameKey.whole(_id(4)), origin: 'p1'),
        isTrue,
        reason:
            'duplicates arriving from distinct peers are exactly the '
            'signal that the frame is already well covered',
      );
    });
  });
}
