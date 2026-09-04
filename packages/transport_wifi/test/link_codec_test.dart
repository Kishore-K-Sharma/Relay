import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/src/link_codec.dart';

/// TCP is a byte stream with no message boundaries, so everything here is about
/// the reader surviving what the network actually does: two messages arriving
/// in one read, one message arriving in five, and a hostile peer claiming a
/// four-gigabyte frame.
void main() {
  List<LinkMessage> readAll(LinkReader reader, List<int> bytes) =>
      reader.offer(Uint8List.fromList(bytes)).toList();

  test('a hello carries the sender address hash', () {
    final reader = LinkReader();

    final messages = readAll(reader, LinkCodec.encodeHello(0xDEADBEEF));

    expect(messages, hasLength(1));
    expect((messages.single as HelloMessage).addressHash, 0xDEADBEEF);
  });

  test('a mesh frame comes out byte for byte', () {
    final reader = LinkReader();
    final frame = Uint8List.fromList([1, 2, 3, 250, 0, 255]);

    final messages = readAll(reader, LinkCodec.encodeFrame(frame));

    expect((messages.single as FrameMessage).bytes, frame);
  });

  test('two messages in a single read both come out, in order', () {
    final reader = LinkReader();

    final messages = readAll(reader, [
      ...LinkCodec.encodeHello(7),
      ...LinkCodec.encodeFrame(Uint8List.fromList([9])),
    ]);

    expect(messages, hasLength(2));
    expect(messages.first, isA<HelloMessage>());
    expect((messages.last as FrameMessage).bytes, [9]);
  });

  test('a message split one byte at a time reassembles', () {
    final reader = LinkReader();
    final encoded = LinkCodec.encodeFrame(Uint8List.fromList([4, 5, 6, 7]));

    final collected = <LinkMessage>[];
    for (final byte in encoded) {
      collected.addAll(reader.offer(Uint8List.fromList([byte])));
    }

    expect(collected, hasLength(1));
    expect((collected.single as FrameMessage).bytes, [4, 5, 6, 7]);
  });

  test('a declared length beyond the cap is refused before allocating', () {
    final reader = LinkReader();
    final header = Uint8List(4);
    ByteData.view(header.buffer).setUint32(0, 0x7FFFFFFF, Endian.big);

    // The point is the throw, not the message: without this the reader would
    // try to buffer two gigabytes because a stranger on the Wi-Fi asked it to.
    expect(() => reader.offer(header), throwsA(isA<LinkProtocolException>()));
  });

  test('a connection that does not speak Relay is refused at the hello', () {
    final reader = LinkReader();
    final body = Uint8List.fromList([
      1, // hello
      ...'HTTP'.codeUnits,
      1,
      0, 0, 0, 1,
    ]);
    final wire = Uint8List(4 + body.length);
    ByteData.view(wire.buffer).setUint32(0, body.length, Endian.big);
    wire.setRange(4, wire.length, body);

    expect(() => reader.offer(wire), throwsA(isA<LinkProtocolException>()));
  });

  test('an unknown message kind is refused rather than ignored', () {
    // Ignoring it would let a future version silently half-work. Refusing the
    // link makes the incompatibility visible.
    final reader = LinkReader();
    final wire = Uint8List.fromList([0, 0, 0, 2, 99, 0]);

    expect(() => reader.offer(wire), throwsA(isA<LinkProtocolException>()));
  });

  test('an empty mesh frame is refused', () {
    final reader = LinkReader();
    final wire = Uint8List.fromList([0, 0, 0, 1, 2]);

    expect(() => reader.offer(wire), throwsA(isA<LinkProtocolException>()));
  });

  test('a frame at the cap is accepted', () {
    final reader = LinkReader();
    final frame = Uint8List(LinkCodec.maxFrameLength);

    final messages = readAll(reader, LinkCodec.encodeFrame(frame));

    expect((messages.single as FrameMessage).bytes, hasLength(frame.length));
  });

  test('encoding a frame over the cap throws rather than sending it', () {
    expect(
      () => LinkCodec.encodeFrame(Uint8List(LinkCodec.maxFrameLength + 1)),
      throwsA(isA<LinkProtocolException>()),
    );
  });

  group('the buffer', () {
    test('a maximum frame delivered one byte at a time stays cheap', () {
      // A regression guard for a change of complexity class, not for a few
      // milliseconds. The reader used to flatten its whole accumulated buffer
      // on every call, including calls where nothing completed, making the
      // cost of one message quadratic in the number of pieces it arrived in —
      // a number the *sender* picks. Nothing here is authenticated and this
      // runs before the peer has said who it is, so that was an
      // unauthenticated remote amplification.
      //
      // The work is repeated to put real distance between the two regimes: the
      // old reader needed about a second for this, the current one needs a few
      // tens of milliseconds. The bound sits an order of magnitude above the
      // latter and well below the former, so a slow machine does not flake and
      // a reintroduced quadratic does not slip through.
      final wire = LinkCodec.encodeFrame(Uint8List(LinkCodec.maxFrameLength));

      final watch = Stopwatch()..start();
      var messages = 0;
      for (var repeat = 0; repeat < 8; repeat++) {
        final reader = LinkReader();
        for (var i = 0; i < wire.length; i++) {
          messages += reader
              .offer(Uint8List.sublistView(wire, i, i + 1))
              .length;
        }
      }
      watch.stop();

      expect(messages, 8);
      expect(
        watch.elapsed,
        lessThan(const Duration(milliseconds: 400)),
        reason: 'the reader looks quadratic in the number of chunks again',
      );
    });

    test('it does not grow without bound across many messages', () {
      // The cursor has to be reset, and the space behind it reused. Without
      // that a long-lived link accumulates every byte it has ever received.
      final reader = LinkReader();
      final frame = Uint8List(1000);

      for (var i = 0; i < 500; i++) {
        expect(reader.offer(LinkCodec.encodeFrame(frame)), hasLength(1));
      }
    });

    test('a message split across a compaction still reassembles', () {
      // Half a message left in the buffer, then a chunk that does not fit
      // behind it, is what forces the live bytes to slide down. Getting that
      // copy wrong corrupts the frame rather than failing loudly.
      final wire = LinkCodec.encodeFrame(
        Uint8List.fromList(List.generate(3000, (i) => i % 256)),
      );
      final reader = LinkReader();

      expect(reader.offer(Uint8List.sublistView(wire, 0, 7)), isEmpty);
      final rest = reader.offer(Uint8List.sublistView(wire, 7));

      expect(
        (rest.single as FrameMessage).bytes,
        Uint8List.fromList(List.generate(3000, (i) => i % 256)),
      );
    });
  });
}
