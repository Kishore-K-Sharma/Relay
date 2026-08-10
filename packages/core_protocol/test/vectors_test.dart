// Verifies the Dart implementation against the shared vectors in
// `testvectors/`. Kotlin and Swift consume the same files, which is what keeps
// the three relay implementations from drifting apart.
//
// A failure here means either the implementation changed behaviour or the
// vectors were regenerated without updating the other two implementations.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Locates the repository root from the test's working directory, which differs
/// between a workspace-wide run and a single-package run.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (Directory('${dir.path}/testvectors').existsSync()) return dir;
    dir = dir.parent;
  }
  throw StateError(
    'could not locate testvectors/ from ${Directory.current.path}',
  );
}

Map<String, Object?> _load(String relative) {
  final file = File('${_repoRoot().path}/$relative');
  if (!file.existsSync()) {
    throw StateError(
      'missing vector file $relative — run tools/generate_vectors.dart',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  group('protocol constants match the published vectors', () {
    final frames = _load('testvectors/protocol/frames.json');
    final fragments = _load('testvectors/protocol/fragments.json');
    final relay = _load('testvectors/relay/decisions.json');

    test('frame constants', () {
      expect(frames['protocolVersion'], protocolVersion);
      expect(frames['frameHeaderLength'], frameHeaderLength);
      expect(frames['maxTtl'], maxTtl);
      expect(frames['maxPayloadLength'], maxPayloadLength);
    });

    test('fragment constants', () {
      expect(fragments['fragmentHeaderLength'], fragmentHeaderLength);
      expect(fragments['fragmentPayloadLength'], fragmentPayloadLength);
    });

    test('relay constants', () {
      expect(relay['suppressionThreshold'], suppressionThreshold);
      expect(relay['jitterMinMs'], relayJitterMin.inMilliseconds);
      expect(relay['jitterMaxMs'], relayJitterMax.inMilliseconds);
      expect(relay['dedupMaxEntries'], dedupMaxEntries);
      expect(relay['dedupExpirySeconds'], dedupExpiry.inSeconds);
    });
  });

  group('frame vectors', () {
    final data = _load('testvectors/protocol/frames.json');
    final vectors = (data['vectors']! as List).cast<Map<String, Object?>>();

    test('the vector file is not empty', () => expect(vectors, isNotEmpty));

    for (final vector in vectors) {
      final name = vector['name']! as String;
      final spec = vector['frame']! as Map<String, Object?>;
      final expectedHex = vector['encodedHex']! as String;

      test('$name decodes to the documented field values', () {
        final frame = Frame.decode(_unhex(expectedHex));
        final flags = spec['flags']! as Map<String, Object?>;

        expect(frame.version, spec['version']);
        expect(frame.type.name, spec['type']);
        expect(frame.type.wireValue, spec['typeWire']);
        expect(frame.ttl, spec['ttl']);
        expect(frame.flags.encrypted, flags['encrypted']);
        expect(frame.flags.fragmented, flags['fragmented']);
        expect(frame.flags.compressed, flags['compressed']);
        expect(frame.flags.urgent, flags['urgent']);
        expect(frame.msgId.toHex(), spec['msgId']);
        expect(frame.srcHash, spec['srcHash']);
        expect(frame.dstHash, spec['dstHash']);
        expect(_hex(frame.payload), spec['payloadHex']);
      });

      test('$name re-encodes to the documented bytes', () {
        expect(_hex(Frame.decode(_unhex(expectedHex)).encode()), expectedHex);
      });
    }
  });

  group('fragment vectors', () {
    final data = _load('testvectors/protocol/fragments.json');
    final vectors = (data['vectors']! as List).cast<Map<String, Object?>>();

    for (final vector in vectors) {
      final name = vector['name']! as String;
      final expectedCount = vector['fragmentCount']! as int;
      final expectedHex = (vector['fragmentsHex']! as List).cast<String>();

      test('$name splits into the documented fragments', () {
        expect(expectedHex, hasLength(expectedCount));

        final frames = expectedHex.map((h) => Frame.decode(_unhex(h))).toList();
        expect(frames.map((f) => _hex(f.encode())), expectedHex);
      });

      test('$name reassembles to one message', () {
        final clock = Duration.zero;
        final reassembler = Reassembler(clock: () => clock);

        ReassembledMessage? completed;
        for (final hex in expectedHex) {
          completed = reassembler.offer(Frame.decode(_unhex(hex))) ?? completed;
        }

        expect(completed, isNotNull, reason: 'fragments must reassemble');
        expect(completed!.payload, hasLength(vector['payloadLength']));
      });
    }
  });

  group('relay decision vectors', () {
    final data = _load('testvectors/relay/decisions.json');
    final vectors = (data['vectors']! as List).cast<Map<String, Object?>>();

    test('the vector file is not empty', () => expect(vectors, isNotEmpty));

    for (final vector in vectors) {
      final name = vector['name']! as String;

      test(name, () {
        final localHash = vector['localHash']! as int;
        final input = vector['input']! as Map<String, Object?>;
        final expected = vector['expect']! as Map<String, Object?>;
        final priorSeen = (vector['priorSeen']! as List)
            .cast<Map<String, Object?>>();

        final clock = Duration.zero;
        final dedup = DedupSet(clock: () => clock);
        for (final seen in priorSeen) {
          dedup.addIfNew(
            FrameKey(
              MsgId.fromHex(seen['msgId']! as String),
              int.parse(seen['fragmentIndex']! as String),
            ),
          );
        }

        final engine = RelayEngine(
          localHash: localHash,
          clock: () => clock,
          jitter: (min, max) => min,
          dedup: dedup,
        );

        final frame = Frame.decode(_unhex(input['encodedHex']! as String));
        final decision = engine.receive(
          frame,
          fromPeer: input['fromPeer']! as String,
        );

        expect(
          decision.deliverLocally,
          expected['deliverLocally'],
          reason: 'deliverLocally mismatch for $name',
        );
        expect(
          decision.relayFrame != null,
          expected['relay'],
          reason: 'relay mismatch for $name',
        );
        expect(
          decision.drop?.name,
          expected['drop'],
          reason: 'drop reason mismatch for $name',
        );

        if (expected['relayTtl'] != null) {
          expect(decision.relayFrame!.ttl, expected['relayTtl']);
        }
      });
    }
  });
}
