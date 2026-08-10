import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';

/// One simulated device.
///
/// Runs the real [RelayEngine] and [Reassembler] from `core_protocol`, so the
/// simulator exercises production logic rather than a reimplementation of it.
class SimNode {
  SimNode({
    required this.index,
    required this.addressHash,
    required ProtocolClock clock,
    required JitterSource jitter,
  }) : relay = RelayEngine(
         localHash: addressHash,
         clock: clock,
         jitter: jitter,
       ),
       reassembler = Reassembler(clock: clock);

  final int index;
  final int addressHash;
  final RelayEngine relay;
  final Reassembler reassembler;

  /// Fully reassembled payloads delivered to this node's application layer.
  final List<Uint8List> receivedPayloads = <Uint8List>[];

  /// Frames held because this node had no live link at all when they arrived.
  final List<Frame> storeAndForward = <Frame>[];

  /// Messages this node originated that are not yet confirmed delivered.
  final List<PendingMessage> outbox = <PendingMessage>[];

  /// End-to-end identities already delivered, so a retry is not shown twice.
  final Set<String> deliveredAppIds = <String>{};

  int receivedFrameCount = 0;
  int relayCount = 0;
  int transmittedCount = 0;

  /// Hop count of the frame that completed the most recent delivery.
  int? lastDeliveryHopCount;

  @override
  String toString() =>
      'SimNode($index, hash=0x${addressHash.toRadixString(16)})';
}

/// A message awaiting confirmed delivery.
class PendingMessage {
  PendingMessage({
    required this.sequence,
    required this.dstHash,
    required this.payload,
  });

  final int sequence;
  final int dstHash;
  final Uint8List payload;
  bool delivered = false;
}
