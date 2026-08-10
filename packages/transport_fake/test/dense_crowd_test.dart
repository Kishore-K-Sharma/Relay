import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';
import 'package:transport_fake/transport_fake.dart';

/// The Phase 6 dense-crowd gate.
///
/// The failure this guards against is a broadcast storm. Naive flooding in a
/// dense mesh costs O(nodes × degree) transmissions for every message, and in a
/// crowd of a few hundred people that saturates the 2.4 GHz band, drains every
/// battery in the room, and delivers nothing. Flood suppression — waiting a
/// jittered moment and abandoning a relay once enough neighbours are heard
/// carrying the same frame — is what prevents it.
///
/// These tests assert the property that matters: **cost per node stays flat as
/// the crowd grows**. A suppression bug would not fail the correctness tests;
/// everything would still be delivered. It would only show up here, as the
/// numbers climbing with node count.
MeshSimulator crowd({
  required int size,
  int density = 6,
  int seed = 7,
  double packetLoss = 0.0,
}) {
  final sim = MeshSimulator(seed: seed, packetLoss: packetLoss)..addNodes(size);
  sim.connectRandom(maxDiameter: 6, minDegree: density);
  return sim;
}

int deliveredCount(MeshSimulator sim) =>
    sim.nodes.where((n) => n.receivedPayloads.isNotEmpty).length;

int relayTotal(MeshSimulator sim) =>
    sim.nodes.fold<int>(0, (sum, n) => sum + n.relayCount);

