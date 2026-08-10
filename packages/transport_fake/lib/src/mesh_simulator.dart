import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';

import 'sim_node.dart';

/// An undirected link between two nodes.
class MeshLink {
  MeshLink(this.a, this.b);
  final int a;
  final int b;

  @override
  bool operator ==(Object other) =>
      other is MeshLink &&
      ((other.a == a && other.b == b) || (other.a == b && other.b == a));

  @override
  int get hashCode => a.hashCode ^ b.hashCode;
}

class _Event implements Comparable<_Event> {
  _Event(this.at, this.sequence, this.action);
  final Duration at;
  final int sequence;
  final void Function() action;

  @override
  int compareTo(_Event other) {
    final byTime = at.compareTo(other.at);
    return byTime != 0 ? byTime : sequence.compareTo(other.sequence);
  }
}

/// A deterministic, virtual-time mesh of [SimNode]s.
///
/// Time never advances in real seconds: events are drained from an ordered
/// queue, so a scenario spanning simulated minutes runs in microseconds and
/// produces identical results for a given seed.
class MeshSimulator {
  MeshSimulator({
    int seed = 0,
    this.packetLoss = 0.0,
    this.linkLatency = const Duration(milliseconds: 8),
  }) : _random = Random(seed);

  /// Probability in [0,1] that any single transmission is lost.
  final double packetLoss;

  /// One-way propagation delay across a link.
  final Duration linkLatency;

  final Random _random;
  final List<SimNode> nodes = <SimNode>[];
  final Set<MeshLink> _links = <MeshLink>{};
  final Set<MeshLink> _downLinks = <MeshLink>{};
  final SplayTreeSet<_Event> _queue = SplayTreeSet<_Event>();

  Duration _now = Duration.zero;
  int _sequence = 0;
  int _msgCounter = 0;
  int _appSeq = 0;

  int totalTransmissions = 0;
  int totalLost = 0;

  Duration get now => _now;

  SimNode node(int index) => nodes[index];

  /// Address hash for a node. Distinct and stable across a run.
  static int hashOf(int index) => 0x10000000 + index;

  void addNodes(int count) {
    for (var i = 0; i < count; i++) {
      nodes.add(
        SimNode(
          index: nodes.length,
          addressHash: hashOf(nodes.length),
          clock: () => _now,
          jitter: _jitter,
        ),
      );
    }
  }

  Duration _jitter(Duration min, Duration max) {
    final span = max.inMicroseconds - min.inMicroseconds;
    return Duration(
      microseconds: min.inMicroseconds + _random.nextInt(span + 1),
    );
  }

  // ---------------------------------------------------------------- topology

  void link(int a, int b) {
    if (a == b) return;
    _links.add(MeshLink(a, b));
  }

  void connectChain() {
    for (var i = 0; i < nodes.length - 1; i++) {
      link(i, i + 1);
    }
  }

