import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A sealed message handed to a stranger to carry.
///
/// The idea: when somebody is out of range, give an encrypted copy to people
/// walking past. They carry it in their pocket, unable to read it, and one of
/// them eventually walks near the recipient and hands it over.
///
/// Two properties make that safe to do.
///
/// **The courier learns nothing.** The ciphertext is one-way sealed to the
/// recipient — the courier is not a party to it — and the only routing
/// information is [recipientTag], which is an HMAC over the recipient's static
/// key and the current day. Somebody who does not already know that key cannot
/// tell who an envelope is for, and because the tag rotates daily, two
/// envelopes for the same person on different days do not correlate.
///
/// **It cannot be used as an amplifier.** [copies] is a spray-and-wait budget:
/// each handover to another courier splits it in half, so an envelope reaches
/// at most [maxCopies] carriers no matter how many devices it passes through.
/// Without that, one envelope would flood every phone in a city.
///
/// The wire format is TLV so that a field added later is skipped rather than
/// fatal — an old build must be able to carry a new envelope opaquely, which is
/// the entire job of a courier.
@immutable
class CourierEnvelope {
  CourierEnvelope({
    required this.recipientTag,
    required this.expiresAt,
    required this.ciphertext,
    int copies = 1,
  }) : copies = copies.clamp(1, maxCopies);

  /// Rotating recipient hint. See [tagLength].
  final Uint8List recipientTag;

  /// Milliseconds since epoch after which any holder must destroy it.
  final int expiresAt;

  /// Opaque to everyone except the recipient.
  final Uint8List ciphertext;

  /// How many further couriers this holder may still hand a copy to.
  ///
  /// 1 means carry-only: deliver it to the recipient, never pass it on.
  final int copies;

  static const int tagLength = 16;

  /// Couriered messages are text. Carrying somebody's voice notes around is a
  /// different and much larger favour to ask of a stranger's storage.
  static const int maxCiphertextBytes = 16 * 1024;

  /// Nobody carries anything longer than this, whatever the envelope claims.
  static const Duration maxLifetime = Duration(hours: 24);

  /// Allowance for the depositor's clock being wrong.
  static const Duration expirySlack = Duration(hours: 1);

  /// The ceiling on the spray budget. This is what stops an envelope becoming
  /// an amplification attack on every phone nearby.
  static const int maxCopies = 8;

  static const int _typeRecipientTag = 0x01;
  static const int _typeExpiry = 0x02;
  static const int _typeCiphertext = 0x03;
  static const int _typeCopies = 0x04;

  bool isExpiredAt(DateTime now) => now.millisecondsSinceEpoch >= expiresAt;

  /// The same envelope with a different remaining budget.
  CourierEnvelope withCopies(int value) => CourierEnvelope(
    recipientTag: recipientTag,
    expiresAt: expiresAt,
    ciphertext: ciphertext,
    copies: value,
  );

  /// Encodes, or null when the envelope could never be valid.
  Uint8List? encode() {
    if (recipientTag.length != tagLength) return null;
    if (ciphertext.isEmpty || ciphertext.length > maxCiphertextBytes) {
      return null;
    }

    final out = BytesBuilder();

    void field(int type, List<int> value) {
      out
        ..addByte(type)
        ..addByte((value.length >> 8) & 0xFF)
        ..addByte(value.length & 0xFF)
        ..add(value);
    }

    field(_typeRecipientTag, recipientTag);
    field(_typeExpiry, [
      for (var shift = 56; shift >= 0; shift -= 8) (expiresAt >> shift) & 0xFF,
    ]);
    field(_typeCiphertext, ciphertext);
    // Omitted when 1, so a carry-only envelope — the common case — stays as
    // small as it can be.
    if (copies > 1) field(_typeCopies, [copies]);

    return out.toBytes();
  }

  /// Reads an envelope, or null if the bytes are not one.
  ///
  /// Null rather than an exception: this is attacker-chosen input, arriving
  /// from somebody who by definition has no relationship with this device.
  static CourierEnvelope? decode(Uint8List bytes) {
    Uint8List? tag;
    int? expiry;
    Uint8List? ciphertext;
    var copies = 1;

    var at = 0;
    while (at < bytes.length) {
      final type = bytes[at];
      at++;
      if (at + 2 > bytes.length) return null;
      final length = (bytes[at] << 8) | bytes[at + 1];
      at += 2;
      if (at + length > bytes.length) return null;
      final value = Uint8List.sublistView(bytes, at, at + length);
      at += length;

      switch (type) {
        case _typeRecipientTag:
          if (length != tagLength) return null;
          tag = Uint8List.fromList(value);
        case _typeExpiry:
          if (length != 8) return null;
          var parsed = 0;
          for (final byte in value) {
            parsed = (parsed << 8) | byte;
          }
          expiry = parsed;
        case _typeCiphertext:
          if (length == 0 || length > maxCiphertextBytes) return null;
          ciphertext = Uint8List.fromList(value);
        case _typeCopies:
          if (length != 1) return null;
          copies = value[0];
        default:
          // Unknown field from a newer build. Skipped on purpose: a courier
          // that refused to carry what it did not understand would stop being
          // useful the first time the format grew.
          continue;
      }
    }

    if (tag == null || expiry == null || ciphertext == null) return null;

    return CourierEnvelope(
      recipientTag: tag,
      expiresAt: expiry,
      ciphertext: ciphertext,
      copies: copies,
    );
  }

  /// The UTC day number a tag is scoped to.
  static int epochDay(DateTime at) =>
      at.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// The message an HMAC is taken over to produce a tag for [day].
  ///
  /// Separated from the HMAC itself so this package keeps no dependency on a
  /// cryptography library; `core_crypto` supplies the key and the hash.
  static Uint8List tagInput(int day) {
    const context = 'relay-courier-tag-v1';
    final out = Uint8List(context.length + 4);
    out.setRange(0, context.length, context.codeUnits);
    for (var i = 0; i < 4; i++) {
      out[context.length + i] = (day >> ((3 - i) * 8)) & 0xFF;
    }
    return out;
  }

  /// The days a tag might have been computed for, given the clock now.
  ///
  /// Yesterday, today and tomorrow. An envelope sealed just before midnight —
  /// or on a phone whose clock is an hour out — must still be recognised while
  /// it is being carried, and the alternative is silently undeliverable mail.
  static List<int> candidateDays(DateTime now) {
    final day = epochDay(now);
    return [if (day > 0) day - 1, day, day + 1];
  }
}
