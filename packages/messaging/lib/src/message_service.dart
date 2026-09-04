import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:data/data.dart';
import 'package:transport_nostr/transport_nostr.dart';

import 'session_manager.dart';

/// Application-level envelope carried inside the encrypted payload.
///
/// The mesh's [MsgId] identifies one *transmission*; a retry is a different
/// transmission of the same message and carries a fresh id, precisely so it can
/// slip past relays that already saw the original. Identifying the *message*
/// end to end therefore needs its own field, which is what this provides.
class AppEnvelope {
  const AppEnvelope({
    required this.senderKey,
    required this.sequence,
    required this.body,
    this.voiceDurationMs,
    this.compressed = false,
    this.isDummy = false,
  });

  /// A frame that means nothing, sent so that silence and conversation look
  /// alike to somebody watching the radio.
  ///
  /// Marked rather than made of random bytes, so the recipient discards it
  /// cheaply and certainly. The marker is inside the encryption: an observer
  /// sees an ordinary padded frame of an ordinary size, which is the whole
  /// point.
  factory AppEnvelope.dummy({
    required Uint8List senderKey,
    required Uint8List filler,
  }) => AppEnvelope(
    senderKey: senderKey,
    sequence: 0,
    body: filler,
    isDummy: true,
  );

  /// Builds an envelope, compressing the body when that is worth doing.
  ///
  /// Compression lives here, under the encryption, for two reasons.
  /// Compressing afterwards would be pointless — ciphertext does not compress.
  /// And the frame header has a spare `compressed` flag which is deliberately
  /// left unused: setting it would tell every relay in earshot whether a given
  /// message was repetitive enough to shrink, which is a small leak that costs
  /// nothing to avoid by keeping the marker inside the sealed envelope.
  factory AppEnvelope.build({
    required Uint8List senderKey,
    required int sequence,
    required Uint8List body,
    int? voiceDurationMs,
    CompressionPolicy policy = defaultCompression,
  }) {
    final result = policy.apply(
      body,
      // Audio is already compressed. A second pass burns battery and usually
      // produces something larger.
      type: voiceDurationMs == null ? FrameType.message : FrameType.voice,
    );
    return AppEnvelope(
      senderKey: senderKey,
      sequence: sequence,
      body: result.payload,
      voiceDurationMs: voiceDurationMs,
      compressed: result.compressed,
    );
  }

  static const CompressionPolicy defaultCompression = CompressionPolicy(
    compressor: Lz4Compressor(),
  );

  /// 4-byte sender hash + 4-byte sequence + 2-byte voice duration + flags.
  static const int headerLength = 11;

  static const int _compressedBit = 0x01;
  static const int _dummyBit = 0x02;

  final Uint8List senderKey;
  final int sequence;

  /// Compressed when [compressed] is true. Use [AppEnvelope.decode] to read it
  /// back; touching this directly gets you the compressed bytes.
  final Uint8List body;

  final int? voiceDurationMs;
  final bool compressed;

  /// True for a cover-traffic frame. The recipient drops it without a trace.
  final bool isDummy;

  Uint8List encode() {
    final out = Uint8List(headerLength + body.length);
    final view = ByteData.view(out.buffer);
    out.setRange(0, 4, senderKey.take(4).toList());
    view.setUint32(4, sequence, Endian.big);
    view.setUint16(8, voiceDurationMs ?? 0, Endian.big);
    out[10] = (compressed ? _compressedBit : 0) | (isDummy ? _dummyBit : 0);
    out.setRange(headerLength, out.length, body);
    return out;
  }

  /// Reads an envelope back, decompressing the body if it says so.
  ///
  /// Returns null on anything malformed, including a body that claims to be
  /// compressed and is not. The caller drops the message: a peer that is lying
  /// or corrupt must cost one dropped frame, not an exception on the inbound
  /// chain that would silence the device.
  static AppEnvelope? decode(
    Uint8List payload, {
    CompressionPolicy policy = defaultCompression,
  }) {
    if (payload.length < headerLength) return null;
    final view = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
      payload.length,
    );
    final duration = view.getUint16(8, Endian.big);
    final compressed = payload[10] & _compressedBit != 0;
    final isDummy = payload[10] & _dummyBit != 0;

    final Uint8List body;
    try {
      body = policy.restore(
        Uint8List.sublistView(payload, headerLength),
        compressed: compressed,
      );
    } on FrameFormatException {
      return null;
    }

