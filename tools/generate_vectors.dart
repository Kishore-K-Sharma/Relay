// Regenerates the shared test vectors consumed by Dart, Kotlin and Swift.
//
// Run: dart run tools/generate_vectors.dart
//
// The vectors are the contract between the three relay implementations. Change
// the vectors first, then make every implementation pass them.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

MsgId _id(int seed) => MsgId(Uint8List.fromList(List<int>.filled(8, seed)));

Uint8List _body(int n, {int seed = 0}) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + seed) & 0xFF));

Map<String, Object?> _frameVector(String name, Frame frame) => {
  'name': name,
  'frame': {
    'version': frame.version,
    'type': frame.type.name,
    'typeWire': frame.type.wireValue,
    'ttl': frame.ttl,
    'flags': {
      'encrypted': frame.flags.encrypted,
      'fragmented': frame.flags.fragmented,
      'compressed': frame.flags.compressed,
      'urgent': frame.flags.urgent,
    },
    'msgId': frame.msgId.toHex(),
    'srcHash': frame.srcHash,
    'dstHash': frame.dstHash,
    'payloadHex': _hex(frame.payload),
  },
  'encodedHex': _hex(frame.encode()),
};

List<Map<String, Object?>> _protocolVectors() {
  final vectors = <Map<String, Object?>>[];

  for (final type in FrameType.values) {
    vectors.add(
      _frameVector(
        'type-${type.name}',
        Frame(
          type: type,
          ttl: 7,
          flags: const FrameFlags(encrypted: true),
          msgId: _id(1),
          srcHash: 0x11223344,
          dstHash: 0xAABBCCDD,
          payload: _body(16),
        ),
      ),
    );
  }

  vectors.add(
    _frameVector(
      'empty-payload',
      Frame(
        type: FrameType.ack,
        ttl: 0,
        flags: const FrameFlags(),
        msgId: _id(2),
        srcHash: 0,
        dstHash: 0,
        payload: Uint8List(0),
      ),
    ),
  );

  vectors.add(
    _frameVector(
      'broadcast-all-flags',
      Frame(
        type: FrameType.announce,
        ttl: maxTtl,
        flags: const FrameFlags(
          encrypted: true,
          fragmented: true,
          compressed: true,
          urgent: true,
        ),
        msgId: _id(0xFF),
        srcHash: 0xFFFFFFFF,
        dstHash: broadcastHash,
        payload: _body(maxPayloadLength),
      ),
    ),
  );

  return vectors;
}

List<Map<String, Object?>> _fragmentVectors() {
  final cases = <Map<String, Object?>>[];

  for (final size in <int>[
    1,
    maxPayloadLength,
    maxPayloadLength + 1,
    fragmentPayloadLength * 3,
    fragmentPayloadLength * 3 + 7,
  ]) {
    final logical = Frame(
      type: FrameType.message,
      ttl: maxTtl,
      flags: const FrameFlags(encrypted: true),
      msgId: _id(5),
      srcHash: 0x01010101,
      dstHash: 0x02020202,
      payload: _body(size, seed: 3),
    );
    final fragments = fragmentFrame(logical);

    cases.add({
      'name': 'payload-$size',
      'payloadLength': size,
      'fragmentCount': fragments.length,
      'fragmentsHex': fragments.map((f) => _hex(f.encode())).toList(),
    });
  }

  return cases;
}