void main() {
  group('a broadcast in a dense crowd', () {
    test('reaches everyone at 60 nodes', () {
      final sim = crowd(size: 60);

      sim.broadcast(from: 0, payload: Uint8List.fromList([1, 2, 3]));
      sim.run();

      expect(deliveredCount(sim), 59);
    });

    test('reaches everyone exactly once', () {
      final sim = crowd(size: 60);

      sim.broadcast(from: 0, payload: Uint8List.fromList([1, 2, 3]));
      sim.run();

      // Every node has many paths back to the origin in a dense mesh. Without
      // deduplication each one would surface as a repeated message.
      for (final node in sim.nodes.skip(1)) {
        expect(
          node.receivedPayloads,
          hasLength(1),
          reason: 'node ${node.index}',
        );
      }
    });

    test('costs a flat number of transmissions per node as the crowd grows', () {
      final cost = <int, double>{};

      for (final size in [20, 40, 60, 80]) {
        final sim = crowd(size: size);
        sim.broadcast(from: 0, payload: Uint8List.fromList([1]));
        sim.run();

        expect(
          deliveredCount(sim),
          size - 1,
          reason: 'delivery at $size nodes',
        );
        cost[size] = sim.totalTransmissions / size;
      }

      // Measured 2.4–4.1 across this range. The ceiling is set well above that
      // so ordinary variation does not fail the build, but far below the
      // naive-flooding figure, which grows without bound.
      for (final entry in cost.entries) {
        expect(
          entry.value,
          lessThan(8),
          reason: '${entry.key} nodes cost ${entry.value} transmissions each',
        );
      }

      // The real assertion: quadrupling the crowd must not multiply the
      // per-node cost. Anything above 2x here means suppression is not working.
      expect(cost[80]! / cost[20]!, lessThan(2.0));
    });

    test('stays far below what naive flooding would cost', () {
      const size = 60;
      const density = 6;
      final sim = crowd(size: size, density: density);

      sim.broadcast(from: 0, payload: Uint8List.fromList([1]));
      sim.run();

      // Every node relaying to every neighbour, once per hop of the ttl budget.
      const naive = size * density * maxTtl;
      expect(sim.totalTransmissions, lessThan(naive ~/ 8));
    });

    test('a denser crowd needs fewer relays, not more', () {
      final sparse = crowd(size: 60, density: 4);
      final dense = crowd(size: 60, density: 8);

      for (final sim in [sparse, dense]) {
        sim.broadcast(from: 0, payload: Uint8List.fromList([1]));
        sim.run();
        expect(deliveredCount(sim), 59);
      }

      // Counterintuitive and the whole point of witness-based suppression: the
      // more neighbours a node has, the more likely it hears someone else
      // already carrying the frame, and the more often it stays quiet.
      expect(relayTotal(dense), lessThan(relayTotal(sparse)));
    });

    test('does not loop', () {
      final sim = crowd(size: 80, density: 8);
      sim.broadcast(from: 0, payload: Uint8List.fromList([1]));

      // `run` throws past its event ceiling. A relay loop in a mesh this dense
      // would blow through it immediately.
      expect(() => sim.run(maxEvents: 20000), returnsNormally);
    });
  });

  group('a directed message in a dense crowd', () {
    test('crosses 60 nodes and arrives once', () {
      final sim = crowd(size: 60);

      sim.sendMessage(from: 0, to: 59, payload: Uint8List.fromList([4, 2]));
      sim.run();
      for (var i = 0; i < 5; i++) {
        sim.flushStoreAndForward();
        sim.run();
      }

      expect(sim.node(59).receivedPayloads, hasLength(1));
    });

    test('survives heavy packet loss once retries are allowed', () {
      const trials = 12;
      var firstAttempt = 0;
      var afterRetries = 0;

      for (var seed = 0; seed < trials; seed++) {
        final sim = crowd(size: 60, seed: seed, packetLoss: 0.4);
        sim.sendMessage(from: 0, to: 59, payload: Uint8List.fromList([1]));
        sim.run();

        if (sim.node(59).receivedPayloads.isNotEmpty) firstAttempt++;

        for (var i = 0; i < 5; i++) {
          sim.flushStoreAndForward();
          sim.run();
        }
        if (sim.node(59).receivedPayloads.isNotEmpty) afterRetries++;
      }

      // At 40% loss a single attempt sometimes fails, which is expected and is
      // exactly why the outbox exists. What must not happen is a message being
      // permanently lost while both devices are still present.
      expect(firstAttempt, greaterThanOrEqualTo(trials - 2));
      expect(afterRetries, trials);
    });

    test('retrying does not deliver the message twice', () {
      final sim = crowd(size: 60, packetLoss: 0.3);

      sim.sendMessage(from: 0, to: 59, payload: Uint8List.fromList([7]));
      sim.run();
      for (var i = 0; i < 5; i++) {
        sim.flushStoreAndForward();
        sim.run();
      }

      // Each retry carries a fresh MsgId so it can slip past relays that saw
      // the original. Only the app-layer (origin, sequence) key stops the
      // recipient seeing the same message several times.
      expect(sim.node(59).receivedPayloads, hasLength(1));
    });
  });

  group('sustained traffic', () {
    test('twenty senders at once all get through', () {
      final sim = crowd(size: 60);

      for (var sender = 0; sender < 20; sender++) {
        sim.sendMessage(
          from: sender,
          to: 59 - sender,
          payload: Uint8List.fromList([sender]),
        );
      }
      sim.run();
      for (var i = 0; i < 3; i++) {
        sim.flushStoreAndForward();
        sim.run();
      }

      for (var sender = 0; sender < 20; sender++) {
        expect(
          sim.node(59 - sender).receivedPayloads,
          isNotEmpty,
          reason: 'message from $sender to ${59 - sender}',
        );
      }
    });

    test('concurrent traffic does not multiply per-message cost', () {
      final single = crowd(size: 60);
      single.sendMessage(from: 0, to: 59, payload: Uint8List.fromList([1]));
      single.run();

      final many = crowd(size: 60);
      for (var sender = 0; sender < 20; sender++) {
        many.sendMessage(
          from: sender,
          to: 59 - sender,
          payload: Uint8List.fromList([sender]),
        );
      }
      many.run();

      // Twenty messages must cost roughly twenty times one, not more. Anything
      // superlinear means concurrent traffic is defeating suppression, which is
      // the condition a real crowd creates and a single-message test misses.
      expect(many.totalTransmissions, lessThan(single.totalTransmissions * 30));
    });
  });
}