    return AppEnvelope(
      senderKey: Uint8List.sublistView(payload, 0, 4),
      sequence: view.getUint32(4, Endian.big),
      body: body,
      voiceDurationMs: duration == 0 ? null : duration,
      compressed: compressed,
      isDummy: isDummy,
    );
  }
}

/// A stored inbound message plus the identity the sender gave it.
///
/// The sequence is carried out separately because an acknowledgement has to
/// name the message in terms the *sender* recognises, and a local row id means
/// nothing on the other device.
class ReceivedMessage {
  const ReceivedMessage({
    required this.message,
    required this.senderKey,
    required this.sequence,
  });

  final StoredMessage message;
  final Uint8List senderKey;
  final int sequence;
}

/// Outcome of an attempt to send, reported honestly to the UI.
class SendOutcome {
  const SendOutcome({
    required this.messageId,
    required this.state,
    required this.transport,
    this.reason,
  });

  final String messageId;
  final MessageState state;
  final TransportKind? transport;

  /// Why the message did not go out, when it did not.
  final String? reason;
}

/// Ties the pieces together for one device.
///
/// Deliberately the only place that knows the full path from "user typed
/// something" to "bytes on a radio". Every layer beneath it stays testable in
/// isolation because none of them reach across this boundary.
class MessageService {
  MessageService({
    required LocalStore store,
    required TransportRouter router,
    required SessionManager sessions,
    required Uint8List senderKey,
    required int localAddressHash,
    DateTime Function()? clock,
    Random? random,

    /// Rounds every payload up to a block size before it is encrypted, so the
    /// length of a frame stops describing the message inside it. On by
    /// default; it costs airtime, so it can be switched off.
    PaddingPolicy padding = const PaddingPolicy(),

    /// Whether the internet relay may be spent on a given recipient, and how
    /// long to keep retrying for them.
    ///
    /// Callbacks rather than stored columns because both answers can change
    /// after a message is queued — the user stars someone while a message to
    /// them is still sitting in the outbox — and because this package has no
    /// business knowing what a favourite is.
    bool Function(int targetHash)? relayAllowed,
    Duration Function(int targetHash)? retryWindow,
  }) : _store = store,
       _padding = padding,
       _relayAllowed = relayAllowed ?? _alwaysRelay,
       _retryWindow = retryWindow ?? _defaultRetryWindow,
       _router = router,
       _sessions = sessions,
       _senderKey = senderKey,
       _localHash = localAddressHash,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final LocalStore _store;
  final TransportRouter _router;
  final SessionManager _sessions;
  final Uint8List _senderKey;
  final int _localHash;
  final DateTime Function() _clock;
  final Random _random;
  final PaddingPolicy _padding;
  final bool Function(int targetHash) _relayAllowed;
  final Duration Function(int targetHash) _retryWindow;

  static bool _alwaysRelay(int _) => true;
  static Duration _defaultRetryWindow(int _) => outboxLifetime;

  /// Room keys by room address. A target hash present here is a room and needs
  /// no handshake; anything else is a direct message and does.
  final _rooms = <int, RoomCipher>{};

  int _sequence = 0;

  SessionManager get sessions => _sessions;

  void registerRoom(int roomId, RoomCipher cipher) => _rooms[roomId] = cipher;

  void forgetRoom(int roomId) => _rooms.remove(roomId);

  /// How long an undelivered message keeps being retried before it is declared
  /// never delivered. The default; see `retryWindow` for the per-recipient
  /// override the app uses to keep a favourite's messages for longer.
  static const Duration outboxLifetime = Duration(hours: 24);

  final _events = StreamController<SendOutcome>.broadcast();

  /// Delivery state changes, so the UI can update without polling.
  Stream<SendOutcome> get outcomes => _events.stream;

