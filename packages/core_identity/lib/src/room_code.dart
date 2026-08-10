import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:cryptography/cryptography.dart' hide CipherState;

/// Characters permitted in a room code.
///
/// `0`, `O`, `1`, `I` and `L` are excluded because a room code gets shouted
/// across a noisy field and typed by someone who has had a drink.
const String roomCodeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

const int roomCodeLength = 6;

/// Argon2id parameters, tuned so one derivation costs roughly half a second on
/// a mid-range phone. This raises the cost of guessing the code space; it does
/// not make a 6-character code into a strong secret.
const int roomArgonMemoryKib = 65536; // 64 MiB
const int roomArgonIterations = 3;
const int roomArgonParallelism = 1;

/// A validated group room code.
class RoomCode {
  const RoomCode._(this.value);

  factory RoomCode.parse(String input) {
    final normalised = input.trim().toUpperCase();

    if (normalised.length != roomCodeLength) {
      throw FormatException(
        'a room code is exactly $roomCodeLength characters',
        input,
      );
    }
    for (final char in normalised.split('')) {
      if (!roomCodeAlphabet.contains(char)) {
        throw FormatException('"$char" is not allowed in a room code', input);
      }
    }
    return RoomCode._(normalised);
  }

  factory RoomCode.generate([Random? random]) {
    final rng = random ?? Random.secure();
    return RoomCode._(
      List<String>.generate(
        roomCodeLength,
        (_) => roomCodeAlphabet[rng.nextInt(roomCodeAlphabet.length)],
      ).join(),
    );
  }

  final String value;

  /// Entropy of the code space, in bits.
  static double get entropyBits =>
      roomCodeLength * (log(roomCodeAlphabet.length) / log(2));

  /// Always false, and deliberately part of the public API.
  ///
  /// A room code is a convenience for getting a crowd talking, not a strong
  /// secret: anyone who overhears it reads the room, and room traffic has no
  /// forward secrecy. The join screen must say so in plain words and must not
  /// display the same lock affordance as a verified direct message.
  static bool get isStrongSecret => false;

  @override
  String toString() => value;
}

/// A derived room key and its routing identifier.
class DerivedRoom {
  const DerivedRoom({required this.key, required this.roomId});

  final Uint8List key;

  /// 4-byte address the room's frames are sent to.
  final int roomId;
}

/// Derives the symmetric room key from a code.
Future<DerivedRoom> deriveRoomKey(RoomCode code) async {
  final salt = await blake2s(<int>[
    ...'relay-room-v1'.codeUnits,
    ...code.value.codeUnits,
  ]);

  final argon = Argon2id(
    parallelism: roomArgonParallelism,
    memory: roomArgonMemoryKib,
    iterations: roomArgonIterations,
    hashLength: 32,
  );
  final derived = await argon.deriveKey(
    secretKey: SecretKey(code.value.codeUnits),
    nonce: salt,
  );
  final key = Uint8List.fromList(await derived.extractBytes());

  final idDigest = await blake2s(<int>[...'relay-roomid-v1'.codeUnits, ...key]);
  final roomId = ByteData.view(
    Uint8List.fromList(idDigest).buffer,
  ).getUint32(0, Endian.big);

  return DerivedRoom(key: key, roomId: roomId == 0 ? 1 : roomId);
}
