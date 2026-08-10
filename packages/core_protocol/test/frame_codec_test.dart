import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length, {int seed = 0}) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) & 0xFF));

Frame _frame({
  FrameType type = FrameType.message,
  int ttl = 7,
  FrameFlags flags = const FrameFlags(),
  int srcHash = 0x11223344,
  int dstHash = 0xAABBCCDD,
  int payloadLength = 32,
}) => Frame(
  type: type,
  ttl: ttl,
  flags: flags,
  msgId: MsgId(_bytes(8, seed: 3)),
  srcHash: srcHash,
  dstHash: dstHash,
  payload: _bytes(payloadLength),
);

void main() {
  group('Frame codec', () {
    test('round-trips a message frame preserving every header field', () {
      final frame = _frame(flags: const FrameFlags(encrypted: true));

      final decoded = Frame.decode(frame.encode());

      expect(decoded.version, protocolVersion);
      expect(decoded.type, FrameType.message);
      expect(decoded.ttl, 7);
      expect(decoded.flags.encrypted, isTrue);
      expect(decoded.msgId, frame.msgId);
      expect(decoded.srcHash, 0x11223344);
      expect(decoded.dstHash, 0xAABBCCDD);
      expect(decoded.payload, frame.payload);
    });

    test('writes a 20-byte header ahead of the payload', () {
      final encoded = _frame(payloadLength: 5).encode();

      expect(encoded.length, frameHeaderLength + 5);
      expect(frameHeaderLength, 20);
    });

    test('places each header field at its documented offset', () {
      final encoded = _frame(
        type: FrameType.voice,
        ttl: 4,
        srcHash: 0x01020304,
        dstHash: 0x05060708,
      ).encode();

      expect(encoded[0], protocolVersion, reason: 'version at offset 0');
      expect(encoded[1], FrameType.voice.wireValue, reason: 'type at offset 1');
      expect(encoded[2], 4, reason: 'ttl at offset 2');
      expect(
        encoded.sublist(4, 12),
        _bytes(8, seed: 3),
        reason: 'msgId at 4..11',
      );
      expect(encoded.sublist(12, 16), [
        0x01,
        0x02,
        0x03,
        0x04,
      ], reason: 'srcHash big-endian at 12..15');
      expect(encoded.sublist(16, 20), [
        0x05,
        0x06,
        0x07,
        0x08,
      ], reason: 'dstHash big-endian at 16..19');
    });

    for (final type in FrameType.values) {
      test('round-trips frame type ${type.name}', () {
        expect(Frame.decode(_frame(type: type).encode()).type, type);
      });
    }

    test('round-trips every flag combination independently', () {
      const combinations = [
        FrameFlags(encrypted: true),
        FrameFlags(fragmented: true),
        FrameFlags(compressed: true),
        FrameFlags(urgent: true),
        FrameFlags(
          encrypted: true,
          fragmented: true,
          compressed: true,
          urgent: true,
        ),
        FrameFlags(),
      ];

      for (final flags in combinations) {
        final decoded = Frame.decode(_frame(flags: flags).encode());
        expect(
          decoded.flags,
          flags,
          reason: 'flags $flags did not survive encoding',
        );
      }
    });

    test('accepts an empty payload', () {
      final decoded = Frame.decode(_frame(payloadLength: 0).encode());

      expect(decoded.payload, isEmpty);
    });

    test('treats a zero destination hash as broadcast', () {
      final decoded = Frame.decode(_frame(dstHash: broadcastHash).encode());

      expect(decoded.isBroadcast, isTrue);
      expect(_frame(dstHash: 0x00000001).isBroadcast, isFalse);
    });
  });

  group('Frame codec rejects malformed input', () {
    test('rejects a buffer shorter than the header', () {
      expect(
        () => Frame.decode(Uint8List(frameHeaderLength - 1)),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('rejects an unknown protocol version', () {
      final encoded = _frame().encode()..[0] = 0x7F;

      expect(
        () => Frame.decode(encoded),
        throwsA(isA<UnsupportedVersionException>()),
      );
    });

    test('rejects an unknown frame type', () {
      final encoded = _frame().encode()..[1] = 0xEE;

      expect(() => Frame.decode(encoded), throwsA(isA<FrameFormatException>()));
    });

    test('rejects a payload larger than the transport can carry', () {
      expect(
        () => _frame(payloadLength: maxPayloadLength + 1).encode(),
        throwsA(isA<FrameFormatException>()),
      );
    });

    test('rejects a ttl above the protocol maximum', () {
      expect(() => _frame(ttl: maxTtl + 1), throwsA(isA<ArgumentError>()));
    });

    test('rejects a negative ttl', () {
      expect(() => _frame(ttl: -1), throwsA(isA<ArgumentError>()));
    });

    test('rejects a message id that is not 8 bytes', () {
      expect(() => MsgId(_bytes(7)), throwsA(isA<ArgumentError>()));
      expect(() => MsgId(_bytes(9)), throwsA(isA<ArgumentError>()));
    });

    test('rejects an address hash outside 32 bits', () {
      expect(
        () => _frame(srcHash: 0x1_0000_0000),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => _frame(dstHash: -1), throwsA(isA<ArgumentError>()));
    });
  });

  group('MsgId', () {
    test('compares and hashes by value, not identity', () {
      expect(MsgId(_bytes(8)), MsgId(_bytes(8)));
      expect(MsgId(_bytes(8)).hashCode, MsgId(_bytes(8)).hashCode);
      expect(MsgId(_bytes(8)), isNot(MsgId(_bytes(8, seed: 1))));
    });

    test('renders as lowercase hex for logs and test vectors', () {
      expect(
        MsgId(Uint8List.fromList([0, 1, 0xAB, 0xFF, 0, 0, 0, 0])).toHex(),
        '0001abff00000000',
      );
    });

    test('parses back from hex', () {
      final id = MsgId(_bytes(8, seed: 9));

      expect(MsgId.fromHex(id.toHex()), id);
    });
  });
}