  /// Sends a text or voice message to one peer or a room.
  Future<SendOutcome> send({
    required String conversationId,
    required String body,
    required int targetHash,
    String? targetPeerId,
    int? voiceDurationMs,
  }) async {
    _sequence++;
    final messageId = _newMessageId();
    final now = _clock();

    _store.insertMessage(
      StoredMessage(
        id: messageId,
        conversationId: conversationId,
        body: body,
        fromMe: true,
        state: MessageState.queued,
        createdAt: now,
        senderKey: _senderKey,
        voiceDurationMs: voiceDurationMs,
        // Kept on the message, not only in the outbox: the outbox row is
        // deleted the moment delivery is acknowledged, and a read receipt
        // arrives after that.
        sequence: _sequence,
      ),
    );

    final envelope = AppEnvelope.build(
      senderKey: _senderKey,
      sequence: _sequence,
      // UTF-8, not `codeUnits`. That getter yields UTF-16, and everything
      // above 0xFF is silently truncated on the way into a byte list — which
      // would corrupt every message in most of the world's languages.
      body: Uint8List.fromList(utf8.encode(body)),
      voiceDurationMs: voiceDurationMs,
    ).encode();

    // Persist to the outbox before attempting to send. If the process dies
    // between the two, the message is retried rather than silently lost.
    _store.enqueue(
      OutboxEntry(
        messageId: messageId,
        sequence: _sequence,
        targetHash: targetHash,
        payload: envelope,
        attempts: 0,
        nextRetryAt: now,
        expiresAt: now.add(_retryWindow(targetHash)),
      ),
    );

    return _attempt(
      messageId: messageId,
      sequence: _sequence,
      targetHash: targetHash,
      targetPeerId: targetPeerId,
      payload: envelope,
      voiceDurationMs: voiceDurationMs,
    );
  }

  Future<SendOutcome> _attempt({
    required String messageId,
    required int sequence,
    required int targetHash,
    required String? targetPeerId,
    required Uint8List payload,
    int? voiceDurationMs,
  }) async {
    final room = _rooms[targetHash];

    // Encrypt before anything else. A frame whose header says `encrypted` while
    // its payload is readable would be the single most damaging bug this app
    // could ship, so there is no code path here that puts plaintext on a wire.
    final Uint8List sealed;
    final FrameType type;

    // Padded before encryption, never after. Padding ciphertext would leave
    // the real length visible in the block the receiver has to be told about;
    // padding first means the filler is inside the sealed envelope and is
    // indistinguishable from the message to anyone who cannot read it.
    final padded = _padding.pad(payload);

    if (room != null) {
      sealed = await room.encrypt(padded);
      type = FrameType.room;
    } else {
      if (_sessions.stateFor(targetHash) != SessionState.established) {
        // No secure channel yet. Open one and leave the message in the outbox;
        // it goes out on the next retry once the handshake lands.
        await ensureSession(targetHash, peerId: targetPeerId);
        return _reportUnsent(
          messageId,
          'setting up encryption with this person',
        );
      }
      sealed = await _sessions.encrypt(targetHash, padded);
      type = voiceDurationMs == null ? FrameType.message : FrameType.voice;
    }

    final frames = fragmentFrame(
      Frame(
        type: type,
        ttl: maxTtl,
        flags: const FrameFlags(encrypted: true),
        msgId: _newMsgId(),
        srcHash: _localHash,
        dstHash: targetHash,
        payload: sealed,
      ),
    );

    RouteResult? last;
    for (final frame in frames) {
      last = await _router.send(
        frame.encode(),
        toPeer: targetPeerId,
        // A room is addressed to everyone in range and never has a peer to
        // relay to, so the question only arises for direct messages.
        allowRelay: room != null || _relayAllowed(targetHash),
      );
      if (!last.accepted) break;
    }

    final outcome = last != null && last.accepted
        ? SendOutcome(
            messageId: messageId,
            // "sent" only. Delivery is not known until an ack returns, and
            // claiming otherwise here is the single most misleading thing this
            // app could do.
            state: MessageState.sent,
            transport: last.kind,
          )
        : SendOutcome(
            messageId: messageId,
            state: MessageState.queued,
            transport: null,
            reason: last?.reason ?? 'no transport available',
          );

    _store.updateMessageState(messageId, outcome.state);
    // Recorded whether or not the frame left. A message stays in the outbox
    // until an ack arrives, so without backoff on the success path every
    // sent-but-unacknowledged message would be rebroadcast on every tick.
    _store.recordAttempt(messageId, _clock());
    _events.add(outcome);
    return outcome;
  }

  SendOutcome _reportUnsent(String messageId, String reason) {
    final outcome = SendOutcome(
      messageId: messageId,
      state: MessageState.queued,
      transport: null,
      reason: reason,
    );
    _store.updateMessageState(messageId, MessageState.queued);
    _store.recordAttempt(messageId, _clock());
    _events.add(outcome);
    return outcome;
  }

  // ------------------------------------------------------------- handshakes

