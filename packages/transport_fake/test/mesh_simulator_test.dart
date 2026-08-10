import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';
import 'package:transport_fake/transport_fake.dart';

Uint8List _payload(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  group('MeshSimulator topology', () {
    test('reports the shortest hop distance between two nodes', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(4)
        ..connectChain();

      expect(sim.hopDistance(0, 1), 1);
      expect(sim.hopDistance(0, 3), 3);
      expect(sim.hopDistance(3, 0), 3);
    });

    test('reports unreachable nodes as infinite distance', () {
      final sim = MeshSimulator(seed: 1)..addNodes(4);

      sim.link(0, 1);

      expect(sim.hopDistance(0, 3), isNull);
    });

    test('builds a connected random topology within a target diameter', () {
      final sim = MeshSimulator(seed: 7)
        ..addNodes(20)
        ..connectRandom(maxDiameter: 6);

      expect(sim.isConnected, isTrue);
      expect(sim.diameter, lessThanOrEqualTo(6));
    });
  });

  group('MeshSimulator delivery', () {
    test('delivers a direct message between linked neighbours', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(2)
        ..link(0, 1);

      sim.sendMessage(from: 0, to: 1, payload: _payload('hello'));
      sim.run();

      expect(sim.node(1).receivedPayloads.single, _payload('hello'));
    });

    test('delivers across intermediate nodes that relay for it', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(4)
        ..connectChain();

      sim.sendMessage(from: 0, to: 3, payload: _payload('relayed'));
      sim.run();

      expect(sim.node(3).receivedPayloads.single, _payload('relayed'));
      expect(sim.node(1).relayCount, greaterThan(0));
    });

    test('does not deliver a directed message to uninvolved nodes', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(4)
        ..connectChain();

      sim.sendMessage(from: 0, to: 3, payload: _payload('private'));
      sim.run();

      expect(sim.node(1).receivedPayloads, isEmpty);
      expect(sim.node(2).receivedPayloads, isEmpty);
    });

    test('delivers a broadcast to every reachable node', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(5)
        ..connectChain();

      sim.broadcast(from: 0, payload: _payload('everyone'));
      sim.run();

      for (var i = 1; i < 5; i++) {
        expect(
          sim.node(i).receivedPayloads,
          hasLength(1),
          reason: 'node $i missed the broadcast',
        );
      }
    });

    test('never delivers the same message twice to one node', () {
      final sim = MeshSimulator(seed: 3)
        ..addNodes(8)
        ..connectRandom(maxDiameter: 4);

      sim.broadcast(from: 0, payload: _payload('once only'));
      sim.run();

      for (final node in sim.nodes) {
        expect(
          node.receivedPayloads.length,
          lessThanOrEqualTo(1),
          reason: 'node ${node.index} received a duplicate',
        );
      }
    });

    test('stops a message at the hop limit', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(12)
        ..connectChain();

      sim.sendMessage(from: 0, to: 11, payload: _payload('too far'));
      sim.run();

      expect(
        sim.node(11).receivedPayloads,
        isEmpty,
        reason: '11 hops exceeds the protocol maximum of $maxTtl',
      );
      expect(
        sim.node(maxTtl).receivedFrameCount,
        greaterThan(0),
        reason: 'it should still have travelled as far as the hop limit allows',
      );
    });

    test('reassembles a fragmented payload delivered over multiple hops', () {
      final sim = MeshSimulator(seed: 1)
        ..addNodes(3)
        ..connectChain();
      final big = Uint8List.fromList(List<int>.generate(4000, (i) => i & 0xFF));

      sim.sendMessage(from: 0, to: 2, payload: big);
      sim.run();

      expect(sim.node(2).receivedPayloads.single, big);
    });
  });

  group('MeshSimulator adverse conditions', () {
    test(
      'still delivers over redundant paths when a fraction of frames are lost',
      () {
        final sim = MeshSimulator(seed: 11, packetLoss: 0.2)
          ..addNodes(20)
          ..connectRandom(maxDiameter: 6);

        sim.broadcast(from: 0, payload: _payload('lossy'));
        sim.run();

        final reached = sim.nodes
            .where((n) => n.receivedPayloads.isNotEmpty)
            .length;
        expect(
          reached,
          greaterThanOrEqualTo(15),
          reason: 'flooding over redundant paths should survive 20% loss',
        );
      },
    );

    test('cannot deliver across a partition', () {
      final sim = MeshSimulator(seed: 2)
        ..addNodes(6)
        ..connectChain();

      sim.partition(between: 2, and: 3);
      sim.sendMessage(from: 0, to: 5, payload: _payload('blocked'));
      sim.run();

      expect(sim.node(5).receivedPayloads, isEmpty);
    });

    test('delivers a queued message once a partition heals', () {
      final sim = MeshSimulator(seed: 2)
        ..addNodes(6)
        ..connectChain();

      sim.partition(between: 2, and: 3);
      sim.sendMessage(from: 0, to: 5, payload: _payload('deferred'));
      sim.run();
      expect(sim.node(5).receivedPayloads, isEmpty);

      sim.heal(between: 2, and: 3);
      sim.flushStoreAndForward();
      sim.run();

      expect(sim.node(5).receivedPayloads.single, _payload('deferred'));
    });

    test('suppresses redundant relays in a dense cluster', () {
      final dense = MeshSimulator(seed: 5)
        ..addNodes(12)
        ..connectFullyMeshed();
      final sparse = MeshSimulator(seed: 5)
        ..addNodes(12)
        ..connectChain();

      dense.broadcast(from: 0, payload: _payload('dense'));
      dense.run();
      sparse.broadcast(from: 0, payload: _payload('sparse'));
      sparse.run();

      final naiveFloodTransmissions = 12 * 11;
      expect(
        dense.totalTransmissions,
        lessThan(naiveFloodTransmissions),
        reason: 'flood suppression must beat naive flooding in a dense cluster',
      );
    });

    test('is deterministic for a given seed', () {
      MeshSimulator build() => MeshSimulator(seed: 99, packetLoss: 0.3)
        ..addNodes(15)
        ..connectRandom(maxDiameter: 6);

      final a = build()
        ..broadcast(from: 0, payload: _payload('x'))
        ..run();
      final b = build()
        ..broadcast(from: 0, payload: _payload('x'))
        ..run();

      expect(a.totalTransmissions, b.totalTransmissions);
      expect(
        a.nodes.map((n) => n.receivedPayloads.length),
        b.nodes.map((n) => n.receivedPayloads.length),
      );
    });
  });

  group('P0 exit gate', () {
    test('a 20-node mesh delivers a multi-hop message under 20% packet loss '
        'across a partition-and-heal cycle, with no duplicates', () {
      final sim = MeshSimulator(seed: 4242, packetLoss: 0.2)
        ..addNodes(20)
        ..connectRandom(maxDiameter: 6);

      // Pick a destination that is genuinely multi-hop, never a direct neighbour.
      final destination = sim.nodes
          .map((n) => n.index)
          .firstWhere((i) => (sim.hopDistance(0, i) ?? 0) >= 3);
      expect(sim.hopDistance(0, destination), greaterThanOrEqualTo(3));

      // Cut the mesh in half mid-flight, then heal it.
      final cut = sim.partitionHalf();
      sim.sendMessage(from: 0, to: destination, payload: _payload('exit gate'));
      sim.run();

      sim.healAll(cut);
      sim.flushStoreAndForward();
      sim.run();

      final node = sim.node(destination);
      expect(
        node.receivedPayloads,
        hasLength(1),
        reason: 'exactly one delivery, no duplicates',
      );
      expect(node.receivedPayloads.single, _payload('exit gate'));
      expect(
        sim.hopCountOfDelivery(destination),
        greaterThanOrEqualTo(2),
        reason: 'delivery must have been relayed, not direct',
      );
    });
  });
}
