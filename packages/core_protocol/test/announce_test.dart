import 'dart:convert';
import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

/// The one frame every device sends in the clear.
///
/// It has to stay readable by builds older and newer than this one, because a
/// device that cannot parse an announce cannot see the person sending it at
/// all — there is no second channel to fall back to.
void main() {
  Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

  group('encoding', () {
    test('survives a round trip', () {
      final decoded = Announce.decode(
        Announce(
          nickname: 'Sara',
          identityKey: key(1),
          noiseStaticKey: key(2),
        ).encode(),
      )!;

      expect(decoded.nickname, 'Sara');
      expect(decoded.identityKey, key(1));
      expect(decoded.noiseStaticKey, key(2));
    });

    test('a name in any script survives', () {
      final decoded = Announce.decode(
        Announce(nickname: 'ज़ेहरा', identityKey: key(1)).encode(),
      )!;

      expect(decoded.nickname, 'ज़ेहरा');
    });

    test('a long name is cut on a character boundary', () {
      // Truncating UTF-8 mid-character would put a replacement glyph in
      // somebody's name on every device in range.
      final decoded = Announce.decode(
        Announce(nickname: 'ज़' * 40, identityKey: key(1)).encode(),
      )!;

      expect(utf8.encode(decoded.nickname).length, lessThanOrEqualTo(32));
      expect(decoded.nickname, isNot(contains('�')));
    });

    test('an empty name is allowed', () {
      expect(
        Announce.decode(
          Announce(nickname: '', identityKey: key(1)).encode(),
        )!.nickname,
        isEmpty,
      );
    });

    test('fits a single frame', () {
      expect(
        Announce(
          nickname: 'x' * 40,
          identityKey: key(1),
          noiseStaticKey: key(2),
        ).encode().length,
        lessThanOrEqualTo(maxPayloadLength),
      );
    });
  });

  group('the Noise key', () {
    test('is optional', () {
      final decoded = Announce.decode(
        Announce(nickname: 'Sara', identityKey: key(1)).encode(),
      )!;

      expect(decoded.noiseStaticKey, isNull);
    });

    test('an older announce carrying only an identity still parses', () {
      // Exactly what a build from before couriers puts on the wire. If this
      // stops working, upgrading one phone makes it blind to every other.
      final legacy = Uint8List.fromList([4, ...utf8.encode('Sara'), ...key(1)]);
      final decoded = Announce.decode(legacy)!;

      expect(decoded.nickname, 'Sara');
      expect(decoded.identityKey, key(1));
      expect(decoded.noiseStaticKey, isNull);
    });

    test('is not confused with the identity key', () {
      // The two are different keys for different jobs. Swapping them would
      // seal mail to a signing key and verify signatures against a DH key.
      final decoded = Announce.decode(
        Announce(
          nickname: '',
          identityKey: key(1),
          noiseStaticKey: key(2),
        ).encode(),
      )!;

      expect(decoded.identityKey, isNot(decoded.noiseStaticKey));
    });
  });

  group('refusing input', () {
    test('an empty payload', () {
      expect(Announce.decode(Uint8List(0)), isNull);
    });

    test('a name length that runs off the end', () {
      expect(Announce.decode(Uint8List.fromList([200, 1, 2, 3])), isNull);
    });

    test('a missing identity key', () {
      expect(Announce.decode(Uint8List.fromList([0])), isNull);
    });

    test('a truncated identity key', () {
      expect(
        Announce.decode(Uint8List.fromList([0, ...key(1).take(20)])),
        isNull,
      );
    });

    test('a truncated Noise key', () {
      // Half a key is not a key. Better to see the person without couriering
      // than to seal mail to something that cannot open it.
      final decoded = Announce.decode(
        Uint8List.fromList([0, ...key(1), ...key(2).take(10)]),
      )!;

      expect(decoded.identityKey, key(1));
      expect(decoded.noiseStaticKey, isNull);
    });

    test('trailing bytes from a future revision are ignored', () {
      final decoded = Announce.decode(
        Uint8List.fromList([0, ...key(1), ...key(2), 9, 9, 9]),
      )!;

      expect(decoded.noiseStaticKey, key(2));
    });
  });
}