  /// Opens a Noise session with a peer if one is not already in progress.
  Future<void> ensureSession(int peerHash, {String? peerId}) async {
    if (_sessions.stateFor(peerHash) != SessionState.none) return;
    final opening = await _sessions.beginHandshake(peerHash);
    await _sendHandshake(peerHash, opening, peerId);
  }

  /// Feeds an inbound handshake frame and sends any reply it produces.
  ///
  /// Returns true once the session is established, which is the caller's cue to
  /// flush anything that was waiting on it.
  Future<bool> handleHandshake({
    required int peerHash,
    required Uint8List message,
    String? peerId,
  }) async {
    try {
      final reply = await _sessions.receiveHandshake(peerHash, message);
      if (reply != null) await _sendHandshake(peerHash, reply, peerId);
    } catch (_) {
      // A malformed or hostile handshake message is not worth reporting to the
      // user: in a crowd it is indistinguishable from ordinary radio noise.
      return false;
    }
    return _sessions.stateFor(peerHash) == SessionState.established;
  }

  Future<void> _sendHandshake(
    int peerHash,
    Uint8List message,
    String? peerId,
  ) async {
    // A handshake message is not secret — it is what establishes the secret —
    // so the encrypted flag stays false and says so truthfully.
    final frame = Frame(
      type: FrameType.handshake,
      ttl: maxTtl,
      flags: const FrameFlags(),
      msgId: _newMsgId(),
      srcHash: _localHash,
      dstHash: peerHash,
      payload: message,
    );
    // Gated the same way a message is. Opening a session over the relay would
    // spend exactly the metadata the gate exists to protect, and it would do so
    // before the user had said a word.
    await _router.send(
      frame.encode(),
      toPeer: peerId,
      allowRelay: _relayAllowed(peerHash),
    );
  }

  /// Sends everything queued for one target immediately, ignoring backoff.
  ///
  /// Backoff exists to avoid hammering a peer that is not there. When a
  /// handshake has just completed the peer demonstrably *is* there, and the
  /// exact reason those messages were deferred has gone away — waiting out a
  /// timer would leave the user staring at "waiting to send" for no reason.
  Future<int> flushFor(int targetHash) async {
    final due = [
      for (final entry in _store.dueRetries(_clock(), ignoreBackoff: true))
        if (entry.targetHash == targetHash) entry,
    ];
    return _attemptGroup(targetHash, due);
  }

  /// Retries everything due. Called when a peer appears or a partition heals.
  Future<int> retryDue() async {
    final now = _clock();
    _store.expireOutbox(now);

    return _flush(_store.dueRetries(now));
  }

  /// Sends a set of outbox entries, combining what can usefully be combined.
  ///
  /// Grouped by recipient because a batch is one encrypted frame to one
  /// address; two messages to two people share nothing.
  Future<int> _flush(List<OutboxEntry> entries) async {
    final byTarget = <int, List<OutboxEntry>>{};
    for (final entry in entries) {
      byTarget.putIfAbsent(entry.targetHash, () => []).add(entry);
    }

    var sent = 0;
    for (final group in byTarget.entries) {
      sent += await _attemptGroup(group.key, group.value);
    }
    return sent;
  }

  Future<int> _attemptGroup(int targetHash, List<OutboxEntry> entries) async {
    // One message, or a room — where the payload is already shared with
    // everyone and there is nothing to coalesce against — goes the ordinary
    // way. Batching those would add a container for no saving.
    if (entries.length < 2 || _rooms.containsKey(targetHash)) {
      for (final entry in entries) {
        await _attempt(
          messageId: entry.messageId,
          sequence: entry.sequence,
          targetHash: targetHash,
          targetPeerId: null,
          payload: entry.payload,
        );
      }
      return entries.length;
    }

    if (_sessions.stateFor(targetHash) != SessionState.established) {
      await ensureSession(targetHash);
      for (final entry in entries) {
        _reportUnsent(
          entry.messageId,
          'setting up encryption with this person',
        );
      }
      return entries.length;
    }

    var sent = 0;
    var at = 0;
    for (final batch in PayloadBatch.plan([
      for (final entry in entries) entry.payload,
    ])) {
      final members = entries.sublist(at, at + batch.items.length);
      at += batch.items.length;

      if (members.length == 1) {
        // Nothing to combine it with — an oversized payload, or the tail of a
        // group. The ordinary path already handles it correctly.
        await _attempt(
          messageId: members.single.messageId,
          sequence: members.single.sequence,
          targetHash: targetHash,
          targetPeerId: null,
          payload: members.single.payload,
        );
        sent++;
        continue;
      }

      await _sendBatch(targetHash, batch, members);
      sent += members.length;
    }
    return sent;
  }

