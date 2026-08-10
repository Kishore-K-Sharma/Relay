import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// Lifecycle of an outgoing message.
///
/// [sent] and [delivered] are deliberately separate. In a mesh a frame leaving
/// the device says nothing about arrival, and users make real decisions on this
/// — whether to go find someone, whether to repeat themselves out loud.
enum MessageState { queued, sent, delivered, read, failed, expired }

enum ConversationKind { direct, room }

enum TrustState { unverified, verified, keyChanged }

@immutable
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.fromMe,
    required this.state,
    required this.createdAt,
    this.senderKey,
    this.voiceDurationMs,
    this.hopCount,
    this.transport,
    this.sequence,
    this.viaCourier = false,
  });

  final String id;
  final String conversationId;
  final String body;
  final bool fromMe;
  final MessageState state;
  final DateTime createdAt;
  final Uint8List? senderKey;
  final int? voiceDurationMs;
  final int? hopCount;
  final String? transport;

  /// The sender's own sequence number. Set on outgoing messages so a read
  /// receipt, which names a message by sequence, can still find it after the
  /// outbox row has been dequeued.
  final int? sequence;

  /// Somebody carried this here rather than it arriving over a radio link.
  ///
  /// Distinct from [transport], which records the link the final hop used. A
  /// couriered message also arrives over a link — the difference is that it
  /// waited in a stranger's pocket first, possibly for hours, which is the one
  /// thing about its arrival a reader would not otherwise guess.
  final bool viaCourier;
}

@immutable
class OutboxEntry {
  const OutboxEntry({
    required this.messageId,
    required this.sequence,
    required this.targetHash,
    required this.payload,
    required this.attempts,
    required this.nextRetryAt,
    required this.expiresAt,
  });

  final String messageId;

  /// Application-level sequence. Together with the sender key this identifies
  /// the *message*, as distinct from any single transmission of it.
  final int sequence;

  final int targetHash;
  final Uint8List payload;
  final int attempts;
  final DateTime nextRetryAt;
  final DateTime expiresAt;
}

/// Durable storage.
///
/// Hand-written SQL rather than a code-generated ORM: the schema is small,
/// stable, and this keeps the package testable in a plain Dart VM with no build
/// step between a change and a test run.
class LocalStore {
  LocalStore._(this._db);

  /// Opens (or creates) a store. Pass null for an in-memory database.
  factory LocalStore.open([String? path]) {
    final db = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
    final store = LocalStore._(db);
    store._migrate();
    return store;
  }

  final Database _db;

  static const int schemaVersion = 1;

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA foreign_keys = ON');

