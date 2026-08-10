import 'dart:typed_data';

import 'identity.dart';

/// How much this device trusts a peer's claimed identity.
enum TrustState {
  /// Seen over the air. The nickname is self-asserted and unproven.
  unverified,

  /// Key pinned after an in-person QR scan.
  verified,

  /// A pinned contact appeared under a different key. Treated as hostile until
  /// a human re-verifies, because this is exactly what an impersonation looks
  /// like.
  keyChanged,
}

/// Outcome of processing a peer observed over the air.
enum ObserveResult { added, updated, ignored, keyChanged }

class Contact {
  Contact({
    required this.publicKey,
    required this.nickname,
    required this.trust,
    this.safetyCode,
    this.pinnedAt,
  });

  final Uint8List publicKey;
  String nickname;
  TrustState trust;
  SafetyCode? safetyCode;
  Duration? pinnedAt;

  bool get isVerified => trust == TrustState.verified;
}

/// In-memory contact list. Persistence is layered on top in the `data` package.
class ContactStore {
  final Map<String, Contact> _byKey = <String, Contact>{};

  static String _id(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  List<Contact> get contacts => _byKey.values.toList(growable: false);

  Contact? lookup(Uint8List publicKey) => _byKey[_id(publicKey)];

  /// Pins a contact after an in-person exchange. This is the only path that
  /// produces [TrustState.verified], and it also clears a previous
  /// [TrustState.keyChanged] flag.
  Future<Contact> pin({
    required Uint8List publicKey,
    required String nickname,
    Uint8List? localKey,
    Duration? at,
  }) async {
    final contact = Contact(
      publicKey: publicKey,
      nickname: nickname,
      trust: TrustState.verified,
      safetyCode: localKey == null
          ? null
          : await SafetyCode.between(localKey, publicKey),
      pinnedAt: at,
    );
    _byKey[_id(publicKey)] = contact;
    return contact;
  }

  /// Records a peer heard over the air.
  ///
  /// A verified contact is never downgraded and its nickname is never
  /// overwritten by an over-the-air claim — otherwise anyone could rename a
  /// trusted contact by broadcasting.
  ObserveResult observe({
    required Uint8List publicKey,
    required String nickname,
    Uint8List? claimsToReplace,
  }) {
    if (claimsToReplace != null) {
      final existing = _byKey[_id(claimsToReplace)];
      if (existing != null &&
          existing.isVerified &&
          _id(claimsToReplace) != _id(publicKey)) {
        existing.trust = TrustState.keyChanged;
        return ObserveResult.keyChanged;
      }
    }

    final existing = _byKey[_id(publicKey)];
    if (existing == null) {
      _byKey[_id(publicKey)] = Contact(
        publicKey: publicKey,
        nickname: nickname,
        trust: TrustState.unverified,
      );
      return ObserveResult.added;
    }

    if (existing.trust == TrustState.verified ||
        existing.trust == TrustState.keyChanged) {
      return ObserveResult.ignored;
    }

    existing.nickname = nickname;
    return ObserveResult.updated;
  }

  void forget(Uint8List publicKey) => _byKey.remove(_id(publicKey));

  /// Drops every contact. Used by panic wipe.
  void clear() => _byKey.clear();
}
