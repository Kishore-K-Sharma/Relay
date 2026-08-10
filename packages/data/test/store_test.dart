import 'dart:io';
import 'dart:typed_data';

import 'package:data/data.dart';
import 'package:test/test.dart';

Uint8List key(int seed) => Uint8List.fromList(List<int>.filled(8, seed));

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore.open();
    store.upsertConversation(
      id: 'c1',
      kind: ConversationKind.direct,
      title: 'Sara',
    );
  });

  tearDown(() => store.close());

  StoredMessage message(
    String id, {
    bool fromMe = true,
    MessageState state = MessageState.queued,
  }) => StoredMessage(
    id: id,
    conversationId: 'c1',
    body: 'hello',
    fromMe: fromMe,
    state: state,
    createdAt: DateTime(2026, 7, 26, 12, 0, int.parse(id.substring(1))),
  );

  group('messages', () {
    test('round-trips a stored message', () {
      store.insertMessage(message('m1'));

      final loaded = store.messages('c1').single;
      expect(loaded.id, 'm1');
      expect(loaded.body, 'hello');
      expect(loaded.state, MessageState.queued);
    });

    test('orders messages oldest first', () {
      store.insertMessage(message('m2'));
      store.insertMessage(message('m1'));

      expect(store.messages('c1').map((m) => m.id), ['m1', 'm2']);
    });

    test('advances state forward', () {
      store.insertMessage(message('m1'));

      store.updateMessageState('m1', MessageState.sent);
      store.updateMessageState('m1', MessageState.delivered);

      expect(store.messages('c1').single.state, MessageState.delivered);
    });

    test('never moves state backwards', () {
      store.insertMessage(message('m1'));
      store.updateMessageState('m1', MessageState.read);

      store.updateMessageState('m1', MessageState.delivered);

      expect(
        store.messages('c1').single.state,
        MessageState.read,
        reason: 'a late delivery receipt must not un-read a message',
      );
    });

    test('allows a terminal failure to override progress', () {
      store.insertMessage(message('m1'));
      store.updateMessageState('m1', MessageState.sent);

      store.updateMessageState('m1', MessageState.expired);

      expect(store.messages('c1').single.state, MessageState.expired);
    });

    test('counts unread only for incoming messages', () {
      store.insertMessage(message('m1', fromMe: false));
      store.insertMessage(message('m2', fromMe: true));

      expect(store.conversations().single.unread, 1);
    });

    test('clears unread when a conversation is read', () {
      store.insertMessage(message('m1', fromMe: false));

      store.markRead('c1');

      expect(store.conversations().single.unread, 0);
      expect(store.messages('c1').single.state, MessageState.read);
    });
  });

  group('a message that was carried by hand', () {
    test('is not what an ordinary message looks like', () {
      // The default has to be "came over the radio". Marking every message as
      // carried would make the label meaningless, which is worse than absent.
      store.insertMessage(message('m1'));

      expect(store.messages('c1').single.viaCourier, isFalse);
    });

    test('is remembered as carried', () {
      // Not derivable after the fact. Once the envelope is opened there is
      // nothing left on the message to say a person walked it across town, and
      // that is the single most surprising thing about how it arrived.
      store.insertMessage(
        StoredMessage(
          id: 'm2',
          conversationId: 'c1',
          body: 'meet at the gate',
          fromMe: false,
          state: MessageState.delivered,
          createdAt: DateTime(2026, 7, 27),
          viaCourier: true,
        ),
      );

      expect(store.messages('c1').single.viaCourier, isTrue);
    });

    test('survives a state change', () {
      // How it arrived does not stop being true when it is marked read.
      store.insertMessage(
        StoredMessage(
          id: 'm3',
          conversationId: 'c1',
          body: 'hello',
          fromMe: false,
          state: MessageState.delivered,
          createdAt: DateTime(2026, 7, 27),
          viaCourier: true,
        ),
      );

      store.markRead('c1');

      expect(store.messages('c1').single.viaCourier, isTrue);
    });
  });

  group('outbox', () {
    OutboxEntry entry(String id, {DateTime? retryAt, DateTime? expiresAt}) =>
        OutboxEntry(
          messageId: id,
          sequence: 1,
          targetHash: 0xAABB,
          payload: Uint8List.fromList([1, 2, 3]),
          attempts: 0,
          nextRetryAt: retryAt ?? DateTime(2026, 1, 1),
          expiresAt: expiresAt ?? DateTime(2027, 1, 1),
        );

    test('returns entries whose retry time has arrived', () {
      store.enqueue(entry('m1', retryAt: DateTime(2026, 1, 1)));
      store.enqueue(entry('m2', retryAt: DateTime(2030, 1, 1)));

      final due = store.dueRetries(DateTime(2026, 6, 1));

      expect(due.map((e) => e.messageId), ['m1']);
    });

    test('backs off exponentially between attempts', () {
      store.enqueue(entry('m1'));
      final now = DateTime(2026, 6, 1);

      store.recordAttempt('m1', now);
      final first = store.dueRetries(DateTime(2026, 12, 31)).single.nextRetryAt;
      store.recordAttempt('m1', now);
      final second = store
          .dueRetries(DateTime(2026, 12, 31))
          .single
          .nextRetryAt;

      expect(second.isAfter(first), isTrue);
    });

    test('caps backoff so a long-absent peer is still retried', () {
      store.enqueue(entry('m1'));
      final now = DateTime(2026, 6, 1);

      for (var i = 0; i < 30; i++) {
        store.recordAttempt('m1', now);
      }

      final next = store.dueRetries(DateTime(2026, 12, 31)).single.nextRetryAt;
      expect(next.difference(now).inSeconds, lessThanOrEqualTo(3600));
    });

    test('marks expired entries as never delivered', () {
      store.insertMessage(message('m1'));
      store.enqueue(entry('m1', expiresAt: DateTime(2026, 1, 2)));

      final expired = store.expireOutbox(DateTime(2026, 6, 1));

      expect(expired, ['m1']);
      expect(store.messages('c1').single.state, MessageState.expired);
      expect(store.outboxDepth, 0);
    });

    test('dequeues on confirmed delivery', () {
      store.enqueue(entry('m1'));

      store.dequeue('m1');

      expect(store.outboxDepth, 0);
    });
  });

  group('cross-transport deduplication', () {
    test('accepts a message once', () {
      expect(store.acceptMessage(key(1), 7), isTrue);
      expect(store.acceptMessage(key(1), 7), isFalse);
    });

    test('distinguishes senders and sequences', () {
      expect(store.acceptMessage(key(1), 1), isTrue);
      expect(store.acceptMessage(key(2), 1), isTrue);
      expect(store.acceptMessage(key(1), 2), isTrue);
    });

    test('survives a reopen when backed by a file', () {
      final dir = Directory.systemTemp.createTempSync('relay_store');
      final path = '${dir.path}/relay.db';

      final first = LocalStore.open(path);
      expect(first.acceptMessage(key(3), 1), isTrue);
      first.close();

      final second = LocalStore.open(path);
      expect(
        second.acceptMessage(key(3), 1),
        isFalse,
        reason:
            'dedup state must outlive a process restart, or a relaunch '
            'would redeliver everything still circulating',
      );
      second.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('contacts', () {
    test('stores and reloads a pinned contact', () {
      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.verified,
        safetyCode: '12345',
      );

      final contact = store.contacts().single;
      expect(contact.nickname, 'Sara');
      expect(contact.trust, TrustState.verified);
    });

    test('updates trust on a key change', () {
      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.verified,
      );

      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.keyChanged,
      );

      expect(store.contacts().single.trust, TrustState.keyChanged);
    });
  });

  group('a contact\'s Noise key', () {
    test('is stored and read back', () {
      store.saveNoiseKey(publicKey: key(1), noiseStaticKey: key(9));

      expect(store.noiseKeyFor(key(1)), key(9));
    });

    test('is absent for somebody who never published one', () {
      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.unverified,
      );

      expect(store.noiseKeyFor(key(1)), isNull);
    });

    test('is absent for a stranger', () {
      expect(store.noiseKeyFor(key(2)), isNull);
    });

    test('can be learned before anything else about the person', () {
      // An announce arrives before any conversation. There may be no contact
      // row yet, and refusing the key until there is would mean never
      // learning it for somebody the user has not spoken to.
      store.saveNoiseKey(publicKey: key(3), noiseStaticKey: key(4));

      expect(store.noiseKeyFor(key(3)), key(4));
    });

    test('survives the person being verified afterwards', () {
      // saveContact lists the columns it updates. If it ever replaced the row
      // instead, verifying somebody would silently stop mail reaching them.
      store.saveNoiseKey(publicKey: key(1), noiseStaticKey: key(9));
      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.verified,
      );

      expect(store.noiseKeyFor(key(1)), key(9));
    });

    test('does not on its own make somebody a contact', () {
      // Overhearing an announce is not a relationship. A bare row here would
      // show up in every name lookup as a contact called "", and an empty
      // search term would match a stranger.
      store.saveNoiseKey(publicKey: key(3), noiseStaticKey: key(4));

      expect(store.contacts(), isEmpty);
    });

    test('is replaced when the person publishes a new one', () {
      store.saveNoiseKey(publicKey: key(1), noiseStaticKey: key(9));
      store.saveNoiseKey(publicKey: key(1), noiseStaticKey: key(8));

      expect(store.noiseKeyFor(key(1)), key(8));
    });
  });

  group('panic wipe', () {
    test('destroys every table', () {
      store.insertMessage(message('m1'));
      store.enqueue(
        OutboxEntry(
          messageId: 'm1',
          sequence: 1,
          targetHash: 1,
          payload: Uint8List(1),
          attempts: 0,
          nextRetryAt: DateTime(2026),
          expiresAt: DateTime(2027),
        ),
      );
      store.saveContact(
        publicKey: key(1),
        nickname: 'Sara',
        trust: TrustState.verified,
      );

      store.wipe();

      expect(store.conversations(), isEmpty);
      expect(store.contacts(), isEmpty);
      expect(store.outboxDepth, 0);
      expect(store.acceptMessage(key(9), 1), isTrue);
    });
  });
}
