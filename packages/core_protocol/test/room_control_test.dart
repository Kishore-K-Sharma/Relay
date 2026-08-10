import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// The claims a room's owner can make.
///
/// Every one of these is *advisory*. A room's only real access control is its
/// code, and anyone holding it can ignore every claim in this file. The tests
/// below check that the bytes survive a round trip and that malformed input is
/// refused; they do not, and cannot, check that anybody obeys them.
void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final other = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  final signature = Uint8List.fromList(List.generate(64, (i) => i * 3 % 256));

  RoomControl claim() => RoomControl(
    kind: RoomControlKind.claim,
    ownerKey: key,
    issuedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    signature: signature,
  );

  test('a claim survives a round trip', () {
    final decoded = RoomControl.decode(claim().encode())!;

    expect(decoded.kind, RoomControlKind.claim);
    expect(decoded.ownerKey, key);
    expect(decoded.signature, signature);
    expect(decoded.issuedAt, claim().issuedAt);
  });

  test('a transfer names the new owner', () {
    final control = RoomControl(
      kind: RoomControlKind.transfer,
      ownerKey: key,
      newOwnerKey: other,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
      signature: signature,
    );

    final decoded = RoomControl.decode(control.encode())!;

    expect(decoded.kind, RoomControlKind.transfer);
    expect(decoded.newOwnerKey, other);
  });

  test('a retention setting survives a round trip', () {
    final control = RoomControl(
      kind: RoomControlKind.retention,
      ownerKey: key,
      retain: false,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
      signature: signature,
    );

    expect(RoomControl.decode(control.encode())!.retain, isFalse);
  });

  test('what is signed excludes the signature itself', () {
    // Otherwise there is nothing a signature could be computed over, and the
    // two devices would disagree about the bytes.
    final signed = claim().signedBytes();
    final encoded = claim().encode();

    expect(signed.length, encoded.length - RoomControl.signatureLength);
    expect(encoded.sublist(signed.length), signature);
  });

  test('the same claim signs the same bytes on both devices', () {
    expect(claim().signedBytes(), claim().signedBytes());
  });

  test('a different owner signs different bytes', () {
    final mine = claim().signedBytes();
    final theirs = RoomControl(
      kind: RoomControlKind.claim,
      ownerKey: other,
      issuedAt: claim().issuedAt,
      signature: signature,
    ).signedBytes();

    expect(mine, isNot(theirs));
  });

  test('a transfer signs over the new owner too', () {
    // Without this a signed transfer could be redirected to anyone.
    final toOther = RoomControl(
      kind: RoomControlKind.transfer,
      ownerKey: key,
      newOwnerKey: other,
      issuedAt: claim().issuedAt,
      signature: signature,
    );
    final toSelf = RoomControl(
      kind: RoomControlKind.transfer,
      ownerKey: key,
      newOwnerKey: key,
      issuedAt: claim().issuedAt,
      signature: signature,
    );

    expect(toOther.signedBytes(), isNot(toSelf.signedBytes()));
  });

  test('a retention setting signs over the value', () {
    final on = RoomControl(
      kind: RoomControlKind.retention,
      ownerKey: key,
      retain: true,
      issuedAt: claim().issuedAt,
      signature: signature,
    );
    final off = RoomControl(
      kind: RoomControlKind.retention,
      ownerKey: key,
      retain: false,
      issuedAt: claim().issuedAt,
      signature: signature,
    );

    expect(on.signedBytes(), isNot(off.signedBytes()));
  });

  group('refuses malformed input', () {
    test('an empty payload', () {
      expect(RoomControl.decode(Uint8List(0)), isNull);
    });

    test('a truncated payload', () {
      final bytes = claim().encode();
      expect(RoomControl.decode(bytes.sublist(0, bytes.length - 1)), isNull);
    });

    test('an unknown kind', () {
      final bytes = claim().encode();
      bytes[0] = 0x7F;

      expect(RoomControl.decode(bytes), isNull);
    });

    test('a transfer with no new owner', () {
      final bytes = claim().encode();
      bytes[0] = RoomControlKind.transfer.wireValue;

      expect(RoomControl.decode(bytes), isNull);
    });
  });
}
