import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';

/// Envelopes on the wire.
///
/// A courier frame is the one thing this app transmits that neither device
/// involved can read. Everything here is about it being handed over exactly
/// once, to exactly the peer in front of us, and going no further.
class CountingTransport implements Transport {
  final sent = <({Uint8List frame, String? toPeer})>[];
  final _inbound = StreamController<InboundFrame>.broadcast();

  @override
  Stream<InboundFrame> get inbound => _inbound.stream;
  @override
  Stream<PeerEvent> get peerEvents => const Stream.empty();
  @override
  List<TransportPeer> get peers => const [
    TransportPeer(peerId: 'carol', hopDistance: 1),
  ];
  @override
  TransportStatus get status => const TransportStatus(
    running: true,
    adapterOn: true,
    permissionsGranted: true,
    advertising: true,
    scanning: true,
    connectedPeerCount: 1,
  );
  @override
  Stream<TransportStatus> get statusChanges => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> send(
    Uint8List frame, {
    String? toPeer,
    String? excludePeer,
  }) async {
    sent.add((frame: frame, toPeer: toPeer));
  }

  Future<void> dispose() => _inbound.close();
}

const int localHash = 0xAAAA;
const int carolHash = 0xCCCC;

void main() {
  final now = DateTime.utc(2026, 7, 26, 12);

  late LocalStore store;
  late CountingTransport mesh;
  late MessageService service;
  late Uint8List recipientStatic;

  Uint8List secret(int fill) => Uint8List.fromList(List.filled(32, fill));

  setUp(() async {
    recipientStatic = await publicKeyOf(secret(2));
    store = LocalStore.open();
    mesh = CountingTransport();
    service = MessageService(
      store: store,
      router: TransportRouter(mesh: mesh),
      sessions: SessionManager(
        staticPrivateKey: secret(1),
        localAddressHash: localHash,
      ),
      senderKey: Uint8List.fromList([1, 2, 3, 4]),
      localAddressHash: localHash,
      clock: () => now,
      random: Random(42),
    );
  });

  tearDown(() async {
    await service.dispose();
    await mesh.dispose();
    store.close();
  });

  Future<CourierEnvelope> envelope({int copies = 1}) => CourierSeal.build(
    senderNoisePrivate: secret(1),
    recipientNoiseStatic: recipientStatic,
    payload: Uint8List.fromList('bring water'.codeUnits),
    now: now,
    copies: copies,
  );

  group('sending', () {
    test('an envelope goes out as a courier frame', () async {
      expect(
        await service.sendCourier(
          await envelope(),
          toPeer: 'carol',
          peerHash: carolHash,
        ),
        isTrue,
      );

      final frame = Frame.decode(mesh.sent.single.frame);
      expect(frame.type, FrameType.courier);
      expect(mesh.sent.single.toPeer, 'carol');
    });

    test('it is addressed to the courier, not the recipient', () async {
      // The whole reason it is being carried is that nobody knows how to
      // address the recipient. The frame goes to the person taking it.
      await service.sendCourier(
        await envelope(),
        toPeer: 'carol',
        peerHash: carolHash,
      );

      expect(Frame.decode(mesh.sent.single.frame).dstHash, carolHash);
    });

    test('it travels exactly one hop', () async {
      // Flooding an envelope would replicate it outside the spray budget,
      // which is the only thing bounding how much of the mesh one message
      // consumes. It would also be pointless: a mesh that can reach the
      // recipient does not need a courier.
      await service.sendCourier(
        await envelope(),
        toPeer: 'carol',
        peerHash: carolHash,
      );

      expect(Frame.decode(mesh.sent.single.frame).ttl, 1);
    });

    test('the frame does not claim to be encrypted', () async {
      // The body is sealed, but the tag, expiry and copy count are in the
      // clear so a carrier can act on them. Setting the flag would be a lie
      // about the envelope's header.
      await service.sendCourier(
        await envelope(),
        toPeer: 'carol',
        peerHash: carolHash,
      );

      expect(Frame.decode(mesh.sent.single.frame).flags.encrypted, isFalse);
    });

    test('the payload is the envelope, readable by the carrier', () async {
      // Deliberate: a courier must be able to see the tag to know whether it
      // is worth carrying, and the expiry to know when to drop it.
      final original = await envelope(copies: 4);
      await service.sendCourier(original, toPeer: 'carol', peerHash: carolHash);

      final decoded = CourierEnvelope.decode(
        Frame.decode(mesh.sent.single.frame).payload,
      )!;
      expect(decoded.recipientTag, original.recipientTag);
      expect(decoded.copies, 4);
      expect(decoded.ciphertext, original.ciphertext);
    });

    test('an envelope that will not encode is refused, not sent', () async {
      final broken = CourierEnvelope(
        recipientTag: Uint8List(3),
        expiresAt: now.millisecondsSinceEpoch,
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );

      expect(
        await service.sendCourier(broken, toPeer: 'carol', peerHash: carolHash),
        isFalse,
      );
      expect(mesh.sent, isEmpty);
    });
  });

  group('receiving', () {
    test('an envelope is read back off the wire', () async {
      final original = await envelope(copies: 2);
      await service.sendCourier(original, toPeer: 'carol', peerHash: carolHash);

      final decoded = service.receiveCourier(
        Frame.decode(mesh.sent.single.frame).payload,
      )!;
      expect(decoded.ciphertext, original.ciphertext);
      expect(decoded.copies, 2);
    });

    test('rubbish yields nothing rather than throwing', () {
      // Anyone in range can send this. It must cost one dropped frame.
      expect(service.receiveCourier(Uint8List(0)), isNull);
      expect(service.receiveCourier(Uint8List.fromList([9, 9, 9])), isNull);
    });
  });
}
