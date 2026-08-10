import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What an owner is claiming.
enum RoomControlKind {
  /// "This room is mine." First one wins; see [RoomControl] for why that is
  /// weaker than it sounds.
  claim(0x01),

  /// "It is theirs now."
  transfer(0x02),

  /// "Messages here should not be kept."
  retention(0x03);

  const RoomControlKind(this.wireValue);

  final int wireValue;

  static RoomControlKind? fromWire(int value) {
    for (final kind in RoomControlKind.values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

/// A signed statement by a room's owner.
///
/// **These are advisory and the code says so on purpose.** A room's only real
/// access control is its code: everyone who has it can read, write, and run a
/// build that ignores every claim here. Ownership buys a convention — one
/// person is understood to run the room, other apps show it, and a retention
/// request is honoured by well-behaved clients. It buys nothing against someone
/// who does not want to honour it, and the UI must never suggest otherwise.
///
/// What the signature *does* achieve is that nobody can forge a claim in
/// somebody else's name, and a transfer cannot be redirected in flight. Those
/// are worth having on their own.
@immutable
class RoomControl {
  const RoomControl({
    required this.kind,
    required this.ownerKey,
    required this.issuedAt,
    required this.signature,
    this.newOwnerKey,
    this.retain = true,
  });

  final RoomControlKind kind;

  /// The Ed25519 identity key of whoever is claiming.
  final Uint8List ownerKey;

  /// Only on a [RoomControlKind.transfer].
  final Uint8List? newOwnerKey;

  /// Only meaningful on a [RoomControlKind.retention].
  final bool retain;

  /// When the owner made the claim, by their clock.
  ///
  /// Signed over, so a captured claim cannot be replayed as a newer one — the
  /// receiver keeps the newest it has seen and ignores anything older.
  final DateTime issuedAt;

  final Uint8List signature;

  static const int keyLength = 32;
  static const int signatureLength = 64;

  /// kind + retain + 8-byte timestamp + owner key.
  static const int _bodyLength = 1 + 1 + 8 + keyLength;

  /// Exactly the bytes a signature covers.
  ///
  /// The signature itself is excluded, or there would be nothing to compute it
  /// over. Everything that changes the meaning of the claim is included: the
  /// kind, the retention value, the timestamp, the owner, and the new owner on
  /// a transfer — without that last one a signed transfer could be redirected
  /// to anybody in flight.
  Uint8List signedBytes() {
    final withNewOwner = kind == RoomControlKind.transfer;
    final out = Uint8List(_bodyLength + (withNewOwner ? keyLength : 0));
    out[0] = kind.wireValue;
    out[1] = retain ? 1 : 0;
    ByteData.view(
      out.buffer,
    ).setUint64(2, issuedAt.millisecondsSinceEpoch, Endian.big);
    out.setRange(10, 10 + keyLength, ownerKey);
    if (withNewOwner) {
      out.setRange(
        _bodyLength,
        out.length,
        newOwnerKey ?? Uint8List(keyLength),
      );
    }
    return out;
  }

  Uint8List encode() {
    final body = signedBytes();
    return Uint8List(body.length + signatureLength)
      ..setRange(0, body.length, body)
      ..setRange(body.length, body.length + signatureLength, signature);
  }

  /// Reads a control message, or null if the bytes are not one.
  ///
  /// Null rather than an exception: this is attacker-chosen input arriving on
  /// the inbound path, and one dropped frame is the right cost for a bad one.
  static RoomControl? decode(Uint8List bytes) {
    if (bytes.length < _bodyLength + signatureLength) return null;

    final kind = RoomControlKind.fromWire(bytes[0]);
    if (kind == null) return null;

    final withNewOwner = kind == RoomControlKind.transfer;
    final expected =
        _bodyLength + (withNewOwner ? keyLength : 0) + signatureLength;
    if (bytes.length != expected) return null;

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

    return RoomControl(
      kind: kind,
      retain: bytes[1] != 0,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(
        view.getUint64(2, Endian.big),
        isUtc: true,
      ),
      ownerKey: Uint8List.fromList(bytes.sublist(10, 10 + keyLength)),
      newOwnerKey: withNewOwner
          ? Uint8List.fromList(
              bytes.sublist(_bodyLength, _bodyLength + keyLength),
            )
          : null,
      signature: Uint8List.fromList(
        bytes.sublist(bytes.length - signatureLength),
      ),
    );
  }
}
