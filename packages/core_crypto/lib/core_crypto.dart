/// Noise XX handshake, AEAD sessions and key derivation.
///
/// Pure Dart: no storage, no networking, no platform channels. Every primitive
/// here is verified against published test vectors in `testvectors/crypto/`.
library;

export 'src/noise.dart';
export 'src/primitives.dart';
