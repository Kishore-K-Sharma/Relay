import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport_nostr/transport_nostr.dart';

final alice = NostrKeyPair.fromPrivateHex('0a' * 32);
final bob = NostrKeyPair.fromPrivateHex('0b' * 32);
final eve = NostrKeyPair.fromPrivateHex('0e' * 32);

final now = DateTime.utc(2026, 7, 26, 12);

Uint8List frame() => Uint8List.fromList(List.generate(60, (i) => i));

Future<NostrEvent> wrapForBob({Random? random}) => GiftWrap.seal(
  frame: frame(),
  sender: alice,
  recipientPubkey: bob.publicKeyHex,
  now: now,
  random: random,
);

void main() {
  test('the recipient recovers the frame', () async {
    final unwrapped = await GiftWrap.open(
      wrap: await wrapForBob(),
      recipient: bob,
    );

    expect(unwrapped!.frame, frame());
  });

  test('the recipient learns who really sent it', () async {
    final unwrapped = await GiftWrap.open(
      wrap: await wrapForBob(),
      recipient: bob,
    );

    // From the seal, not the wrap. The wrap is signed by a throwaway key.
    expect(unwrapped!.senderPubkey, alice.publicKeyHex);
  });

  test('the wrap does not name the sender', () async {
    final wrap = await wrapForBob();

    // This is the whole point. If the outer event named Alice, every relay
    // would hold a complete record of who talks to whom.
    expect(wrap.pubkey, isNot(alice.publicKeyHex));
    expect(jsonEncode(wrap.toJson()), isNot(contains(alice.publicKeyHex)));
  });

  test('the wrap does name the recipient, and only the recipient', () async {
    final wrap = await wrapForBob();

    // Unavoidable: a relay has to know who to deliver it to. It is the one
    // piece of metadata this design cannot hide, and it is worth stating.
    expect(wrap.tag('p'), bob.publicKeyHex);
  });

  test('two wraps of the same frame look unrelated', () async {
    final first = await wrapForBob();
    final second = await wrapForBob();

    expect(first.pubkey, isNot(second.pubkey));
    expect(first.content, isNot(second.content));
  });

  test('the wrap timestamp is not the real one', () async {
    final wrap = await wrapForBob(random: Random(7));

    // NIP-59 requires backdating up to two days, so a relay cannot correlate
    // wrapped events by when they were created.
    expect(
      wrap.createdAt,
      lessThanOrEqualTo(now.millisecondsSinceEpoch ~/ 1000),
    );
  });

  test('someone else cannot open it', () async {
    expect(
      await GiftWrap.open(wrap: await wrapForBob(), recipient: eve),
      isNull,
    );
  });

  test('a wrap with a tampered signature is refused', () async {
    final wrap = await wrapForBob();
    final forged = NostrEvent(
      id: wrap.id,
      pubkey: wrap.pubkey,
      createdAt: wrap.createdAt,
      kind: wrap.kind,
      tags: wrap.tags,
      content: wrap.content,
      sig: '00' * 64,
    );

    expect(await GiftWrap.open(wrap: forged, recipient: bob), isNull);
  });

  test('an ordinary note is ignored rather than misread', () async {
    final note = await signEvent(
      keys: alice,
      createdAt: 1700000000,
      kind: 1,
      tags: const [],
      content: 'hello world',
    );

    expect(await GiftWrap.open(wrap: note, recipient: bob), isNull);
  });

  test('a seal claiming an author it did not sign for is refused', () async {
    // Eve wraps a seal she made, but writes Alice's key inside the rumor.
    final rumor = jsonEncode({
      'kind': GiftWrap.kindFrame,
      'created_at': 1700000000,
      'pubkey': alice.publicKeyHex,
      'content': base64Encode(frame()),
      'tags': const <List<String>>[],
    });

    final seal = await signEvent(
      keys: eve,
      createdAt: 1700000000,
      kind: 13,
      tags: const [],
      content: nip44Encrypt(
        rumor,
        conversationKey(eve.privateKeyHex, bob.publicKeyHex),
      ),
    );

    final wrapper = NostrKeyPair.ephemeral();
    final wrap = await signEvent(
      keys: wrapper,
      createdAt: 1700000000,
      kind: NostrEvent.kindGiftWrap,
      tags: [
        ['p', bob.publicKeyHex],
      ],
      content: nip44Encrypt(
        jsonEncode(seal.toJson()),
        conversationKey(wrapper.privateKeyHex, bob.publicKeyHex),
      ),
    );

    // Bob must not be told this came from Alice.
    expect(await GiftWrap.open(wrap: wrap, recipient: bob), isNull);
  });

  test('a large frame survives the round trip', () async {
    final big = Uint8List.fromList(List.generate(4000, (i) => i % 256));

    final unwrapped = await GiftWrap.open(
      wrap: await GiftWrap.seal(
        frame: big,
        sender: alice,
        recipientPubkey: bob.publicKeyHex,
        now: now,
      ),
      recipient: bob,
    );

    expect(unwrapped!.frame, big);
  });
}
