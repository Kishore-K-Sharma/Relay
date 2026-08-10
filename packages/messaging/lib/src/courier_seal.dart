import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_protocol/core_protocol.dart';

/// Sealing and unsealing envelopes handed to strangers.
///
/// Two independent things happen here, and it matters that they are separate.
/// The **seal** is one-way Noise X: only the recipient can read the contents,
/// and they learn who wrote it. The **tag** is a rotating hint that lets a
/// courier work out whether it is carrying something for the person standing in
/// front of it, *without* learning who that is unless it already knows their
/// key.
abstract final class CourierSeal {
  /// Builds an envelope for somebody who is not here.
  static Future<CourierEnvelope> build({
    required Uint8List senderNoisePrivate,
    required Uint8List recipientNoiseStatic,
    required Uint8List payload,
    required DateTime now,
    Duration lifetime = CourierEnvelope.maxLifetime,
    int copies = 1,
  }) async {
    final sealed = await NoiseX.seal(
      senderPrivate: senderNoisePrivate,
      recipientStatic: recipientNoiseStatic,
      payload: payload,
    );

    final capped = lifetime > CourierEnvelope.maxLifetime
        ? CourierEnvelope.maxLifetime
        : lifetime;

    return CourierEnvelope(
      recipientTag: await tagFor(
        recipientNoiseStatic,
        day: CourierEnvelope.epochDay(now),
      ),
      expiresAt: now.add(capped).millisecondsSinceEpoch,
      ciphertext: sealed,
      copies: copies,
    );
  }

  /// Opens an envelope addressed to us, or null if it is not.
  static Future<({Uint8List senderStatic, Uint8List payload})?> open({
    required Uint8List recipientNoisePrivate,
    required CourierEnvelope envelope,
  }) => NoiseX.open(
    recipientPrivate: recipientNoisePrivate,
    sealed: envelope.ciphertext,
  );

  /// The rotating hint for a recipient on a given day.
  ///
  /// Keyed on the recipient's static key, so it is computable only by somebody
  /// who already knows who they are. Because it changes daily, two envelopes
  /// for the same person on different days cannot be linked by an observer who
  /// does not.
  static Future<Uint8List> tagFor(
    Uint8List recipientNoiseStatic, {
    required int day,
  }) async {
    final mac = await hmacBlake2s(
      recipientNoiseStatic,
      CourierEnvelope.tagInput(day),
    );
    return Uint8List.sublistView(mac, 0, CourierEnvelope.tagLength);
  }

  /// The tags to test when deciding whether mail is for somebody.
  ///
  /// Yesterday, today and tomorrow, because an envelope sealed just before
  /// midnight — or on a phone whose clock is out — must still be recognised
  /// while it is being carried.
  static Future<List<Uint8List>> candidateTags(
    Uint8List recipientNoiseStatic, {
    required DateTime now,
  }) async => [
    for (final day in CourierEnvelope.candidateDays(now))
      await tagFor(recipientNoiseStatic, day: day),
  ];
}
