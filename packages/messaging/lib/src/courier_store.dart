import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';

/// How much of this device's storage a depositor is entitled to.
///
/// Carrying somebody's mail costs storage, battery and — if the envelope is
/// ever inspected — a small amount of deniability. The tiers exist so that
/// generosity to strangers can never crowd out mail from people the user
/// actually chose.
enum CourierTier {
  /// Somebody the user marked a favourite.
  favourite,

  /// Somebody verified in person but not chosen. Gets a smaller share, and is
  /// evicted first when space runs out.
  verified,
}

/// Somebody else's mail, held on this device until it can be handed on.
///
/// The policy here is entirely about **refusing** things. An unbounded courier
/// store is a free disk-filling attack on every phone in range, and an
/// unbounded copy budget turns one envelope into a broadcast storm. Every limit
/// below exists because its absence is exploitable by anybody standing nearby.
class CourierStore {
  CourierStore({required LocalStore store, DateTime Function()? clock})
    : _store = store,
      _clock = clock ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _clock;

  /// Total envelopes carried for everybody.
  static const int maxEnvelopes = 40;

  /// Of which this many may be from merely-verified people. Their mail can
  /// never fill the store and lock out a favourite's.
  static const int maxVerifiedEnvelopes = 20;

  static const int maxPerFavourite = 5;
  static const int maxPerVerified = 2;

  int get count => _store.courieredCount;

  /// Throws nothing away silently: returns how many expired envelopes went.
  int pruneExpired() => _store.expireCouriered(_clock());

  /// Throws away everything held for other people. Returns how many went.
  ///
  /// The user's own messages are in a different table and are untouched.
  int dropAll() => _store.dropCouriered();

  /// Takes an envelope from [depositor], or refuses it.
  ///
  /// Returns false whenever a quota, a deadline or a validity check says no.
  /// The caller decides *whether somebody is allowed to ask*; this decides
  /// whether there is room.
  bool deposit(
    CourierEnvelope envelope, {
    required Uint8List depositor,
    CourierTier tier = CourierTier.favourite,
  }) {
    final now = _clock();
    if (envelope.recipientTag.length != CourierEnvelope.tagLength) return false;
    if (envelope.ciphertext.isEmpty ||
        envelope.ciphertext.length > CourierEnvelope.maxCiphertextBytes) {
      return false;
    }
    if (envelope.isExpiredAt(now)) return false;

    // A depositor does not get to pin storage for longer than the app would
    // have kept retrying the message itself.
    final ceiling = now
        .add(CourierEnvelope.maxLifetime)
        .add(CourierEnvelope.expirySlack);
    if (envelope.expiresAt > ceiling.millisecondsSinceEpoch) return false;

    pruneExpired();
    final held = _store.couriered();

    // Same ciphertext means the same envelope, however it arrived. Before any
    // spray a carry-only copy can legitimately turn up ahead of the original,
    // so the larger budget wins — but once this branch has sprayed, replaying
    // the depositor's packet must never refill it. That would defeat
    // spray-and-wait entirely and let one envelope run forever.
    for (final existing in held) {
      if (_sameBytes(existing.ciphertext, envelope.ciphertext)) {
        if (existing.sprayedTo.isEmpty && envelope.copies > existing.copies) {
          _save(existing, copies: envelope.copies);
        }
        return true;
      }
    }

    final fromThisDepositor = held
        .where((e) => _sameBytes(e.depositor, depositor))
        .length;
    final perDepositor = tier == CourierTier.favourite
        ? maxPerFavourite
        : maxPerVerified;
    if (fromThisDepositor >= perDepositor) return false;

    if (tier == CourierTier.verified) {
      final verified = held.where((e) => e.tier == tier.name).length;
      if (verified >= maxVerifiedEnvelopes) return false;
    }

    if (held.length >= maxEnvelopes) {
      // Oldest first, and verified-tier mail before a favourite's. A verified
      // deposit never displaces a favourite: when the store holds nothing but
      // favourites' mail, the newcomer is refused instead.
      final victim = held.where((e) => e.tier == CourierTier.verified.name);
      if (victim.isNotEmpty) {
        _store.deleteCouriered(victim.first.ciphertext);
      } else if (tier == CourierTier.favourite) {
        _store.deleteCouriered(held.first.ciphertext);
      } else {
        return false;
      }
    }

    _store.saveCouriered(
      ciphertext: envelope.ciphertext,
      recipientTag: envelope.recipientTag,
      expiresAt: envelope.expiresAt,
      depositor: depositor,
      storedAt: now,
      tier: tier.name,
      copies: envelope.copies,
    );
    return true;
  }

