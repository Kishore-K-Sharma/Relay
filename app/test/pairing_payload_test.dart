import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/domain/pairing_payload.dart';

Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  test('round-trips', () {
    final original = PairingPayload(
      identityKey: key(1),
      noiseKey: key(2),
      nostrKey: 'ab' * 32,
      nickname: 'Sara',
    );

    final decoded = PairingPayload.decode(original.encode())!;

    expect(decoded.identityKey, key(1));
    expect(decoded.noiseKey, key(2));
    expect(decoded.nostrKey, 'ab' * 32);
    expect(decoded.nickname, 'Sara');
  });

  test('survives a nickname with spaces and accents', () {
    final decoded = PairingPayload.decode(
      PairingPayload(
        identityKey: key(1),
        noiseKey: key(2),
        nostrKey: 'ab' * 32,
        nickname: 'José Ramírez',
      ).encode(),
    )!;

    // The separator is a colon and names contain anything, so the nickname is
    // encoded rather than embedded raw.
    expect(decoded.nickname, 'José Ramírez');
  });

  test('a nickname containing a colon does not corrupt the payload', () {
    final decoded = PairingPayload.decode(
      PairingPayload(
        identityKey: key(1),
        noiseKey: key(2),
        nostrKey: 'ab' * 32,
        nickname: 'a:b:c',
      ).encode(),
    )!;

    expect(decoded.nickname, 'a:b:c');
  });

  test('someone else\'s QR code is ignored, not treated as an error', () {
    // A camera pointed at the world sees wifi codes, ticket codes and URLs
    // constantly. None of them is a failure.
    expect(PairingPayload.decode('https://example.com'), isNull);
    expect(PairingPayload.decode('WIFI:S:cafe;T:WPA;P:hunter2;;'), isNull);
    expect(PairingPayload.decode(''), isNull);
  });

  test('a future version is refused rather than misread', () {
    final ours = PairingPayload(
      identityKey: key(1),
      noiseKey: key(2),
      nostrKey: 'ab' * 32,
      nickname: 'x',
    ).encode();

    expect(PairingPayload.decode(ours.replaceFirst(':1:', ':2:')), isNull);
  });

  test('a truncated key is refused', () {
    expect(PairingPayload.decode('relay:1:AAAA:AAAA:${'ab' * 32}:eA'), isNull);
  });

  test('a relay key that is not a secp256k1 key is refused', () {
    // Feeding junk here would end up in a Nostr filter and simply never match,
    // which reads to the user as messages silently vanishing.
    expect(
      PairingPayload.decode(
        PairingPayload(
          identityKey: key(1),
          noiseKey: key(2),
          nostrKey: 'not-a-key',
          nickname: 'x',
        ).encode(),
      ),
      isNull,
    );
  });

  test('an empty relay key is allowed: the relay is optional', () {
    final decoded = PairingPayload.decode(
      PairingPayload(
        identityKey: key(1),
        noiseKey: key(2),
        nostrKey: '',
        nickname: 'x',
      ).encode(),
    )!;

    expect(decoded.nostrKey, isEmpty);
  });

  test('malformed base64 is refused', () {
    expect(PairingPayload.decode('relay:1:!!!!:!!!!:!!!!:!!!!'), isNull);
  });
}