    // Overwrite deleted content instead of just unlinking it.
    //
    // Without this, `DELETE FROM messages` marks the page free and leaves the
    // message text in the file until something happens to reuse it. On a phone
    // that is seized, "deleted" would mean "still there, findable with a hex
    // editor". The cost is extra writes on delete, which for a database this
    // small is not measurable.
    _db.execute('PRAGMA secure_delete = ON');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        peer_key BLOB,
        room_code TEXT,
        last_activity_at INTEGER NOT NULL,
        unread_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        body TEXT NOT NULL,
        from_me INTEGER NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        sender_key BLOB,
        voice_duration_ms INTEGER,
        hop_count INTEGER,
        transport TEXT,
        -- Somebody carried this message here in their pocket rather than it
        -- arriving over a radio link. Not derivable afterwards: once the
        -- envelope is opened nothing on the message says how far it walked.
        via_courier INTEGER NOT NULL DEFAULT 0,
        -- The sender's own sequence number, on outgoing messages only.
        -- A read receipt names a message by this, and it has to outlive the
        -- outbox row, which is deleted the moment delivery is acknowledged.
        sequence INTEGER
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_conv '
      'ON messages(conversation_id, created_at)',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        message_id TEXT PRIMARY KEY,
        sequence INTEGER NOT NULL,
        target_hash INTEGER NOT NULL,
        payload BLOB NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_retry_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        public_key BLOB PRIMARY KEY,
        nickname TEXT NOT NULL,
        trust TEXT NOT NULL,
        safety_code TEXT,
        pinned_at INTEGER,
        -- Deliberately chosen by the user, and independent of trust. Someone
        -- can be favourited before they are ever verified, and verifying them
        -- afterwards must not disturb the flag: see [saveContact], which lists
        -- the columns it updates rather than replacing the row.
        favourite INTEGER NOT NULL DEFAULT 0,
        favourited_at INTEGER,
        -- The X25519 key mail is sealed to when this person is out of reach.
        -- Separate from public_key, which is Ed25519 and signs. Null until
        -- they publish one; absent means "cannot be couriered to", never
        -- "fall back to the signing key".
        noise_key BLOB
      )
    ''');

    /// People this device refuses to show its owner.
    ///
    /// Keyed on the identity public key rather than an address hash, because a
    /// hash is 32 bits and truncated: two people can share one, and a block
    /// that silenced the wrong person would be worse than no block at all.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS blocked (
        public_key BLOB PRIMARY KEY,
        nickname TEXT NOT NULL DEFAULT '',
        blocked_at INTEGER NOT NULL
      )
    ''');

    /// What is known about a room beyond its code.
    ///
    /// All of it is advisory. A room's only real access control is its code,
    /// and a client that ignores every row in this table still works. Stored
    /// so the convention survives a restart, not because it is enforced.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS rooms (
        room_id INTEGER PRIMARY KEY,
        owner_key BLOB,
        claimed_at INTEGER,
        retain INTEGER NOT NULL DEFAULT 1
      )
    ''');

    /// Other people's mail, held while we carry it to them.
    ///
    /// Keyed on the ciphertext because that *is* the envelope's identity: two
    /// copies of the same sealed message are the same message however they
    /// reached this device, and replaying one must not replenish a spent spray
    /// budget.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS couriered (
        ciphertext BLOB PRIMARY KEY,
        recipient_tag BLOB NOT NULL,
        expires_at INTEGER NOT NULL,
        depositor BLOB NOT NULL,
        stored_at INTEGER NOT NULL,
        tier TEXT NOT NULL,
        copies INTEGER NOT NULL,
        -- Couriers already given a copy, so a repeated encounter with the same
        -- person does not spray them again and drain the budget.
        sprayed_to TEXT NOT NULL DEFAULT ''
      )
    ''');

    /// Deduplication of *messages* across transports, as distinct from the
    /// relay's per-transmission table. A retry carries a fresh frame id, so
    /// only (sender, sequence) identifies the message itself.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS seen_messages (
        sender_key BLOB NOT NULL,
        sequence INTEGER NOT NULL,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (sender_key, sequence)
      )
    ''');

    _db.execute(
      'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)',
    );
    _db.execute(
      "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '$schemaVersion')",
    );
  }

  // ---------------------------------------------------------- conversations

  void upsertConversation({
    required String id,
    required ConversationKind kind,
    required String title,
    Uint8List? peerKey,
    String? roomCode,
  }) {
    _db.execute(
      '''
      INSERT INTO conversations(id, kind, title, peer_key, room_code, last_activity_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title
      ''',
      [id, kind.name, title, peerKey, roomCode, _now()],
    );
  }

  List<({String id, ConversationKind kind, String title, int unread})>
  conversations() => _db
      .select(
        'SELECT id, kind, title, unread_count FROM conversations '
        'ORDER BY last_activity_at DESC',
      )
      .map(
        (row) => (
          id: row['id'] as String,
          kind: ConversationKind.values.byName(row['kind'] as String),
          title: row['title'] as String,
          unread: row['unread_count'] as int,
        ),
      )
      .toList();

  /// The identity key of the person a direct conversation is with.
  ///
  /// Null for a room, and for a conversation opened from an address hash
  /// before that person's announce was ever heard.
  Uint8List? peerKeyFor(String conversationId) {
    final rows = _db.select('SELECT peer_key FROM conversations WHERE id = ?', [
      conversationId,
    ]);
    if (rows.isEmpty) return null;
    return rows.first['peer_key'] as Uint8List?;
  }

  void markRead(String conversationId) {
    _db.execute('UPDATE conversations SET unread_count = 0 WHERE id = ?', [
      conversationId,
    ]);
    _db.execute(
      "UPDATE messages SET state = 'read' WHERE conversation_id = ? "
      "AND from_me = 0 AND state != 'read'",
      [conversationId],
    );
  }

  // --------------------------------------------------------------- messages

  /// Stores a message.
  ///
  /// [countUnread] is false for messages that arrive as history when somebody
  /// joins a room. Unread means "arrived while you were not looking"; a hundred
  /// messages that predate the user entirely are not that, and badging them as
  /// such would be noise rather than information.
  void insertMessage(StoredMessage message, {bool countUnread = true}) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO messages(
        id, conversation_id, body, from_me, state, created_at,
        sender_key, voice_duration_ms, hop_count, transport, sequence,
        via_courier)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        message.id,
        message.conversationId,
        message.body,
        message.fromMe ? 1 : 0,
        message.state.name,
        message.createdAt.millisecondsSinceEpoch,
        message.senderKey,
        message.voiceDurationMs,
        message.hopCount,
        message.transport,
        message.sequence,
        message.viaCourier ? 1 : 0,
      ],
    );
    // Only ever forwards. History arriving for a room carries the timestamps
    // it was originally recorded with, and letting those move the conversation
    // backwards would shuffle an active room down the list the moment somebody
    // caught up on it.
    _db.execute(
      'UPDATE conversations SET last_activity_at = MAX(last_activity_at, ?) '
      'WHERE id = ?',
      [message.createdAt.millisecondsSinceEpoch, message.conversationId],
    );
    if (!message.fromMe && countUnread) {
      _db.execute(
        'UPDATE conversations SET unread_count = unread_count + 1 WHERE id = ?',
        [message.conversationId],
      );
    }
  }

  /// Advances a message's state.
  ///
  /// State only ever moves forward. A late `delivered` must not overwrite a
  /// `read` that already arrived, or the UI would appear to go backwards.
  void updateMessageState(String messageId, MessageState state) {
    const rank = {
      MessageState.queued: 0,
      MessageState.sent: 1,
      MessageState.delivered: 2,
      MessageState.read: 3,
      MessageState.failed: 4,
      MessageState.expired: 4,
    };

    final current = _db.select('SELECT state FROM messages WHERE id = ?', [
      messageId,
    ]);
    if (current.isEmpty) return;

    final existing = MessageState.values.byName(
      current.first['state'] as String,
    );
    final isTerminal =
        state == MessageState.failed || state == MessageState.expired;
    if (!isTerminal && rank[state]! <= rank[existing]!) return;

    _db.execute('UPDATE messages SET state = ? WHERE id = ?', [
      state.name,
      messageId,
    ]);
  }

  List<StoredMessage> messages(String conversationId, {int limit = 200}) => _db
      .select(
        'SELECT * FROM messages WHERE conversation_id = ? '
        'ORDER BY created_at ASC LIMIT ?',
        [conversationId, limit],
      )
      .map(
        (row) => StoredMessage(
          id: row['id'] as String,
          conversationId: row['conversation_id'] as String,
          body: row['body'] as String,
          fromMe: (row['from_me'] as int) == 1,
          state: MessageState.values.byName(row['state'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
          senderKey: row['sender_key'] as Uint8List?,
          voiceDurationMs: row['voice_duration_ms'] as int?,
          hopCount: row['hop_count'] as int?,
          sequence: row['sequence'] as int?,
          transport: row['transport'] as String?,
          viaCourier: (row['via_courier'] as int? ?? 0) == 1,
        ),
      )
      .toList();

  // ----------------------------------------------------------------- outbox

  void enqueue(OutboxEntry entry) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO outbox(
        message_id, sequence, target_hash, payload, attempts, next_retry_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        entry.messageId,
        entry.sequence,
        entry.targetHash,
        entry.payload,
        entry.attempts,
        entry.nextRetryAt.millisecondsSinceEpoch,
        entry.expiresAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// Entries whose retry time has arrived and which have not expired.
  ///
  /// [ignoreBackoff] returns everything unexpired regardless of its schedule,
  /// for the case where the reason a message was deferred has demonstrably gone
  /// away — a peer reappearing, a handshake completing.
  List<OutboxEntry> dueRetries(
    DateTime now, {
    bool ignoreBackoff = false,
  }) => _db
      .select(
        ignoreBackoff
            ? 'SELECT * FROM outbox WHERE expires_at > ? '
                  'ORDER BY next_retry_at ASC'
            : 'SELECT * FROM outbox WHERE next_retry_at <= ? AND expires_at > ? '
                  'ORDER BY next_retry_at ASC',
        ignoreBackoff
            ? [now.millisecondsSinceEpoch]
            : [now.millisecondsSinceEpoch, now.millisecondsSinceEpoch],
      )
      .map(
        (row) => OutboxEntry(
          messageId: row['message_id'] as String,
          sequence: row['sequence'] as int,
          targetHash: row['target_hash'] as int,
          payload: row['payload'] as Uint8List,
          attempts: row['attempts'] as int,
          nextRetryAt: DateTime.fromMillisecondsSinceEpoch(
            row['next_retry_at'] as int,
          ),
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            row['expires_at'] as int,
          ),
        ),
      )
      .toList();

  /// Records a failed attempt and schedules the next one with exponential
  /// backoff, capped so a long-absent peer is retried roughly hourly rather
  /// than never.
  void recordAttempt(String messageId, DateTime now) {
    final rows = _db.select(
      'SELECT attempts FROM outbox WHERE message_id = ?',
      [messageId],
    );
    if (rows.isEmpty) return;

    final attempts = (rows.first['attempts'] as int) + 1;
    final backoff = Duration(
      seconds: (1 << (attempts.clamp(0, 12))).clamp(2, 3600),
    );
    _db.execute(
      'UPDATE outbox SET attempts = ?, next_retry_at = ? WHERE message_id = ?',
      [attempts, now.add(backoff).millisecondsSinceEpoch, messageId],
    );
  }

  /// The outgoing message this device sent as [sequence], if still in flight.
  ///
  /// Acknowledgements name a message by the sender's sequence, because that is
  /// the only identity both devices share.
  String? messageIdForSequence(int sequence) {
    final rows = _db.select(
      'SELECT message_id FROM outbox WHERE sequence = ? LIMIT 1',
      [sequence],
    );
    return rows.isEmpty ? null : rows.first['message_id'] as String;
  }

  /// Marks the outgoing message sent as [sequence], and every outgoing message
  /// in the same conversation before it, as read.
  ///
  /// Returns true when anything changed, so the caller can avoid a pointless
  /// UI rebuild.
  ///
  /// The cascade is the point. A receipt names the newest message the peer
  /// looked at, and reading that one means they saw everything above it —
  /// leaving those on `delivered` would show a conversation the user has
  /// plainly read as half unread. Sending one receipt per message instead
  /// would be several frames of radio for one glance at a screen.
  bool markReadThrough(int sequence) {
    final rows = _db.select(
      'SELECT conversation_id, created_at FROM messages '
      'WHERE sequence = ? AND from_me = 1 LIMIT 1',
      [sequence],
    );
    if (rows.isEmpty) return false;

    final conversationId = rows.first['conversation_id'] as String;
    final createdAt = rows.first['created_at'] as int;

    // `state != 'read'` keeps this idempotent, and the state-rank rule in
    // [updateMessageState] is preserved by only ever moving forward from the
    // two states that can precede it.
    _db.execute(
      "UPDATE messages SET state = 'read' "
      'WHERE conversation_id = ? AND from_me = 1 AND created_at <= ? '
      "AND state IN ('sent', 'delivered')",
      [conversationId, createdAt],
    );
    return _db.updatedRows > 0;
  }

  void dequeue(String messageId) {
    _db.execute('DELETE FROM outbox WHERE message_id = ?', [messageId]);
  }

  /// Marks everything past its deadline as never delivered.
  ///
  /// Returns the affected message ids so the UI can show `expired` rather than
  /// leaving a message looking permanently in flight.
  List<String> expireOutbox(DateTime now) {
    final rows = _db.select(
      'SELECT message_id FROM outbox WHERE expires_at <= ?',
      [now.millisecondsSinceEpoch],
    );
    final ids = rows.map((r) => r['message_id'] as String).toList();
    for (final id in ids) {
      _db.execute('DELETE FROM outbox WHERE message_id = ?', [id]);
      updateMessageState(id, MessageState.expired);
    }
    return ids;
  }

  int get outboxDepth =>
      _db.select('SELECT COUNT(*) AS c FROM outbox').first['c'] as int;

  // --------------------------------------------------------------- contacts

  void saveContact({
    required Uint8List publicKey,
    required String nickname,
    required TrustState trust,
    String? safetyCode,
    DateTime? pinnedAt,
  }) {
    _db.execute(
      '''
      INSERT INTO contacts(public_key, nickname, trust, safety_code, pinned_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(public_key) DO UPDATE SET
        nickname = excluded.nickname,
        trust = excluded.trust,
        safety_code = excluded.safety_code,
        pinned_at = excluded.pinned_at
      ''',
      [
        publicKey,
        nickname,
        trust.name,
        safetyCode,
        pinnedAt?.millisecondsSinceEpoch,
      ],
    );
  }

  /// Records the X25519 key this person seals mail to.
  ///
  /// Inserts a bare row when the person is not a contact yet. An announce
  /// arrives long before any conversation does, and withholding the key until
  /// there is something to attach it to would mean never learning it for
  /// somebody the user has not spoken to — which is exactly who needs mail
  /// carried to them.
  void saveNoiseKey({
    required Uint8List publicKey,
    required Uint8List noiseStaticKey,
  }) {
    _db.execute(
      '''
      INSERT INTO contacts(public_key, nickname, trust, noise_key)
      VALUES (?, '', ?, ?)
      ON CONFLICT(public_key) DO UPDATE SET noise_key = excluded.noise_key
      ''',
      [publicKey, TrustState.unverified.name, noiseStaticKey],
    );
  }

  /// The key to seal mail to, or null if this person has never published one.
  Uint8List? noiseKeyFor(Uint8List publicKey) {
    final rows = _db.select(
      'SELECT noise_key FROM contacts WHERE public_key = ?',
      [publicKey],
    );
    if (rows.isEmpty) return null;
    return rows.first['noise_key'] as Uint8List?;
  }

  /// Whose Noise key this is, or null if nobody here has published it.
  ///
  /// The reverse of [noiseKeyFor]. Needed because a courier envelope names its
  /// sender by the X25519 key that sealed it, while conversations, blocks and
  /// verification are all keyed on the Ed25519 identity.
  Uint8List? identityForNoiseKey(Uint8List noiseStaticKey) {
    final rows = _db.select(
      'SELECT public_key FROM contacts WHERE noise_key = ?',
      [noiseStaticKey],
    );
    if (rows.isEmpty) return null;
    return rows.first['public_key'] as Uint8List;
  }

  /// Everyone the user has a relationship with, however slight.
  ///
  /// Excludes rows that exist only to hold an overheard Noise key. Hearing an
  /// announce is not a relationship, and a nameless unverified row would show
  /// up in every lookup as a contact called "" — which an empty search term
  /// would then match.
  List<({Uint8List publicKey, String nickname, TrustState trust})> contacts() =>
      _db
          .select(
            '''
            SELECT public_key, nickname, trust FROM contacts
            WHERE nickname != ''
               OR trust != ?
               OR favourite = 1
               OR pinned_at IS NOT NULL
          ''',
            [TrustState.unverified.name],
          )
          .map(
            (row) => (
              publicKey: row['public_key'] as Uint8List,
              nickname: row['nickname'] as String,
              trust: TrustState.values.byName(row['trust'] as String),
            ),
          )
          .toList();

  // --------------------------------------------------------------- couriered

  /// One piece of somebody else's mail, held on this device.
  ///
  /// Deliberately a plain record rather than a domain object: this package
  /// stores rows and enforces nothing. Every quota and spray decision lives in
  /// `messaging`, where it can be reasoned about in one place.
  void saveCouriered({
    required Uint8List ciphertext,
    required Uint8List recipientTag,
    required int expiresAt,
    required Uint8List depositor,
    required DateTime storedAt,
    required String tier,
    required int copies,
    List<String> sprayedTo = const [],
  }) {
    _db.execute(
      '''
      INSERT INTO couriered(
        ciphertext, recipient_tag, expires_at, depositor, stored_at, tier,
        copies, sprayed_to)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(ciphertext) DO UPDATE SET
        copies = excluded.copies,
        sprayed_to = excluded.sprayed_to
      ''',
      [
        ciphertext,
        recipientTag,
        expiresAt,
        depositor,
        storedAt.millisecondsSinceEpoch,
        tier,
        copies,
        sprayedTo.join(','),
      ],
    );
  }

  List<
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
  >
  couriered() => _db
      .select('SELECT * FROM couriered ORDER BY stored_at ASC')
      .map(
        (row) => (
          ciphertext: row['ciphertext'] as Uint8List,
          recipientTag: row['recipient_tag'] as Uint8List,
          expiresAt: row['expires_at'] as int,
          depositor: row['depositor'] as Uint8List,
          storedAt: DateTime.fromMillisecondsSinceEpoch(
            row['stored_at'] as int,
          ),
          tier: row['tier'] as String,
          copies: row['copies'] as int,
          sprayedTo: (row['sprayed_to'] as String).isEmpty
              ? const <String>[]
              : (row['sprayed_to'] as String).split(','),
        ),
      )
      .toList();

  void deleteCouriered(Uint8List ciphertext) {
    _db.execute('DELETE FROM couriered WHERE ciphertext = ?', [ciphertext]);
  }

  /// Destroys everything past its deadline. Returns how many went.
  int expireCouriered(DateTime now) {
    _db.execute('DELETE FROM couriered WHERE expires_at <= ?', [
      now.millisecondsSinceEpoch,
    ]);
    return _db.updatedRows;
  }

  int get courieredCount =>
      _db.select('SELECT COUNT(*) AS c FROM couriered').first['c'] as int;

  /// Throws away every envelope this device is holding for other people.
  /// Returns how many went.
  ///
  /// Touches nothing but the `couriered` table. The user's own conversations
  /// live in `messages` and are not this button's business — a control labelled
  /// "stop carrying other people's mail" that also deleted your own messages
  /// would be a data-loss bug wearing a reasonable label.
  int dropCouriered() {
    _db.execute('DELETE FROM couriered');
    return _db.updatedRows;
  }

  // ------------------------------------------------------------------ rooms

  /// Records who is understood to run a room.
  ///
  /// [claimedAt] is the owner's clock, kept so a captured claim cannot be
  /// replayed later as a newer one.
  void saveRoomOwner({
    required int roomId,
    required Uint8List ownerKey,
    required DateTime claimedAt,
  }) {
    _db.execute(
      '''
      INSERT INTO rooms(room_id, owner_key, claimed_at)
      VALUES (?, ?, ?)
      ON CONFLICT(room_id) DO UPDATE SET
        owner_key = excluded.owner_key,
        claimed_at = excluded.claimed_at
      ''',
      [roomId, ownerKey, claimedAt.millisecondsSinceEpoch],
    );
  }

  void setRoomRetention(int roomId, {required bool retain}) {
    _db.execute(
      'INSERT INTO rooms(room_id, retain) VALUES (?, ?) '
      'ON CONFLICT(room_id) DO UPDATE SET retain = excluded.retain',
      [roomId, retain ? 1 : 0],
    );
  }

  ({Uint8List? ownerKey, DateTime? claimedAt, bool retain})? room(int roomId) {
    final rows = _db.select(
      'SELECT owner_key, claimed_at, retain FROM rooms WHERE room_id = ?',
      [roomId],
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final claimedAt = row['claimed_at'] as int?;
    return (
      ownerKey: row['owner_key'] as Uint8List?,
      claimedAt: claimedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(claimedAt),
      retain: (row['retain'] as int) == 1,
    );
  }

  /// Erases a conversation's messages without erasing the conversation.
  ///
  /// Used for a room whose owner asked that it not be kept. `secure_delete`,
  /// set at open time, overwrites the pages rather than merely freeing them —
  /// but see `docs/SECURITY.md` for what that does and does not promise.
  void deleteMessagesIn(String conversationId) {
    _db.execute('DELETE FROM messages WHERE conversation_id = ?', [
      conversationId,
    ]);
    _db.execute('UPDATE conversations SET unread_count = 0 WHERE id = ?', [
      conversationId,
    ]);
  }

  // -------------------------------------------------------------- favourites

  /// Marks someone as chosen, creating a contact row if there is not one yet.
  ///
  /// Favouriting is available long before verification — the user stars someone
  /// the moment they appear — so this cannot require an existing contact.
  void setFavourite({
    required Uint8List publicKey,
    required bool favourite,
    String nickname = '',
    DateTime? at,
  }) {
    _db.execute(
      '''
      INSERT INTO contacts(public_key, nickname, trust, favourite, favourited_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(public_key) DO UPDATE SET
        favourite = excluded.favourite,
        favourited_at = excluded.favourited_at,
        -- Only fill in a name we did not already have. A verified contact's
        -- name was confirmed in person; a name guessed from a broadcast
        -- announce must not overwrite it.
        nickname = CASE WHEN contacts.nickname = '' THEN excluded.nickname
                        ELSE contacts.nickname END
      ''',
      [
        publicKey,
        nickname,
        TrustState.unverified.name,
        favourite ? 1 : 0,
        favourite ? (at ?? DateTime.now()).millisecondsSinceEpoch : null,
      ],
    );
  }

  bool isFavourite(Uint8List publicKey) => _db.select(
    'SELECT 1 FROM contacts WHERE public_key = ? AND favourite = 1',
    [publicKey],
  ).isNotEmpty;

  /// Everyone chosen, most recently chosen first.
  List<({Uint8List publicKey, String nickname, TrustState trust})>
  favourites() => _db
      .select(
        'SELECT public_key, nickname, trust FROM contacts '
        'WHERE favourite = 1 ORDER BY favourited_at DESC',
      )
      .map(
        (row) => (
          publicKey: row['public_key'] as Uint8List,
          nickname: row['nickname'] as String,
          trust: TrustState.values.byName(row['trust'] as String),
        ),
      )
      .toList();

  // --------------------------------------------------------------- blocking

  void blockPeer({
    required Uint8List publicKey,
    required DateTime at,
    String nickname = '',
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO blocked(public_key, nickname, blocked_at) '
      'VALUES (?, ?, ?)',
      [publicKey, nickname, at.millisecondsSinceEpoch],
    );
  }

  void unblockPeer(Uint8List publicKey) {
    _db.execute('DELETE FROM blocked WHERE public_key = ?', [publicKey]);
  }

  bool isBlocked(Uint8List publicKey) => _db.select(
    'SELECT 1 FROM blocked WHERE public_key = ?',
    [publicKey],
  ).isNotEmpty;

  /// Everyone blocked, so the list can be reviewed and undone.
  ///
  /// A block with no way to see it is a trap: someone silences a stranger in a
  /// crowd, later wants to undo it, and has no idea who they blocked.
  List<({Uint8List publicKey, String nickname, DateTime blockedAt})>
  blocked() => _db
      .select(
        'SELECT public_key, nickname, blocked_at FROM blocked '
        'ORDER BY blocked_at DESC',
      )
      .map(
        (row) => (
          publicKey: row['public_key'] as Uint8List,
          nickname: row['nickname'] as String,
          blockedAt: DateTime.fromMillisecondsSinceEpoch(
            row['blocked_at'] as int,
          ),
        ),
      )
      .toList();

  // ---------------------------------------------------- cross-transport dedup

  /// Returns true the first time a given (sender, sequence) is offered.
  bool acceptMessage(Uint8List senderKey, int sequence) {
    final existing = _db.select(
      'SELECT 1 FROM seen_messages WHERE sender_key = ? AND sequence = ?',
      [senderKey, sequence],
    );
    if (existing.isNotEmpty) return false;

    _db.execute(
      'INSERT INTO seen_messages(sender_key, sequence, seen_at) VALUES (?, ?, ?)',
      [senderKey, sequence, _now()],
    );
    return true;
  }

  // ------------------------------------------------------------------- admin

  /// Destroys everything. Part of panic wipe; irreversible by design.
  ///
  /// Deleting the rows is the easy part and, on its own, is not a wipe. Three
  /// separate places keep the plaintext afterwards, and all three are checked
  /// by `panic_wipe_test.dart` reading the raw bytes off disk:
  ///
  ///  - **Free pages in the main file.** `PRAGMA secure_delete` handles this,
  ///    set at open time so ordinary deletions are covered too.
  ///  - **The write-ahead log.** In WAL mode recent writes live in
  ///    `<db>-wal`, not in the database at all. A wipe that never checkpoints
  ///    leaves the whole conversation sitting in that file.
  ///  - **The file's own free list.** `VACUUM` rebuilds the database so the
  ///    freed space is genuinely gone rather than merely marked reusable.
  void wipe() {
    for (final table in [
      'messages',
      'conversations',
      'outbox',
      'contacts',
      'blocked',
      'rooms',
      'couriered',
      'seen_messages',
    ]) {
      _db.execute('DELETE FROM $table');
    }

    // Fold the WAL back into the database and truncate it to nothing. Must
    // happen before the VACUUM, or the vacuum's own writes land in a fresh WAL
    // that then still holds the pages it was meant to discard.
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _db.execute('VACUUM');
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  void close() => _db.dispose();

  /// Deletes database files in [directory] that this build does not own.
  ///
  /// [wipe] erases the database this process has open. A file left in the same
  /// directory by an older build, under a name this build never opens, is not
  /// reached by it — so its message history survives a panic wipe while the app
  /// reports success. Intact plaintext plus an assurance it is gone is worse
  /// than either alone.
  ///
  /// Run at startup rather than at wipe time, so the orphan does not survive
  /// even one launch and the user is not required to have pressed anything.
  ///
  /// [keep] is an allow-list of file names, not a list of old ones. A list of
  /// old names has to be extended by whoever renames a database next, which is
  /// the same person who has already forgotten. Files that are not databases
  /// are left alone: this directory is not exclusively ours, and deleting
  /// everything unrecognised is the same bug pointing the other way.
  ///
  /// Deletion here is filesystem-level. As with [wipe], the actual defence
  /// against recovery from flash is the platform's encryption at rest, and
  /// nothing beyond that is claimed. See `docs/SECURITY.md`.
  static void eraseForeignDatabases(
    String directory, {
    required Set<String> keep,
  }) {
    final dir = Directory(directory);
    // A fresh install has no directory yet. Throwing would take out startup
    // for every new user, to protect data that cannot be there.
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;

      // The sidecars carry the payload. In WAL mode the most recent writes —
      // the conversation most worth protecting — are in `<db>-wal` and not in
      // the database at all, so matching only `.db` deletes the empty half.
      final base = switch (name) {
        _ when name.endsWith('.db-wal') => name.substring(0, name.length - 4),
        _ when name.endsWith('.db-shm') => name.substring(0, name.length - 4),
        _ when name.endsWith('.db-journal') => name.substring(
          0,
          name.length - 8,
        ),
        _ when name.endsWith('.db') => name,
        _ => null,
      };
      if (base == null || keep.contains(base)) continue;

      entity.deleteSync();
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