  /// Everything addressed to whoever owns [recipientTags].
  ///
  /// The tags are supplied rather than derived because computing them needs
  /// the recipient's static key and an HMAC, which is `core_crypto`'s job.
  /// Pass the candidates for yesterday, today and tomorrow.
  List<CourierEnvelope> envelopesFor(List<Uint8List> recipientTags) {
    pruneExpired();
    return [
      for (final held in _store.couriered())
        if (recipientTags.any((tag) => _sameBytes(tag, held.recipientTag)))
          CourierEnvelope(
            recipientTag: held.recipientTag,
            expiresAt: held.expiresAt,
            ciphertext: held.ciphertext,
            copies: held.copies,
          ),
    ];
  }

  /// Forgets an envelope once it has demonstrably reached its recipient.
  ///
  /// Called only after the transport accepted it onto the recipient's link.
  /// Deleting on the attempt rather than the acceptance would drop mail on a
  /// dropped connection, which is exactly when carrying it mattered.
  void delivered(CourierEnvelope envelope) =>
      _store.deleteCouriered(envelope.ciphertext);

  /// Copies to hand to another courier we have just met.
  ///
  /// Binary spray: each gets half the remaining budget, and this device keeps
  /// the rest. Skipped are envelopes that courier deposited, envelopes
  /// addressed *to* them — those go by the delivery path — carry-only
  /// envelopes, and anyone already sprayed.
  List<CourierEnvelope> spraysFor(
    Uint8List courierKey, {
    required List<Uint8List> courierTags,
  }) {
    pruneExpired();
    final key = _hex(courierKey);

    return [
      for (final held in _store.couriered())
        if (held.copies > 1 &&
            !_sameBytes(held.depositor, courierKey) &&
            !held.sprayedTo.contains(key) &&
            !courierTags.any((tag) => _sameBytes(tag, held.recipientTag)))
          CourierEnvelope(
            recipientTag: held.recipientTag,
            expiresAt: held.expiresAt,
            ciphertext: held.ciphertext,
            copies: held.copies ~/ 2,
          ),
    ];
  }

  /// Commits a spray after the other courier actually took it.
  ///
  /// Two-phase on purpose. Halving the budget before the handover succeeds
  /// would lose copies to every failed connection, and a mesh is mostly failed
  /// connections.
  bool sprayed(CourierEnvelope copy, {required Uint8List courierKey}) {
    final key = _hex(courierKey);

    for (final held in _store.couriered()) {
      if (!_sameBytes(held.ciphertext, copy.ciphertext)) continue;
      // Re-checked rather than assumed: another handover may have won the race
      // while this one was out on the radio.
      if (held.copies <= copy.copies) return false;
      if (held.sprayedTo.contains(key)) return false;

      _save(
        held,
        copies: held.copies - copy.copies,
        sprayedTo: [...held.sprayedTo, key],
      );
      return true;
    }
    return false;
  }

  void _save(
    ({
      Uint8List ciphertext,
      Uint8List recipientTag,
      int expiresAt,
      Uint8List depositor,
      DateTime storedAt,
      String tier,
      int copies,
      List<String> sprayedTo,
    })
    held, {
    int? copies,
    List<String>? sprayedTo,
  }) => _store.saveCouriered(
    ciphertext: held.ciphertext,
    recipientTag: held.recipientTag,
    expiresAt: held.expiresAt,
    depositor: held.depositor,
    storedAt: held.storedAt,
    tier: held.tier,
    copies: copies ?? held.copies,
    sprayedTo: sprayedTo ?? held.sprayedTo,
  );

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