/// Each case describes what a relay must decide, given a frame and prior state.
List<Map<String, Object?>> _relayVectors() {
  const localHash = 0x0000AAAA;

  Map<String, Object?> vector({
    required String name,
    required Frame frame,
    required String fromPeer,
    required List<Map<String, String>> priorSeen,
    required bool deliverLocally,
    required bool relay,
    int? relayTtl,
    String? drop,
    String? note,
  }) => {
    'name': name,
    'localHash': localHash,
    'priorSeen': priorSeen,
    'input': {'fromPeer': fromPeer, 'encodedHex': _hex(frame.encode())},
    'expect': {
      'deliverLocally': deliverLocally,
      'relay': relay,
      'relayTtl': ?relayTtl,
      'drop': drop,
      'excludePeer': fromPeer,
    },
    'note': ?note,
  };

  Frame f({
    required int dst,
    int ttl = 5,
    int src = 0x0000BBBB,
    MsgId? id,
    bool fragmented = false,
    Uint8List? payload,
  }) => Frame(
    type: fragmented ? FrameType.fragment : FrameType.message,
    ttl: ttl,
    flags: FrameFlags(encrypted: true, fragmented: fragmented),
    msgId: id ?? _id(1),
    srcHash: src,
    dstHash: dst,
    payload: payload ?? _body(8),
  );

  final fragments = fragmentFrame(
    Frame(
      type: FrameType.message,
      ttl: 5,
      flags: const FrameFlags(encrypted: true),
      msgId: _id(20),
      srcHash: 0x0000BBBB,
      dstHash: 0x0000CCCC,
      payload: _body(fragmentPayloadLength * 2),
    ),
  );

  return <Map<String, Object?>>[
    vector(
      name: 'addressed-to-us-delivers-and-stops',
      frame: f(dst: localHash),
      fromPeer: 'p1',
      priorSeen: const [],
      deliverLocally: true,
      relay: false,
      note: 'A frame that reached its destination must not be forwarded again.',
    ),
    vector(
      name: 'broadcast-delivers-and-relays',
      frame: f(dst: broadcastHash),
      fromPeer: 'p1',
      priorSeen: const [],
      deliverLocally: true,
      relay: true,
      relayTtl: 4,
    ),
    vector(
      name: 'for-other-relays-only',
      frame: f(dst: 0x0000CCCC),
      fromPeer: 'p1',
      priorSeen: const [],
      deliverLocally: false,
      relay: true,
      relayTtl: 4,
    ),
    vector(
      name: 'hop-limit-reached-drops',
      frame: f(dst: 0x0000CCCC, ttl: 0),
      fromPeer: 'p1',
      priorSeen: const [],
      deliverLocally: false,
      relay: false,
      drop: 'hopLimitReached',
    ),
    vector(
      name: 'duplicate-drops',
      frame: f(dst: 0x0000CCCC, id: _id(9)),
      fromPeer: 'p2',
      priorSeen: [
        {'msgId': _id(9).toHex(), 'fragmentIndex': '-1'},
      ],
      deliverLocally: false,
      relay: false,
      drop: 'duplicate',
    ),
    vector(
      name: 'own-frame-echo-drops',
      frame: f(dst: 0x0000CCCC, src: localHash),
      fromPeer: 'p1',
      priorSeen: const [],
      deliverLocally: false,
      relay: false,
      drop: 'ownFrame',
    ),
    vector(
      name: 'second-fragment-of-known-message-still-relays',
      frame: fragments[1],
      fromPeer: 'p1',
      priorSeen: [
        {'msgId': _id(20).toHex(), 'fragmentIndex': '0'},
      ],
      deliverLocally: false,
      relay: true,
      relayTtl: 4,
      note:
          'Fragments share one msgId. Deduplication keys on '
          '(msgId, fragmentIndex) or multi-fragment messages never propagate.',
    ),
    vector(
      name: 'repeat-of-same-fragment-drops',
      frame: fragments[0],
      fromPeer: 'p2',
      priorSeen: [
        {'msgId': _id(20).toHex(), 'fragmentIndex': '0'},
      ],
      deliverLocally: false,
      relay: false,
      drop: 'duplicate',
    ),
  ];
}

Future<void> _write(String path, Object? json) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(json)}\n',
  );
  stdout.writeln('wrote $path');
}

Future<void> main() async {
  await _write('testvectors/protocol/frames.json', {
    'protocolVersion': protocolVersion,
    'frameHeaderLength': frameHeaderLength,
    'maxTtl': maxTtl,
    'maxPayloadLength': maxPayloadLength,
    'vectors': _protocolVectors(),
  });

  await _write('testvectors/protocol/fragments.json', {
    'fragmentHeaderLength': fragmentHeaderLength,
    'fragmentPayloadLength': fragmentPayloadLength,
    'vectors': _fragmentVectors(),
  });

  await _write('testvectors/relay/decisions.json', {
    'suppressionThreshold': suppressionThreshold,
    'jitterMinMs': relayJitterMin.inMilliseconds,
    'jitterMaxMs': relayJitterMax.inMilliseconds,
    'dedupMaxEntries': dedupMaxEntries,
    'dedupExpirySeconds': dedupExpiry.inSeconds,
    'vectors': _relayVectors(),
  });
}
