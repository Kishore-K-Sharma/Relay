import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'nostr_crypto.dart';
import 'nostr_event.dart';

/// A frame recovered from a gift wrap, and who really sent it.
class UnwrappedFrame {
  const UnwrappedFrame({required this.frame, required this.senderPubkey});

  final Uint8List frame;

  /// The sender's real key, taken from the *seal* rather than the wrap. The
  /// wrap is signed by a throwaway key and says nothing about who sent it.
  final String senderPubkey;
}

/// NIP-59 gift wrapping, carrying mesh frames instead of chat messages.
///
/// Three layers, each doing one job:
///
///  - the **rumor** is the frame itself, unsigned, so that a leaked rumor is
///    not proof of authorship;
///  - the **seal** is the rumor encrypted to the recipient and signed by the
///    sender's real key, so the recipient knows who it is from;
///  - the **wrap** is the seal encrypted and signed under a key generated for
///    this one message, so a relay operator sees only an unlinkable event
///    addressed to someone.
///
/// Skipping the wrap would publish a full social graph to every relay: who
/// talks to whom, and how often. That is precisely the metadata this app exists
/// to avoid producing.
class GiftWrap {
  const GiftWrap._();

  /// Kind for a frame rumor. Above 30000 keeps it out of the ranges relays
  /// treat specially, and it never appears in the clear anyway.
  static const int kindFrame = 30078;

  /// Wraps [frame] for [recipientPubkey].
  ///
  /// [now] is passed in rather than read so the timestamp jitter below is
  /// testable; a fixed clock would otherwise make the test assert nothing.
  static Future<NostrEvent> seal({
    required Uint8List frame,
    required NostrKeyPair sender,
    required String recipientPubkey,
    required DateTime now,
    Random? random,
  }) async {
    final rng = random ?? Random.secure();

    final rumor = jsonEncode({
      'kind': kindFrame,
      'created_at': now.millisecondsSinceEpoch ~/ 1000,
      'pubkey': sender.publicKeyHex,
      'content': base64Encode(frame),
      'tags': const <List<String>>[],
    });

    final sealEvent = await signEvent(
      keys: sender,
      // Randomised backwards, as NIP-59 requires. A truthful timestamp on the
      // seal would let a relay correlate wrapped events by when they were
      // made, undoing the unlinkability the wrap provides.
      createdAt: _jitteredTimestamp(now, rng),
      kind: 13,
      tags: const [],
      content: nip44Encrypt(
        rumor,
        conversationKey(sender.privateKeyHex, recipientPubkey),
        random: rng,
      ),
      random: rng,
    );

    final wrapper = NostrKeyPair.ephemeral(rng);

    return signEvent(
      keys: wrapper,
      createdAt: _jitteredTimestamp(now, rng),
      kind: NostrEvent.kindGiftWrap,
      tags: [
        ['p', recipientPubkey],
      ],
      content: nip44Encrypt(
        jsonEncode(sealEvent.toJson()),
        conversationKey(wrapper.privateKeyHex, recipientPubkey),
        random: rng,
      ),
      random: rng,
    );
  }

  /// Unwraps an event addressed to us.
  ///
  /// Returns null for anything that is not a gift wrap we can open, which is
  /// most of what a public relay will hand back.
  static Future<UnwrappedFrame?> open({
    required NostrEvent wrap,
    required NostrKeyPair recipient,
  }) async {
    if (wrap.kind != NostrEvent.kindGiftWrap) return null;
    if (!verifyEvent(wrap)) return null;

    try {
      final sealJson = nip44Decrypt(
        wrap.content,
        conversationKey(recipient.privateKeyHex, wrap.pubkey),
      );

      final sealEvent = NostrEvent.fromJson(jsonDecode(sealJson));
      if (sealEvent == null || sealEvent.kind != 13) return null;

      // The seal must be genuinely signed. Without this check anyone could
      // wrap a seal claiming any sender they liked.
      if (!verifyEvent(sealEvent)) return null;

      final rumorJson = nip44Decrypt(
        sealEvent.content,
        conversationKey(recipient.privateKeyHex, sealEvent.pubkey),
      );

      final rumor = jsonDecode(rumorJson);
      if (rumor is! Map) return null;
      if (rumor['kind'] != kindFrame) return null;

      // A rumor claiming a different author than the seal that carried it is
      // an impersonation attempt, not a parsing quirk.
      if (rumor['pubkey'] != sealEvent.pubkey) return null;

      final content = rumor['content'];
      if (content is! String) return null;

      return UnwrappedFrame(
        frame: Uint8List.fromList(base64Decode(content)),
        senderPubkey: sealEvent.pubkey,
      );
    } on NostrCryptoException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// A timestamp moved randomly up to two days into the past, per NIP-59.
  static int _jitteredTimestamp(DateTime now, Random random) =>
      now.millisecondsSinceEpoch ~/ 1000 - random.nextInt(2 * 24 * 60 * 60);
}