  /// Encrypts and sends one batch, then reports its outcome for every message
  /// inside it.
  ///
  /// Padding is applied to the batch rather than to each message, which is
  /// most of the saving: five short messages round up to one block instead of
  /// five.
  Future<void> _sendBatch(
    int targetHash,
    PayloadBatch batch,
    List<OutboxEntry> members,
  ) async {
    final sealed = await _sessions.encrypt(
      targetHash,
      _padding.pad(batch.encode()),
    );

    RouteResult? last;
    for (final frame in fragmentFrame(
      Frame(
        type: FrameType.batch,
        ttl: maxTtl,
        flags: const FrameFlags(encrypted: true),
        msgId: _newMsgId(),
        srcHash: _localHash,
        dstHash: targetHash,
        payload: sealed,
      ),
    )) {
      last = await _router.send(
        frame.encode(),
        allowRelay: _relayAllowed(targetHash),
      );
      if (!last.accepted) break;
    }

    final accepted = last != null && last.accepted;
    for (final member in members) {
      // Reported per message, not per batch. The user sees message states, and
      // "the frame carrying five of your messages left" is not one of them.
      final outcome = accepted
          ? SendOutcome(
              messageId: member.messageId,
              state: MessageState.sent,
              transport: last.kind,
            )
          : SendOutcome(
              messageId: member.messageId,
              state: MessageState.queued,
              transport: null,
              reason: last?.reason ?? 'no transport available',
            );
      _store.updateMessageState(member.messageId, outcome.state);
      _store.recordAttempt(member.messageId, _clock());
      _events.add(outcome);
    }
  }

  /// Handles a fully reassembled inbound payload.
  ///
  /// [ciphertext] is exactly what came off the wire. Decryption happens here so
  /// no caller can accidentally accept an unencrypted payload as a message.
  ///
  /// Returns null when the message is a duplicate — which happens routinely, as
  /// a retry or the same message arriving over both Bluetooth and the relay —
  /// or when it cannot be decrypted, which is equally routine in a crowd full
  /// of traffic addressed to other people.
  Future<ReceivedMessage?> receive({
    required String conversationId,
    required Uint8List ciphertext,
    required int senderHash,
    required TransportKind via,
    int? hopCount,
  }) async {
    final opened = await _open(senderHash, ciphertext);
    if (opened == null) return null;
    return _accept(conversationId, opened, via: via, hopCount: hopCount);
  }

  /// Handles an inbound [FrameType.batch]: several messages in one frame.
  ///
  /// Returns everything that was new. An unreadable or malformed batch yields
  /// nothing rather than throwing, for the same reason [receive] does.
  Future<List<ReceivedMessage>> receiveBatch({
    required String conversationId,
    required Uint8List ciphertext,
    required int senderHash,
    required TransportKind via,
    int? hopCount,
  }) async {
    final opened = await _open(senderHash, ciphertext);
    if (opened == null) return const [];

    final batch = PayloadBatch.decode(opened);
    if (batch == null) return const [];

    final received = <ReceivedMessage>[];
    for (final item in batch.items) {
      final message = _accept(
        conversationId,
        item,
        via: via,
        hopCount: hopCount,
      );
      if (message != null) received.add(message);
    }
    return received;
  }

  /// Decrypts and unpads, or null if this device cannot read it.
  ///
  /// Failing is routine rather than exceptional: a crowd is full of traffic
  /// addressed to other people, and a captured frame replayed at us is a
  /// non-event.
  Future<Uint8List?> _open(int senderHash, Uint8List ciphertext) async {
    final room = _rooms[senderHash];

    final Uint8List plaintext;
    try {
      plaintext = room != null
          ? await room.decrypt(ciphertext)
          : await _sessions.decrypt(senderHash, ciphertext);
    } on DecryptFailure {
      return null;
    } on NoSessionException {
      return null;
    } on ReplayedMessage {
      return null;
    }

    try {
      return _padding.strip(plaintext);
    } on FrameFormatException {
      // A peer that is corrupt, hostile, or padding when we are not. One
      // dropped message, never an exception on the inbound path.
      return null;
    }
  }

