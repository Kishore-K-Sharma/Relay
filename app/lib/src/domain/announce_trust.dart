import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:core_protocol/core_protocol.dart';

/// How much of an announce may be believed.
enum AnnounceTrust {
  /// Signed by the identity key it claims. Everything in it is attributable.
  signed,

  /// No signature at all. Usable as evidence that *something* is in range, and
  /// for nothing else.
  unsigned,

  /// A signature that does not verify. Hostile, and dropped whole.
  forged,
}

/// Checks the signature on a received announce.
///
/// An announce is the only frame this app broadcasts in the clear, and every
/// claim in it is acted on: the nickname names a conversation, the identity key
/// decides whether somebody is trusted enough to be handed other people's mail,
/// and the X25519 key is what a courier envelope is sealed to. Unsigned, all
/// three are assertions by whoever happens to be holding a radio — and the last
/// one is the dangerous one, because an identity key is public. Anyone in range
/// could rebroadcast a person's identity key beside their *own* X25519 key and
/// have that person's mail sealed to them. Pinning the contact does not help:
/// verification covers the identity key, and nothing binds the Noise key to it.
///
/// [payload] must be the bytes as they arrived, not a re-encoding of the parse.
/// Verifying a re-serialisation asks "does this match a canonical form" rather
/// than "were these bytes signed", which is a weaker question.
Future<AnnounceTrust> checkAnnounce(
  Announce announce,
  Uint8List payload,
) async {
  final signature = announce.signature;
  final region = Announce.signedRegionOf(payload);
  if (signature == null || region == null) return AnnounceTrust.unsigned;

  try {
    final ok = await verifySignature(
      Announce.signingInput(region),
      signature,
      announce.identityKey,
    );
    return ok ? AnnounceTrust.signed : AnnounceTrust.forged;
  } on Object {
    // A malformed public key throws rather than returning false.
    return AnnounceTrust.forged;
  }
}