  void connectFullyMeshed() {
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        link(i, j);
      }
    }
  }

  /// Builds a connected topology within [maxDiameter], where every node has at
  /// least [minDegree] neighbours.
  ///
  /// [minDegree] matters more than it looks. A spanning path alone is connected
  /// and meets a diameter target, but has almost no redundant paths, so any
  /// packet loss severs the mesh. A real crowd is dense — people stand near
  /// several other people — and redundancy is precisely what lets flooding
  /// survive loss. Modelling that is the difference between a simulator that
  /// predicts field behaviour and one that does not.
  void connectRandom({int maxDiameter = 6, int minDegree = 3}) {
    // A spanning path guarantees connectivity before any random additions.
    final order = List<int>.generate(nodes.length, (i) => i)..shuffle(_random);
    for (var i = 0; i < order.length - 1; i++) {
      link(order[i], order[i + 1]);
    }

    // Raise every node to the minimum degree.
    final target = min(minDegree, nodes.length - 1);
    for (var i = 0; i < nodes.length; i++) {
      var guard = nodes.length * 4;
      while (neighbours(i).length < target && guard-- > 0) {
        final candidate = _random.nextInt(nodes.length);
        if (candidate != i) link(i, candidate);
      }
    }

    // Add shortcuts until the diameter target is met. Bounded so a pathological
    // seed cannot loop forever.
    var guard = nodes.length * nodes.length;
    while (diameter > maxDiameter && guard-- > 0) {
      link(_random.nextInt(nodes.length), _random.nextInt(nodes.length));
    }
  }

  Iterable<int> neighbours(int index) sync* {
    for (final l in _links) {
      if (_downLinks.contains(l)) continue;
      if (l.a == index) yield l.b;
      if (l.b == index) yield l.a;
    }
  }

  /// Shortest hop count between two nodes, or null when unreachable.
  int? hopDistance(int from, int to) {
    if (from == to) return 0;
    final visited = <int>{from};
    var frontier = <int>[from];
    var distance = 0;

    while (frontier.isNotEmpty) {
      distance++;
      final next = <int>[];
      for (final current in frontier) {
        for (final n in neighbours(current)) {
          if (!visited.add(n)) continue;
          if (n == to) return distance;
          next.add(n);
        }
      }
      frontier = next;
    }
    return null;
  }

  bool get isConnected =>
      nodes.every((n) => n.index == 0 || hopDistance(0, n.index) != null);

  /// Longest shortest-path in the graph. Returns a large sentinel when the
  /// graph is disconnected, so diameter-driven loops keep adding links.
  int get diameter {
    var worst = 0;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final d = hopDistance(i, j);
        if (d == null) return 1 << 20;
        if (d > worst) worst = d;
      }
    }
    return worst;
  }

  // --------------------------------------------------------------- partition

  void partition({required int between, required int and}) =>
      _downLinks.add(MeshLink(between, and));

  void heal({required int between, required int and}) =>
      _downLinks.remove(MeshLink(between, and));

  /// Severs every link crossing the midpoint of the node list. Returns the cut
  /// links so [healAll] can restore exactly those.
  List<MeshLink> partitionHalf() {
    final mid = nodes.length ~/ 2;
    final cut = _links
        .where((l) => (l.a < mid) != (l.b < mid))
        .toList(growable: false);
    _downLinks.addAll(cut);
    return cut;
  }

  void healAll(List<MeshLink> cut) => _downLinks.removeAll(cut);

  // ----------------------------------------------------------------- sending

  MsgId _nextMsgId() {
    _msgCounter++;
    final bytes = Uint8List(8);
    ByteData.view(bytes.buffer).setUint64(0, _msgCounter, Endian.big);
    return MsgId(bytes);
  }

  void sendMessage({
    required int from,
    required int to,
    required Uint8List payload,
  }) => _originate(from: from, dstHash: hashOf(to), payload: payload);

  void broadcast({required int from, required Uint8List payload}) =>
      _originate(from: from, dstHash: broadcastHash, payload: payload);

  void _originate({
    required int from,
    required int dstHash,
    required Uint8List payload,
  }) {
    _appSeq++;
    nodes[from].outbox.add(
      PendingMessage(sequence: _appSeq, dstHash: dstHash, payload: payload),
    );
    _emit(from: from, sequence: _appSeq, dstHash: dstHash, payload: payload);
  }

  /// Puts one copy of a logical message onto the wire, with a fresh [MsgId].
  ///
  /// A retry deliberately uses a new [MsgId]: the old one is already in every
  /// nearby relay's deduplication table, so re-sending it would be dropped
  /// immediately and never reach a newly-available path. End-to-end duplicate
  /// suppression is therefore the application layer's job, done here with the
  /// (origin, sequence) header below — exactly the split the real outbox uses.
  void _emit({
    required int from,
    required int sequence,
    required int dstHash,
    required Uint8List payload,
  }) {
    final logical = Frame(
      type: FrameType.message,
      ttl: maxTtl,
      flags: const FrameFlags(encrypted: true),
      msgId: _nextMsgId(),
      srcHash: hashOf(from),
      dstHash: dstHash,
      payload: _AppHeader(origin: from, sequence: sequence).prepend(payload),
    );

    for (final frame in fragmentFrame(logical)) {
      _transmit(from: from, frame: frame, exclude: null);
    }
  }

  /// Pushes one frame onto every live link out of [from].
  void _transmit({
    required int from,
    required Frame frame,
    required int? exclude,
  }) {
    final sender = nodes[from];
    var sent = 0;

    for (final peer in neighbours(from).toList(growable: false)) {
      if (peer == exclude) continue;
      sent++;
      totalTransmissions++;
      sender.transmittedCount++;

      if (_random.nextDouble() < packetLoss) {
        totalLost++;
        continue;
      }
      _schedule(
        linkLatency,
        () => _receive(at: peer, frame: frame, fromPeer: from),
      );
    }

    if (sent == 0) {
      // Nowhere to send right now. Hold it for when a link comes back.
      sender.storeAndForward.add(frame);
    }
  }

  void _receive({
    required int at,
    required Frame frame,
    required int fromPeer,
  }) {
    final target = nodes[at];
    target.receivedFrameCount++;

    final decision = target.relay.receive(frame, fromPeer: '$fromPeer');

    if (decision.deliverLocally) {
      final message = target.reassembler.offer(frame);
      if (message != null) {
        final app = _AppHeader.parse(message.payload);
        // End-to-end duplicate suppression. A retry carries a fresh MsgId, so
        // the relay-level dedup table cannot catch it; only the origin and
        // sequence can.
        if (target.deliveredAppIds.add(app.key)) {
          target.receivedPayloads.add(app.body);
          target.lastDeliveryHopCount = maxTtl - frame.ttl;
          _markDelivered(app.origin, app.sequence);
        }
      }
    }

    final relayFrame = decision.relayFrame;
    if (relayFrame == null) return;

    _schedule(decision.jitter, () {
      if (target.relay.shouldSuppress(
        FrameKey.of(frame),
        origin: '$fromPeer',
      )) {
        return;
      }
      target.relayCount++;
      _transmit(from: at, frame: relayFrame, exclude: fromPeer);
    });
  }

  void _markDelivered(int origin, int sequence) {
    for (final pending in nodes[origin].outbox) {
      if (pending.sequence == sequence) pending.delivered = true;
    }
  }

  /// Retries every message that has not been confirmed delivered, and re-offers
  /// frames held by nodes that were completely isolated.
  ///
  /// This is the simulator's stand-in for the outbox retry described in
  /// ARCHITECTURE.md section 9: the sender keeps trying until an
  /// acknowledgement arrives or the message expires.
  void flushStoreAndForward() {
    for (final node in nodes) {
      final held = List<Frame>.from(node.storeAndForward);
      node.storeAndForward.clear();
      for (final frame in held) {
        _transmit(from: node.index, frame: frame, exclude: null);
      }

      for (final pending in node.outbox) {
        if (pending.delivered) continue;
        _emit(
          from: node.index,
          sequence: pending.sequence,
          dstHash: pending.dstHash,
          payload: pending.payload,
        );
      }
    }
  }

  /// Hops taken by the frame that completed the delivery at [nodeIndex].
  int? hopCountOfDelivery(int nodeIndex) =>
      nodes[nodeIndex].lastDeliveryHopCount;

  // ------------------------------------------------------------------ engine

  void _schedule(Duration delay, void Function() action) {
    _queue.add(_Event(_now + delay, _sequence++, action));
  }

  /// Drains the event queue, advancing virtual time. Returns the number of
  /// events processed.
  int run({int maxEvents = 200000}) {
    var processed = 0;
    while (_queue.isNotEmpty && processed < maxEvents) {
      final event = _queue.first;
      _queue.remove(event);
      _now = event.at;
      event.action();
      processed++;
    }
    if (processed >= maxEvents) {
      throw StateError(
        'simulation exceeded $maxEvents events — likely a relay loop',
      );
    }
    return processed;
  }
}

/// Application-level header the simulator wraps around each payload.
///
/// The mesh's [MsgId] identifies a *transmission*; a retry is a different
/// transmission of the same message. Identifying the *message* end to end needs
/// its own field, which is what this carries.
class _AppHeader {
  const _AppHeader({required this.origin, required this.sequence});

  static const int length = 8;

  final int origin;
  final int sequence;

  Uint8List prepend(Uint8List body) {
    final out = Uint8List(length + body.length);
    final view = ByteData.view(out.buffer);
    view.setUint32(0, origin, Endian.big);
    view.setUint32(4, sequence, Endian.big);
    out.setRange(length, out.length, body);
    return out;
  }

  static ({int origin, int sequence, String key, Uint8List body}) parse(
    Uint8List payload,
  ) {
    final view = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
      payload.length,
    );
    final origin = view.getUint32(0, Endian.big);
    final sequence = view.getUint32(4, Endian.big);
    return (
      origin: origin,
      sequence: sequence,
      key: '$origin:$sequence',
      body: Uint8List.sublistView(payload, length),
    );
  }
}