  ReceivedMessage? _accept(
    String conversationId,
    Uint8List unpadded, {
    required TransportKind via,
    int? hopCount,
    bool viaCourier = false,
  }) {
    final envelope = AppEnvelope.decode(unpadded);
    if (envelope == null) return null;

    // Cover traffic. It cost the sender a frame on purpose; it costs us
    // nothing beyond this line, and it is never shown or acknowledged —
    // acknowledging it would tell an observer exactly which frames were real.
    if (envelope.isDummy) return null;

    if (!_store.acceptMessage(envelope.senderKey, envelope.sequence)) {
      return null;
    }

    final message = StoredMessage(
      id: _newMessageId(),
      conversationId: conversationId,
      body: utf8.decode(envelope.body, allowMalformed: true),
      fromMe: false,
      state: MessageState.delivered,
      createdAt: _clock(),
      senderKey: envelope.senderKey,
      voiceDurationMs: envelope.voiceDurationMs,
      hopCount: hopCount,
      transport: via.name,
      viaCourier: viaCourier,
      // The sender's own counter, kept so this message can be recognised again
      // when somebody shares it as history to catch a newcomer up.
      sequence: envelope.sequence,
    );
    _store.insertMessage(message);
    return ReceivedMessage(
      message: message,
      senderKey: envelope.senderKey,
      sequence: envelope.sequence,
    );
  }

  // --------------------------------------------------------- cover traffic

  /// Sends a frame that means nothing to [targetHash].
  ///
  /// Indistinguishable from a real message to anyone watching the radio: same
  /// encryption, same padding, same size distribution. The recipient decrypts
  /// it, sees the marker, and drops it without showing or acknowledging
  /// anything — an ack would identify the real frames immediately.
  ///
  /// Does nothing without an established session. Opening one purely to send
  /// noise would announce this device to somebody it has never spoken to,
  /// which is the opposite of the intent.
  Future<bool> sendDummy(int targetHash) async {
    if (_sessions.stateFor(targetHash) != SessionState.established) {
      return false;
    }

    // Random filler of a plausible length. Padding rounds it to a block
    // anyway; the variation keeps it from always landing in the same bucket.
    final filler = Uint8List.fromList(
      List.generate(8 + _random.nextInt(120), (_) => _random.nextInt(256)),
    );

    final sealed = await _sessions.encrypt(
      targetHash,
      _padding.pad(
        AppEnvelope.dummy(senderKey: _senderKey, filler: filler).encode(),
      ),
    );

    for (final frame in fragmentFrame(
      Frame(
        type: FrameType.message,
        ttl: maxTtl,
        flags: const FrameFlags(encrypted: true),
        msgId: _newMsgId(),
        srcHash: _localHash,
        dstHash: targetHash,
        payload: sealed,
      ),
    )) {
      // Never over the relay. Paying a third party's bandwidth to send noise
      // would be rude, and it would show up as this device's traffic anyway.
      await _router.send(frame.encode(), allowRelay: false);
    }
    return true;
  }

  /// Peers a dummy could plausibly be sent to right now.
  List<int> get dummyCandidates => _sessions.establishedPeers;

  // -------------------------------------------------------------- couriers

  /// Hands one envelope to a device that might meet its recipient.
  ///
  /// Returns false when the envelope will not encode, which is the only local
  /// failure worth distinguishing: a refused handover is a decision this layer
  /// does not make, and a failed radio write is indistinguishable from the
  /// courier walking away.
  ///
  /// Addressed to [peerHash] — the *carrier* — because nobody here knows how to
  /// address the recipient. That is why it is being carried.
  Future<bool> sendCourier(
    CourierEnvelope envelope, {
    required String toPeer,
    required int peerHash,
  }) async {
    final payload = envelope.encode();
    if (payload == null) return false;

    for (final frame in fragmentFrame(
      Frame(
        type: FrameType.courier,
        // Zero, not one. A frame addressed to us is delivered before the hop
        // counter is looked at, so the carrier still receives this; a bystander
        // is not the addressee, sees an exhausted counter and drops it. At
        // ttl 1 every bystander in range would instead rebroadcast it once,
        // replicating the envelope outside the spray budget — the only thing
        // bounding how much of the network one message consumes — and
        // advertising to a wider circle that this device is carrying mail.
        ttl: 0,
        // The body is sealed, but the tag, expiry and copy count are readable
        // on purpose, so a carrier can decide whether to take it and when to
        // drop it. Claiming the frame is encrypted would misdescribe that.
        flags: const FrameFlags(),
        msgId: _newMsgId(),
        srcHash: _localHash,
        dstHash: peerHash,
        payload: payload,
      ),
    )) {
      final result = await _router.send(
        frame.encode(),
        toPeer: toPeer,
        // Never over the relay. Paying a third party to carry mail defeats the
        // point of couriering, which is to move a message without one.
        allowRelay: false,
      );
      if (!result.accepted) return false;
    }
    return true;
  }

