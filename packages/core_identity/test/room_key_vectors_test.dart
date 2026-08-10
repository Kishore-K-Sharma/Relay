import 'package:core_identity/core_identity.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

/// Room key derivation, checked against the specification and pinned.
///
/// `docs/SECURITY.md` §3 listed this row as "parameters only; **not**
/// vector-tested" — the one primitive in the inventory taking its correctness
/// entirely on trust. Two separate things were unverified and they need
/// different kinds of test:
///
///  1. **Is the Argon2id we call the real Argon2id?** Answered by the RFC 9106
///     known-answer test below, run through `package:cryptography`'s public
///     `Argon2id` class — the same entry point `deriveRoomKey` uses, rather
///     than the internal state object the library tests its own vectors
///     against. A library can be conformant internally and still be wired up
///     wrongly at the surface we happen to call.
///  2. **Does our derivation still produce the keys it produced yesterday?**
///     Answered by pinning real output. A room key is not stored anywhere: it
///     is re-derived from the code on every device that joins. Any drift in the
///     salt, the parameter block or the domain separator silently partitions
///     the room — new joiners derive one key, existing members another, and
///     nobody sees an error, only silence.
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Argon2id is the algorithm the specification describes', () {
    test('RFC 9106 §5.3 known-answer test', () async {
      // The published Argon2id vector: p=4 lanes, m=32 KiB, t=3, 32-byte tag,
      // with the optional secret and associated data both exercised. Getting
      // this right end to end is what distinguishes a real Argon2id from
      // something that merely returns 32 plausible bytes.
      final argon = Argon2id(
        parallelism: 4,
        memory: 32,
        iterations: 3,
        hashLength: 32,
      );

      final derived = await argon.deriveKey(
        secretKey: SecretKey(List<int>.filled(32, 0x01)),
        nonce: List<int>.filled(16, 0x02),
        optionalSecret: List<int>.filled(8, 0x03),
        associatedData: List<int>.filled(12, 0x04),
      );

      expect(
        hex(await derived.extractBytes()),
        '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
      );
    });

    test('the parameters this app uses are the ones documented', () {
      // Pinned separately from the derivation itself. These three numbers are
      // the entire cost of guessing a room code, and lowering one to make a
      // test faster would weaken every room in the field without changing a
      // single assertion about the output.
      expect(roomArgonMemoryKib, 65536, reason: '64 MiB');
      expect(roomArgonIterations, 3);
      expect(roomArgonParallelism, 1);
    });
  });

  group('room key derivation is pinned', () {
    // Derivation costs 64 MiB and roughly half a second by design, so this is
    // deliberately a short list rather than a sweep.
    const vectors = <String, (String key, int roomId)>{
      'ABCDEF': (
        'c267d51413a5e285b2e743555e5be1d9eaabf300580e77797517f58836c213f4',
        3518571577,
      ),
      '234567': (
        '62fe93b1d4d692f4e0c63771e4ed50815dafe3cd9a9ea387b1ed1218df5c5549',
        3161326043,
      ),
    };

    for (final entry in vectors.entries) {
      test('${entry.key} derives the same key it always has', () async {
        final derived = await deriveRoomKey(RoomCode.parse(entry.key));

        expect(hex(derived.key), entry.value.$1);
        expect(derived.roomId, entry.value.$2);
      });
    }

    test('a lowercase code derives the identical key', () async {
      // Codes are read aloud and typed by hand. If case reached the salt, half
      // a crowd would end up in a different room with no error shown.
      final upper = await deriveRoomKey(RoomCode.parse('ABCDEF'));
      final lower = await deriveRoomKey(RoomCode.parse('abcdef'));

      expect(hex(lower.key), hex(upper.key));
      expect(lower.roomId, upper.roomId);
    });

    test('the room id is never zero', () async {
      // Zero is the broadcast address. A room whose id collided with it would
      // send every message to everybody rather than to its members.
      for (final code in ['ABCDEF', '234567', 'ZZZZZZ', 'M2N3P4']) {
        expect(
          (await deriveRoomKey(RoomCode.parse(code))).roomId,
          isNot(0),
          reason: '$code hashed to the broadcast address',
        );
      }
    });

    test('two codes do not share a key', () async {
      final a = await deriveRoomKey(RoomCode.parse('ABCDEF'));
      final b = await deriveRoomKey(RoomCode.parse('ABCDEG'));

      expect(hex(a.key), isNot(hex(b.key)));
    });
  });
}