  /// Reads an inbound courier frame, or null if it is not one.
  ///
  /// Anybody in range can send this, so malformed input costs one dropped
  /// frame and nothing else.
  CourierEnvelope? receiveCourier(Uint8List payload) =>
      CourierEnvelope.decode(payload);

  /// Files a message that arrived inside a courier envelope.
  ///
  /// The envelope is already open — unsealing it needs the Noise static key,
  /// which lives above this layer — so what arrives here is the same
  /// [AppEnvelope] a direct message carries. Returns whether it was new.
  ///
  /// Reusing the ordinary envelope is the point: a message that travels both
  /// by radio and by courier is deduplicated against itself by the same
  /// (sender, sequence) table, and is shown once.
  bool acceptCourieredPayload({
    required String conversationId,
    required Uint8List payload,
    required TransportKind via,
  }) => _accept(conversationId, payload, via: via, viaCourier: true) != null;

  /// The next sequence number this device will use.
  ///
  /// Public so a message handed to a courier is drawn from the same counter as
  /// one sent over a radio. Two counters would collide, and a collision means
  /// the recipient silently discards a real message as a duplicate.
  int nextSequence() => ++_sequence;

  // --------------------------------------------------------------- history

  /// Asks the room what was said before we arrived.
  ///
  /// Broadcast, because there is no single member to ask and no way to know who
  /// is listening. Encrypted with the room key like everything else in a room.
  Future<void> sendHistoryRequest(int roomId, HistoryRequest request) =>
      _sendRoomControl(roomId, FrameType.historyRequest, request.encode());

  /// Answers such a request.
  ///
  /// Unicast when the asker's radio peer is known, because only one device
  /// wanted this and broadcasting it would hand the whole bundle to everyone
  /// in range for no reason.
  Future<void> sendHistoryReply(
    int roomId,
    HistoryBundle bundle, {
    String? toPeer,
  }) => _sendRoomControl(
    roomId,
    FrameType.historyReply,
    bundle.encode(),
    toPeer: toPeer,
  );

  /// Broadcasts a signed statement by a room's owner.
  ///
  /// Encrypted with the room key, so only members can read it — and advisory
  /// even then; see [RoomControl].
  Future<void> sendRoomControl(int roomId, Uint8List payload) =>
      _sendRoomControl(roomId, FrameType.roomControl, payload);

  Future<void> _sendRoomControl(
    int roomId,
    FrameType type,
    Uint8List payload, {
    String? toPeer,
  }) async {
    final room = _rooms[roomId];
    if (room == null) return;

    final sealed = await room.encrypt(_padding.pad(payload));
    for (final frame in fragmentFrame(
      Frame(
        type: type,
        // Short. Catching up is a local courtesy between people in the same
        // place; flooding it across a whole mesh would cost far more than it
        // is worth to whoever is out of earshot.
        ttl: 3,
        flags: const FrameFlags(encrypted: true),
        msgId: _newMsgId(),
        srcHash: _localHash,
        dstHash: roomId,
        payload: sealed,
      ),
    )) {
      // Never over the relay. History is a room-local courtesy, and pushing a
      // whole back catalogue through a third party is not one.
      final result = await _router.send(
        frame.encode(),
        toPeer: toPeer,
        allowRelay: false,
      );
      if (!result.accepted) return;
    }
  }

  /// Decrypts a room control payload, or null if we cannot read it.
  ///
  /// Not being able to read it is ordinary: room traffic for a room this device
  /// is not in passes through constantly and is relayed without being
  /// understood.
  Future<Uint8List?> openRoomControl(int roomId, Uint8List ciphertext) async {
    final room = _rooms[roomId];
    if (room == null) return null;

    try {
      return _padding.strip(await room.decrypt(ciphertext));
    } on DecryptFailure {
      return null;
    } on ReplayedMessage {
      return null;
    } on FrameFormatException {
      return null;
    }
  }

  /// The messages this device would share with somebody catching up.
  ///
  /// Only what was received or sent in that room, and only within the window
  /// asked for. [HistoryBundle.of] applies the count and size ceilings.
  HistoryBundle historyFor(
    String conversationId, {
    required Duration since,
  }) => HistoryBundle.of(
    [
      for (final message in _store.messages(conversationId))
        // Both fields are needed to deduplicate on the other side, and a voice
        // note is deliberately excluded: its body is base64 audio, it would
        // dominate the size ceiling on its own, and the duration that makes it
        // playable is not carried here.
        if (message.sequence != null &&
            message.senderKey != null &&
            message.voiceDurationMs == null)
          HistoryEntry(
            senderKey: message.senderKey!,
            sequence: message.sequence!,
            sentAt: message.createdAt,
            body: message.body,
          ),
    ],
    since: since,
    now: _clock(),
  );

  /// Stores messages someone shared to catch us up. Returns how many were new.
  ///
  /// Deduplicated against the same (sender, sequence) table that suppresses a
  /// message arriving over two radios, so overlapping answers from several
  /// members cost storage once.
  int applyHistory(String conversationId, HistoryBundle bundle) {
    var added = 0;

    for (final entry in bundle.entries) {
      // Our own words, handed back to us by somebody who kept them. Re-adding
      // them would produce a duplicate attributed to nobody.
      if (_bytesEqual(entry.senderKey, _senderKey)) continue;
      if (!_store.acceptMessage(entry.senderKey, entry.sequence)) continue;

      _store.insertMessage(
        StoredMessage(
          id: _newMessageId(),
          conversationId: conversationId,
          body: entry.body,
          fromMe: false,
          state: MessageState.delivered,
          createdAt: entry.sentAt,
          senderKey: entry.senderKey,
        ),
        countUnread: false,
      );
      added++;
    }

    return added;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Records that a peer confirmed receipt.
  void acknowledge(String messageId, {bool read = false}) {
    _store.updateMessageState(
      messageId,
      read ? MessageState.read : MessageState.delivered,
    );
    _store.dequeue(messageId);
    _events.add(
      SendOutcome(
        messageId: messageId,
        state: read ? MessageState.read : MessageState.delivered,
        transport: null,
      ),
    );
  }

  /// Records that a peer confirmed receipt of the message we sent as
  /// [sequence].
  ///
  /// Acks travel by sequence, not by message id: the id is a local row key and
  /// means nothing on the other device. Only the sender's own sequence
  /// identifies the message on both sides.
  bool acknowledgeSequence(
    int sequence, {
    bool read = false,

    /// Who sent the acknowledgement. Enables the delivery cascade below.
    int? fromHash,
  }) {
    if (read) {
      // A read receipt names the newest message the peer looked at, and it
      // arrives after the delivery ack has already dequeued that message — so
      // this cannot go through the outbox the way a delivery ack does.
      final changed = _store.markReadThrough(sequence);
      if (changed) {
        _events.add(
          SendOutcome(
            messageId: _store.messageIdForSequence(sequence) ?? '',
            state: MessageState.read,
            transport: null,
          ),
        );
      }
      return changed;
    }

    final messageId = _store.messageIdForSequence(sequence);
    if (messageId == null) return false;
    acknowledge(messageId);

    // Everything still queued for the *same person* with an earlier sequence
    // arrived too. This is what makes batching work: ten messages travel in
    // one frame and are acknowledged by one receipt, and without the cascade
    // nine of them would sit on "sent" and be retried until they expired.
    //
    // Scoped to [fromHash] deliberately. Cascading across recipients would let
    // an ack from one person mark another person's messages delivered.
    if (fromHash != null) {
      for (final earlier in _store.dueRetries(_clock(), ignoreBackoff: true)) {
        if (earlier.targetHash == fromHash && earlier.sequence < sequence) {
          acknowledge(earlier.messageId);
        }
      }
    }
    return true;
  }

  Future<void> dispose() => _events.close();

  String _newMessageId() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  MsgId _newMsgId() => newMsgId();

  /// A fresh transmission id.
  ///
  /// Public because the runtime builds announce and ack frames of its own, and
  /// they must be drawn from the same source: a predictable id would let anyone
  /// nearby pre-poison a relay's dedup table and silence a device.
  MsgId newMsgId() => MsgId(
    Uint8List.fromList(List<int>.generate(8, (_) => _random.nextInt(256))),
  );
}
