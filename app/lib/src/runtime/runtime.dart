import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart' show publicKeyOf;
import 'package:core_identity/core_identity.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:data/data.dart' as db;
import 'package:messaging/messaging.dart';
import 'package:transport_api/transport_api.dart';
import 'package:transport_nostr/transport_nostr.dart';
import 'package:transport_wifi/transport_wifi.dart';

import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/runtime/commands.dart';
import 'package:relay_app/src/runtime/event_log.dart';
import 'package:relay_app/src/runtime/haptics.dart';
import 'package:relay_app/src/domain/announce_trust.dart';
import 'package:relay_app/src/domain/mentions.dart';
import 'package:relay_app/src/domain/models.dart' as ui;
import 'package:relay_app/src/domain/pairing_payload.dart';
import 'package:relay_app/src/domain/power_mode.dart';
import 'package:relay_app/src/runtime/voice.dart';

/// What running a command produced.
///
/// [notice] is shown to the user on their own screen only — it is never sent
/// anywhere, because the answer to "who is nearby" is nobody else's business.
@immutable
class CommandOutcome {
  const CommandOutcome({this.notice, this.openConversation});

  final String? notice;
  final String? openConversation;
}

/// A room the user has joined.
class JoinedRoom {
  const JoinedRoom({
    required this.code,
    required this.roomId,
    required this.conversationId,
  });

  final String code;
  final int roomId;
  final String conversationId;
}

/// Why a message cannot be sent by courier, when it cannot.
///
/// Separate values rather than one failure, because the user's next move is
/// different in each case and "could not send" tells them none of it.
enum CourierRefusal {
  /// A room. An envelope is sealed to exactly one recipient's key; there is no
  /// such thing as sealing one to a group.
  notADirectMessage(
    'Only one person at a time can be sent a message this way.',
  ),

  /// This device has never heard this person announce, so it does not have the
  /// X25519 key their mail would be sealed to. There is no fallback — guessing
  /// would produce mail nobody can ever open.
  recipientKeyUnknown(
    'You have not been near this person yet, so their phone has never told '
    'yours how to lock a message for them.',
  ),

  /// Nobody trusted is in range to hand it to. Ordinary, and temporary.
  noCarriers(
    'Nobody you trust is nearby to carry it. Your phone will keep trying to '
    'send it the normal way.',
  ),

  /// Stealth mode. Handing an envelope to somebody is a transmission.
  stealth('Your phone is not transmitting anything at the moment.');

  const CourierRefusal(this.explanation);

  /// Plain-language reason, shown to the user as-is.
  final String explanation;
}

/// Everything below the widgets, assembled.
///
/// This is the only class that knows the full path from a tap to bytes on a
/// radio and back. Each layer under it stays independently testable because
/// none of them reach across this boundary; the price is that this class is
/// large, and the mitigation is that it holds almost no logic of its own —
/// it decodes, dispatches, and pushes results into [AppState].
class MeshRuntime {
  MeshRuntime({
    required this.state,
    required this.store,
    required Transport mesh,
    required this.identity,
    required Uint8List noiseStaticKey,
    required this.localAddressHash,

    /// The local-network transport, when the device has one.
    ///
    /// Optional because it is an opportunistic extra: it works only where a
    /// shared Wi-Fi already exists, and the app has to be complete without it.
    WifiTransport? wifi,
    Transport? relay,
    DateTime Function()? clock,
    EventLog? log,
  }) : _bluetooth = mesh,
       _wifi = wifi,
       // Presented to everything above as one mesh. Which radio carries a
       // frame is a routing decision, not something the message layer, the
       // session layer or the UI should have to reason about.
       _mesh = CompositeTransport({
         bluetoothTransportName: mesh,
         // Omitted entirely when there is no Wi-Fi transport, so the composite
         // never holds a radio that cannot work.
         wifiTransportName: ?wifi,
       }),
       _noiseStaticKey = noiseStaticKey,
       log = log ?? EventLog(clock: clock ?? DateTime.now),
       _clock = clock ?? DateTime.now {
    _router = TransportRouter(mesh: _mesh, relay: relay);
    _sessions = SessionManager(
      staticPrivateKey: noiseStaticKey,
      localAddressHash: localAddressHash,
    );
    _messages = MessageService(
      store: store,
      router: _router,
      sessions: _sessions,
      // Four bytes of the identity key, which is what the envelope carries.
      senderKey: Uint8List.sublistView(identity.publicKey, 0, 4),
      localAddressHash: localAddressHash,
      clock: _clock,
      relayAllowed: relayAllowedFor,
      retryWindow: retryWindowFor,
    );
  }

  final AppState state;
  final db.LocalStore store;

  /// Local-only record of what the mesh has been doing. Never uploaded.
  final EventLog log;

  final MeshIdentity identity;
  final int localAddressHash;

  /// Names for the two local radios inside the composite. They become the
  /// prefix on every peer id, so changing one changes stored peer identities.
  static const bluetoothTransportName = 'ble';
  static const wifiTransportName = 'wifi';

  /// The individual radios, kept so the UI can report each one honestly.
  /// [_mesh] is the merged view everything else uses.
  final Transport _bluetooth;
  final WifiTransport? _wifi;

  final CompositeTransport _mesh;
  late final TransportRouter _router;
  final DateTime Function() _clock;

  /// The X25519 private key Noise uses, kept so courier envelopes addressed to
  /// this device can be opened. Never leaves this object.
  final Uint8List _noiseStaticKey;

  late final SessionManager _sessions;
  late final MessageService _messages;

  late final Reassembler _reassembler = Reassembler(
    clock: () => _clock().difference(DateTime.fromMillisecondsSinceEpoch(0)),
  );
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Serialises inbound handling.
  ///
  /// Frames arrive back to back and handling one is asynchronous, so without
  /// this a message can overtake the handshake that produces the key to read
  /// it — and it does, every time, because a sender flushes queued messages
  /// the instant the handshake completes.
  Future<void> _inboundChain = Future<void>.value();

  /// Peer id to the address hash it announced. Built from announce frames,
  /// which are the only thing that ties a radio-level peer id to a mesh
  /// address; the transport itself has no idea the two relate.
  final _peerAddress = <String, int>{};
  final _peerNickname = <String, String>{};
  final _addressPeer = <int, String>{};

  /// Address hashes we refuse to show the user.
  ///
  /// Derived once from the blocked identity keys rather than checked against
  /// the database per frame: this is consulted on every inbound frame in a
  /// crowd, and a query there would be a real cost.
  final _blockedHashes = <int>{};

  /// Address hashes the user has chosen, and the names to show for them.
  ///
  /// Derived from the stored identity keys for the same reason as
  /// [_blockedHashes]: this is consulted on every send and on every rebuild of
  /// the peer list, and a query in either place would be a real cost.
  final _favouriteHashes = <int>{};
  final _favouriteNames = <int, String>{};

  /// Full identity keys, learned from announce frames.
  ///
  /// Needed because blocking and verification both key on the real public key
  /// rather than the truncated address hash, which collides.
  final _peerIdentity = <String, Uint8List>{};

  /// X25519 keys, learned from announce frames. What mail is sealed to.
  final _peerNoiseKey = <String, Uint8List>{};

  /// Who is reachable, as this runtime understands it.
  ///
  /// Kept here rather than read straight from the transport because a peer can
  /// become unreachable for reasons the transport does not know about: a `leave`
  /// frame, or a relayed peer that was never a radio link in the first place.
  final _reachable = <String, int>{};

  final _rooms = <String, JoinedRoom>{};

  /// The newest sequence received from each peer, by conversation.
  ///
  /// A read receipt names one message, and the sender treats everything before
  /// it as read too. Holding only the newest is therefore all that is needed,
  /// and it means opening a conversation costs one frame rather than one per
  /// unread message.
  final _newestInbound = <String, ({int address, int sequence})>{};

  /// Only ever used to spread history replies out in time, never for anything
  /// a secret depends on.
  final _random = Random();

  SessionManager get sessions => _sessions;
  MessageService get messages => _messages;
  TransportRouter get router => _router;

  /// Other people's mail, held while this device carries it.
  late final CourierStore couriers = CourierStore(store: store, clock: _clock);

  /// This device's X25519 public key: what other people seal mail to.
  ///
  /// Derived rather than stored. It is public by construction — every Noise
  /// handshake already reveals it to whoever we speak to — so publishing it in
  /// an announce gives away nothing that talking does not.
  late final Future<Uint8List> noiseStaticPublicKey = publicKeyOf(
    _noiseStaticKey,
  );

  bool _started = false;

  // ------------------------------------------------------------- lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _subscriptions
      ..add(_mesh.inbound.listen(_onInbound))
      ..add(_mesh.peerEvents.listen(_onPeerEvent))
      ..add(_mesh.statusChanges.listen((_) => _publishStatus()))
      ..add(_messages.outcomes.listen(_onSendOutcome));

    for (final peer in _mesh.peers) {
      _reachable[peer.peerId] = peer.hopDistance;
    }

    await _reloadBlocked();
    await _reloadFavourites();
    _loadConversations();
    _publishPeers();
    log.info('Mesh started');
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _dummyTimer?.cancel();
    _dummyTimer = null;
    _purgeUnkeptRooms();
    for (final timer in _pendingHistoryReplies.values) {
      timer.cancel();
    }
    _pendingHistoryReplies.clear();
    await _messages.dispose();
    _started = false;
  }

  // -------------------------------------------------------------- presence

  /// This device's announce, signed, exactly as it goes on the wire.
  ///
  /// One builder for both paths. Dart sends this frame directly; native
  /// rebroadcasts the same bytes on its own timer, because Dart is not alive
  /// in the background and a beacon that stops when the app closes is not a
  /// beacon. Two builders would be two wire formats, and they would drift.
  Future<Announce> _signedAnnounce() async {
    final unsigned = Announce(
      nickname: state.nickname,
      identityKey: identity.publicKey,
      // Published so people who meet us can seal mail for us and hand it to
      // whoever might see us next. Public by construction — it is the key
      // every Noise handshake already reveals to whoever we speak to — but
      // stating it here is what makes couriering possible at all.
      noiseStaticKey: await noiseStaticPublicKey,
    );

    // Signed over the nickname and both keys. Without this an announce is an
    // unauthenticated claim, and the one that matters is the Noise key: anyone
    // in range could rebind a person's courier key to their own by
    // broadcasting that person's identity key — which is public — beside their
    // own X25519 key, and mail for that person would be sealed to the
    // attacker. Pinning a contact does not help, because verification covers
    // the identity key and nothing binds the Noise key to it.
    return unsigned.withSignature(
      await identity.sign(Announce.signingInput(unsigned.encodeUnsigned())),
    );
  }

  /// The beacon native rebroadcasts while Dart is not running.
  ///
  /// Returned split the way the platform API takes it: native supplies the
  /// length-prefixed nickname and appends [keyBlob] byte for byte. The
  /// nickname is already truncated here, because the signature covers those
  /// exact bytes — native re-cutting the name would invalidate it.
  Future<({String nickname, Uint8List keyBlob})> presenceBeacon() async {
    final announce = await _signedAnnounce();
    final payload = announce.encode();
    // payload[0] is the nickname length, so everything past the name is the
    // identity key, the Noise key and the signature.
    return (
      nickname: announce.nickname,
      keyBlob: Uint8List.sublistView(payload, 1 + payload[0]),
    );
  }

  /// Broadcasts who we are.
  ///
  /// Plaintext by necessity: strangers cannot discover us if they cannot read
  /// it. It carries a nickname, two public keys and a signature over all
  /// three, never a long-term secret.
  Future<void> announcePresence() async {
    if (state.status.stealthMode) return;

    final payload = (await _signedAnnounce()).encode();

    await _router.send(
      Frame(
        type: FrameType.announce,
        // Zero, not one. Presence is local: a neighbour delivers a broadcast
        // upward before the hop counter is looked at, so everyone in range
        // still sees this, and nobody rebroadcasts it. At ttl 1 every
        // neighbour would relay it once and presence would travel two hops,
        // filling the mesh with beacons from people nobody can reach.
        ttl: 0,
        flags: const FrameFlags(),
        msgId: _messages.newMsgId(),
        srcHash: localAddressHash,
        dstHash: broadcastHash,
        payload: payload,
      ).encode(),
    );
  }

  // -------------------------------------------------------------- inbound

  void _onInbound(InboundFrame inbound) {
    final Frame frame;
    try {
      frame = Frame.decode(inbound.bytes);
    } on FrameFormatException {
      // Malformed frames are ordinary in a crowd: another app, an older build,
      // a corrupted write. Dropping silently is correct.
      return;
    }

    if (frame.srcHash == localAddressHash) return;

    // One check, at the only place every inbound frame passes through. Note
    // this is *after* the native relay has already decided to forward it: the
    // block governs what the user sees, not what the mesh carries.
    if (_blockedHashes.contains(frame.srcHash)) {
      // Also drop them from the peer table. A radio link can exist before
      // anyone has said who they are, so a blocked person first appears as an
      // anonymous peer; this is the moment we learn the link belongs to them.
      handlePeerLost(inbound.fromPeer);
      return;
    }

    // Everything goes through the reassembler, fragmented or not. It returns
    // whole messages immediately for unfragmented frames, which keeps one code
    // path instead of two that can drift apart.
    final whole = _reassembler.offer(frame);
    if (whole == null) return;

    _inboundChain = _inboundChain.then(
      (_) => _dispatch(whole, frame.ttl, inbound.fromPeer),
      // One bad frame must not break the chain and silence the device.
      onError: (Object _) {},
    );
  }

  /// Completes once everything already received has been handled. Tests use it;
  /// production code has no reason to wait.
  @visibleForTesting
  Future<void> get inboundSettled => _inboundChain;

  Future<void> _dispatch(
    ReassembledMessage message,
    int ttl,
    String fromPeer,
  ) async {
    switch (message.type) {
      case FrameType.announce:
        await _handleAnnounce(message, fromPeer);
      case FrameType.handshake:
        await _handleHandshake(message, fromPeer);
      case FrameType.message:
      case FrameType.voice:
      case FrameType.room:
        await _handleMessage(message, ttl, fromPeer);
      case FrameType.ack:
        _handleAck(message);
      case FrameType.batch:
        await _handleBatch(message, ttl, fromPeer);
      case FrameType.roomControl:
        await _handleRoomControl(message);
      case FrameType.historyRequest:
        await _handleHistoryRequest(message, fromPeer);
      case FrameType.historyReply:
        await _handleHistoryReply(message);
      case FrameType.courier:
        await _handleCourier(message, fromPeer);
      case FrameType.leave:
        handlePeerLost(fromPeer);
      case FrameType.fragment:
        // `fragment` never survives reassembly: a completed message carries the
        // original type from its sub-header. Reaching here means malformed
        // input, and there is nothing sensible to do with it.
        break;
    }
  }

  Future<void> _handleAnnounce(
    ReassembledMessage frame,
    String fromPeer,
  ) async {
    final announce = Announce.decode(frame.payload);
    if (announce == null) return;

    final trust = await checkAnnounce(announce, frame.payload);
    if (trust == AnnounceTrust.forged) return;

    // The address mapping is taken either way. It only says which radio peer
    // is claiming which routing hash, a claim the handshake path already
    // accepts unverified, and getting it wrong means a direct message goes
    // nowhere rather than somewhere else — Noise authenticates the session
    // itself, not this table.
    _peerAddress[fromPeer] = frame.srcHash;
    _addressPeer[frame.srcHash] = fromPeer;
    // An announce is proof of reachability in its own right. The transport may
    // not have raised a discovery event — a relayed announce never will.
    _reachable[fromPeer] ??= 1;

    // Everything below is a claim about *who* this is, and an unsigned
    // announce cannot support one. Believing the nickname would let anyone in
    // range rename a verified contact's conversation by broadcasting; believing
    // the identity key would let them be treated as a trusted courier and
    // handed other people's mail; believing the Noise key would redirect that
    // person's mail to whoever sent this.
    if (trust != AnnounceTrust.signed) {
      _publishPeers();
      return;
    }

    final nickname = announce.nickname;
    if (!_peerNickname.containsKey(fromPeer) && nickname.isNotEmpty) {
      log.info('$nickname came into range');
    }

    if (nickname.isNotEmpty) _peerNickname[fromPeer] = nickname;

    // Held so blocking and verification can name a person by their real key
    // rather than by a 32-bit hash that two people can share.
    _peerIdentity[fromPeer] = announce.identityKey;

    // What mail for this person is sealed to. Stored rather than merely held
    // in memory, because the point of a courier is to reach somebody who is
    // not here — which will usually be after a restart.
    final noiseKey = announce.noiseStaticKey;
    if (noiseKey != null) {
      _peerNoiseKey[fromPeer] = noiseKey;
      store.saveNoiseKey(
        publicKey: announce.identityKey,
        noiseStaticKey: noiseKey,
      );
    }

    _publishPeers();

    // Meeting somebody is the only chance to hand over what we are holding for
    // them, and the only chance to ask them to carry something. Not awaited:
    // an announce must not be held up by a radio write.
    unawaited(offerMail(fromPeer));
  }

  Future<void> _handleHandshake(
    ReassembledMessage frame,
    String fromPeer,
  ) async {
    _peerAddress[fromPeer] = frame.srcHash;
    _addressPeer[frame.srcHash] = fromPeer;

    final established = await _messages.handleHandshake(
      peerHash: frame.srcHash,
      message: frame.payload,
      peerId: fromPeer,
    );

    // Anything queued for this peer was waiting on exactly this, so it goes now
    // rather than waiting out a backoff timer that no longer means anything.
    if (established) {
      log.info(
        'Encrypted channel established with '
        '${_peerNickname[fromPeer] ?? 'a nearby device'}',
      );
      await _messages.flushFor(frame.srcHash);
      _loadConversations();
    }
  }

  Future<void> _handleMessage(
    ReassembledMessage frame,
    int ttl,
    String fromPeer,
  ) async {
    final conversationId = frame.type == FrameType.room
        ? _roomConversationId(frame.dstHash)
        : conversationIdForAddress(frame.srcHash);

    if (frame.type == FrameType.room && !_rooms.containsKey(conversationId)) {
      // Room traffic for a room we are not in. We may still have relayed it;
      // we simply cannot read it, and must not pretend otherwise.
      return;
    }

    _ensureConversationRow(conversationId, frame, fromPeer);

    final stored = await _messages.receive(
      conversationId: conversationId,
      ciphertext: frame.payload,
      // A room is addressed by its own id, so that is the key its cipher is
      // registered under; a direct message is keyed by whoever sent it.
      senderHash: frame.type == FrameType.room ? frame.dstHash : frame.srcHash,
      via: TransportKind.mesh,
      hopCount: maxTtl - ttl + 1,
    );
    if (stored == null) return;

    _loadConversations();
    _feelInbound(stored.message.body);

    // Acknowledge only what we could actually read. Acking anything else would
    // tell the sender their message landed when it did not. Rooms are not
    // acked at all: there is no single recipient to speak for the group.
    if (frame.type != FrameType.room) {
      // Remembered so opening the conversation can send one read receipt
      // naming the newest message, rather than one per unread message.
      _newestInbound[conversationId] = (
        address: frame.srcHash,
        sequence: stored.sequence,
      );
      await _sendAck(frame.srcHash, stored.sequence, fromPeer);
    }
  }

  /// Buzzes for a message that named the user.
  ///
  /// Only for a mention, and only on arrival. In a busy room an unread count is
  /// background noise and a direct request for attention is not — and a phone
  /// that buzzes at every message is one people put on silent, after which the
  /// mesh has no way to reach them at all.
  void _feelInbound(String body) {
    if (Mentions.addresses(body, state.nickname)) {
      unawaited(Haptics.mentioned());
    }
  }

  /// Several messages that travelled in one frame.
  ///
  /// Each one is stored and acknowledged individually, so nothing downstream —
  /// the conversation list, the read receipts, the sender's message states —
  /// has to know that they shared a ride.
  Future<void> _handleBatch(
    ReassembledMessage frame,
    int ttl,
    String fromPeer,
  ) async {
    final conversationId = conversationIdForAddress(frame.srcHash);
    _ensureConversationRow(conversationId, frame, fromPeer);

    final received = await _messages.receiveBatch(
      conversationId: conversationId,
      ciphertext: frame.payload,
      senderHash: frame.srcHash,
      via: TransportKind.mesh,
      hopCount: maxTtl - ttl + 1,
    );
    if (received.isEmpty) return;

    _loadConversations();
    for (final message in received) {
      _feelInbound(message.message.body);
    }

    // One acknowledgement, naming the newest. The sender treats everything
    // before it as delivered too, so a batch of ten costs one ack rather than
    // undoing the saving it just made.
    final newest = received.last;
    _newestInbound[conversationId] = (
      address: frame.srcHash,
      sequence: newest.sequence,
    );
    await _sendAck(frame.srcHash, newest.sequence, fromPeer);
  }

  /// An acknowledgement carries the sender's own sequence number and a flag
  /// byte. The flag distinguishes "this device received it" from "a person
  /// looked at it", which are different claims and must not be collapsed.
  static const int _ackPayloadLength = 5;
  static const int _ackSequenceLength = 4;
  static const int _ackReadBit = 0x01;

  void _handleAck(ReassembledMessage frame) {
    if (frame.payload.length < _ackSequenceLength) return;
    final sequence = ByteData.view(
      frame.payload.buffer,
      frame.payload.offsetInBytes,
      _ackSequenceLength,
    ).getUint32(0, Endian.big);

    final read =
        frame.payload.length > _ackSequenceLength &&
        frame.payload[_ackSequenceLength] & _ackReadBit != 0;

    if (_messages.acknowledgeSequence(
      sequence,
      read: read,
      fromHash: frame.srcHash,
    )) {
      _loadConversations();
    }
  }

  Future<void> _sendAck(
    int peerHash,
    int sequence,
    String peerId, {
    bool read = false,
  }) {
    final payload = Uint8List(_ackPayloadLength);
    ByteData.view(payload.buffer).setUint32(0, sequence, Endian.big);
    payload[_ackSequenceLength] = read ? _ackReadBit : 0;

    // Plaintext, and deliberately so: an ack names a message only by a counter
    // the sender chose, which reveals nothing an observer could not get by
    // counting frames.
    return _router.send(
      Frame(
        type: FrameType.ack,
        ttl: maxTtl,
        flags: const FrameFlags(),
        msgId: _messages.newMsgId(),
        srcHash: localAddressHash,
        dstHash: peerHash,
        payload: payload,
      ).encode(),
      toPeer: peerId,
    );
  }

  // --------------------------------------------------------------- sending

  /// Sends a text message in an existing conversation.
  Future<void> sendText(
    String conversationId,
    String body, {
    int? voiceDurationMs,
  }) async {
    final room = _rooms[conversationId];
    final targetHash = room?.roomId ?? _addressForConversation(conversationId);
    if (targetHash == null) return;

    // Blocking cuts both ways. Continuing to send while ignoring their replies
    // would be a strange half-state, and it would keep telling them where and
    // when we are.
    if (room == null && _blockedHashes.contains(targetHash)) return;

    // Held for a random moment when cover traffic is on, so the frame does not
    // coincide with the keystroke that produced it.
    await _coverDelay();

    await _messages.send(
      conversationId: conversationId,
      body: body,
      targetHash: targetHash,
      targetPeerId: room == null ? _addressPeer[targetHash] : null,
      voiceDurationMs: voiceDurationMs,
    );
    _loadConversations();
  }

  /// Sends a recorded voice note.
  ///
  /// The audio is base64'd into the message body rather than given its own
  /// wire type. It costs a third more bytes, which for a 16 kbit/s note is a
  /// few kilobytes, and in exchange the storage schema, the outbox, the
  /// retry path and the dedup table all work on it unchanged.
  Future<void> sendVoice(String conversationId, VoiceNote note) => sendText(
    conversationId,
    base64Encode(note.bytes),
    voiceDurationMs: note.durationMs,
  );

  /// Recovers the audio from a voice message, or null if the body is not
  /// decodable — which happens when a note was truncated in transit.
  static Uint8List? voiceBytesOf(ui.Message message) {
    if (!message.isVoice) return null;
    try {
      return base64Decode(message.body);
    } on FormatException {
      return null;
    }
  }

  /// Retries everything the outbox says is due.
  ///
  /// Called when a peer appears, when a handshake completes, and on a timer:
  /// all three are moments when something previously unsendable may now go.
  Future<int> retryPending() async {
    final retried = await _messages.retryDue();
    _loadConversations();
    return retried;
  }

  // ----------------------------------------------------------------- rooms

  /// Joins a room by code, deriving its key and registering it.
  Future<JoinedRoom> joinRoom(String rawCode) async {
    final code = RoomCode.parse(rawCode);
    final derived = await deriveRoomKey(code);
    final conversationId = _roomConversationId(derived.roomId);

    _messages.registerRoom(derived.roomId, RoomCipher(derived.key));

    store.upsertConversation(
      id: conversationId,
      kind: db.ConversationKind.room,
      title: code.value,
      roomCode: code.value,
    );

    final joined = JoinedRoom(
      code: code.value,
      roomId: derived.roomId,
      conversationId: conversationId,
    );
    _rooms[conversationId] = joined;
    _loadConversations();

    // Ask what was said before we arrived. Not awaited: joining must not wait
    // on anybody answering, and most of the time nobody will.
    unawaited(requestRoomHistory(conversationId));
    return joined;
  }

  // ------------------------------------------------------------ favourites

  /// How long a favourite's undelivered message keeps being retried.
  ///
  /// A week, against a day for everyone else. "I'll see them next week" is a
  /// normal thing to be true of someone the user chose, and is not worth
  /// assuming about a stranger whose message would otherwise sit in the outbox
  /// costing retries forever.
  static const Duration favouriteRetryWindow = Duration(days: 7);

  /// Marks someone as chosen.
  ///
  /// This is the only thing that unlocks the internet relay for them. That is
  /// deliberate: the relay hands a third party the fact that two identities are
  /// talking and when, which is metadata the mesh never produces, so it is
  /// spent on people the user picked rather than on everyone in radio range.
  Future<void> favourite(Uint8List identityKey, {String nickname = ''}) async {
    store.setFavourite(
      publicKey: identityKey,
      favourite: true,
      nickname: nickname,
      at: _clock(),
    );
    await _reloadFavourites();
    _publishPeers();
  }

  Future<void> unfavourite(Uint8List identityKey) async {
    store.setFavourite(publicKey: identityKey, favourite: false);
    await _reloadFavourites();
    _publishPeers();
  }

  /// Whether the user has chosen this person.
  bool isFavouriteAddress(int addressHash) =>
      _favouriteHashes.contains(addressHash);

  /// Whether the internet relay may be used to reach [addressHash].
  ///
  /// Passed to [MessageService] as a callback rather than resolved once, so
  /// starring someone changes the route of a message already sitting in the
  /// outbox.
  bool relayAllowedFor(int addressHash) => isFavouriteAddress(addressHash);

  Duration retryWindowFor(int addressHash) =>
      _favouriteHashes.contains(addressHash)
      ? favouriteRetryWindow
      : MessageService.outboxLifetime;

  /// A stable peer id for a favourite who is not currently reachable.
  ///
  /// Distinct from any radio peer id, so a favourite walking back into range
  /// produces a second, real entry rather than colliding with this one.
  static String favouritePeerId(int addressHash) =>
      'fav:${addressHash.toRadixString(16)}';

  Future<void> _reloadFavourites() async {
    // Synthetic entries for people who are no longer favourites have to go, or
    // an unfavourited peer would stay on screen until the app restarted.
    for (final hash in _favouriteHashes) {
      _peerAddress.remove(favouritePeerId(hash));
    }
    _favouriteHashes.clear();
    _favouriteNames.clear();

    for (final entry in store.favourites()) {
      final hash = await addressHashOf(entry.publicKey);
      _favouriteHashes.add(hash);
      if (entry.nickname.isNotEmpty) _favouriteNames[hash] = entry.nickname;
      // Registered so tapping an out-of-range favourite opens the conversation
      // and queues a message, rather than doing nothing.
      _peerAddress[favouritePeerId(hash)] = hash;
    }
  }

  // --------------------------------------------------------- cover traffic

  CoverTrafficPolicy _cover = const CoverTrafficPolicy.off();
  Timer? _dummyTimer;

  CoverTrafficPolicy get coverTraffic => _cover;

  /// Turns traffic-pattern cover on or off.
  ///
  /// Off by default. It costs battery and airtime — on this phone and on every
  /// phone that relays the extra frames — and what it buys is partial: a
  /// determined observer watching a quiet mesh long enough still wins. That
  /// trade is the user's to make, so the switch states the cost.
  void setCoverTraffic(bool enabled) {
    _cover = enabled
        ? const CoverTrafficPolicy(enabled: true)
        : const CoverTrafficPolicy.off();
    _dummyTimer?.cancel();
    _dummyTimer = null;
    if (enabled) _scheduleDummy();
  }

  void _scheduleDummy() {
    final delay = _cover.nextDummyDelay(_random);
    if (delay == null) return;
    _dummyTimer = Timer(delay, () async {
      await sendCoverFrame();
      // Rescheduled from inside, never on a fixed period: a dummy every
      // hundred and twenty seconds exactly is trivially filtered back out.
      if (_cover.enabled) _scheduleDummy();
    });
  }

  /// Emits one meaningless frame, if there is anybody to send it to.
  ///
  /// Returns whether one went. Public so a test can drive it without waiting
  /// out a timer.
  @visibleForTesting
  Future<bool> sendCoverFrame() async {
    if (!_cover.enabled) return false;

    // Only people this device already has a session with. Opening one purely
    // to send noise would introduce this device to a stranger, which is the
    // opposite of what cover traffic is for.
    final candidates = [
      for (final hash in _messages.dummyCandidates)
        if (!_blockedHashes.contains(hash)) hash,
    ];
    if (candidates.isEmpty) return false;

    return _messages.sendDummy(candidates[_random.nextInt(candidates.length)]);
  }

  /// Holds a real message back by a random moment, when cover is on.
  ///
  /// Without it, a frame leaving within milliseconds of a keystroke — or of a
  /// reply arriving — times the conversation for anyone watching, whatever the
  /// encryption does.
  Future<void> _coverDelay() async {
    final delay = _cover.nextDelay(_random);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  // -------------------------------------------------------------- commands

  /// Runs whatever the user typed into the composer.
  ///
  /// Everything a command can do is also reachable by tapping, deliberately:
  /// commands are a shortcut for people who like them, never the only way to
  /// get somewhere. A line that is not a command is sent as an ordinary
  /// message, and a line that *looks* like one and is not is refused rather
  /// than sent — a mistyped `/blcok sara` broadcast to a room would announce
  /// the intent to everyone in it.
  Future<CommandOutcome> runCommand(
    String input, {
    required String conversationId,
  }) async {
    final command = Commands.parse(input);

    switch (command) {
      case PlainMessage(:final body):
        if (body.isEmpty) return const CommandOutcome();
        await sendText(conversationId, body);
        return const CommandOutcome();

      case BadCommand(:final message):
        return CommandOutcome(notice: message);

      case HelpCommand():
        return const CommandOutcome(notice: Commands.help);

      case JoinCommand(:final code):
        try {
          final joined = await joinRoom(code);
          return CommandOutcome(openConversation: joined.conversationId);
        } on FormatException catch (error) {
          return CommandOutcome(notice: error.message);
        }

      case WhoCommand():
        final names = [
          for (final peer in state.peers)
            if (peer.isReachable) peer.nickname,
        ]..sort();
        return CommandOutcome(
          notice: names.isEmpty
              ? 'Nobody is in range right now.'
              : 'In range: ${names.join(', ')}',
        );

      case ChannelsCommand():
        final codes = [for (final room in _rooms.values) room.code]..sort();
        return CommandOutcome(
          notice: codes.isEmpty
              ? 'You are not in any group.'
              : 'Groups: ${codes.join(', ')}',
        );

      case WhisperCommand(:final nickname, :final body):
        final target = _conversationForNickname(nickname);
        if (target == null) return CommandOutcome(notice: _unknown(nickname));
        if (body.isNotEmpty) await sendText(target, body);
        return CommandOutcome(openConversation: target);

      case BlockCommand(:final nickname):
        final key = _identityForNickname(nickname);
        if (key == null) return CommandOutcome(notice: _unknown(nickname));
        await block(key, nickname: nickname);
        return CommandOutcome(notice: '$nickname is blocked.');

      case UnblockCommand(:final nickname):
        final key = _identityForNickname(nickname, includeBlocked: true);
        if (key == null) return CommandOutcome(notice: _unknown(nickname));
        await unblock(key);
        return CommandOutcome(notice: '$nickname is unblocked.');

      case FavouriteCommand(:final nickname, :final on):
        final key = _identityForNickname(nickname);
        if (key == null) return CommandOutcome(notice: _unknown(nickname));
        if (on) {
          await favourite(key, nickname: nickname);
        } else {
          await unfavourite(key);
        }
        return CommandOutcome(
          notice: on
              ? '$nickname is a favourite. You can also reach them over the '
                    'internet now.'
              : '$nickname is no longer a favourite.',
        );

      case SlapCommand(:final nickname):
        if (conversationId.isEmpty) {
          return const CommandOutcome(notice: 'Open a conversation first.');
        }
        // Sent as an ordinary message, because that is what it is. Nothing is
        // done to the named person, and nothing about it is special on the
        // wire — it is a line of text the sender is accountable for.
        await sendText(
          conversationId,
          SlapCommand(nickname).textFrom(state.nickname),
        );
        return const CommandOutcome();

      case LeaveCommand():
        if (!_rooms.containsKey(conversationId)) return _notInAGroup;
        final left = state.conversation(conversationId)?.title ?? 'the group';
        leaveRoom(conversationId);
        return CommandOutcome(
          notice:
              'You have left $left. Your phone will stop passing on what was '
              'said there. Rejoin with the same code whenever you like.',
        );

      case ClearCommand():
        if (conversationId.isEmpty) {
          return const CommandOutcome(notice: 'Open a conversation first.');
        }
        store.deleteMessagesIn(conversationId);
        _loadConversations();
        return const CommandOutcome(
          notice: 'Erased on this phone. Other people still have their copy.',
        );

      case NickCommand(:final name):
        state.setNickname(name);
        onNicknameChanged?.call(name);
        await announcePresence();
        return CommandOutcome(notice: 'You are $name now.');

      case ClaimCommand():
        if (!_rooms.containsKey(conversationId)) return _notInAGroup;
        if (roomOwner(conversationId) != null) {
          return const CommandOutcome(
            notice: 'Somebody already runs this group.',
          );
        }
        await claimRoom(conversationId);
        return const CommandOutcome(
          notice:
              'You run this group now — as a convention. Anyone with the code '
              'can still read and write it.',
        );

      case TransferCommand(:final nickname):
        if (!_rooms.containsKey(conversationId)) return _notInAGroup;
        if (!isRoomOwner(conversationId)) return _notTheOwner;
        final key = _identityForNickname(nickname);
        if (key == null) return CommandOutcome(notice: _unknown(nickname));
        await transferRoom(conversationId, key);
        return CommandOutcome(notice: '$nickname runs this group now.');

      case SaveCommand(:final on):
        if (!_rooms.containsKey(conversationId)) return _notInAGroup;
        if (on == null) {
          return CommandOutcome(
            notice: roomRetains(conversationId)
                ? 'This group is kept on this phone.'
                : 'This group is not kept on this phone.',
          );
        }
        if (!isRoomOwner(conversationId)) return _notTheOwner;
        await setRoomRetention(conversationId, retain: on);
        return CommandOutcome(
          notice: on
              ? 'This group will be kept on members\' phones.'
              : 'This group will not be kept. Existing messages are erased.',
        );

      case PassCommand(:final code):
        if (!_rooms.containsKey(conversationId)) return _notInAGroup;
        if (!isRoomOwner(conversationId)) return _notTheOwner;
        return _announceNewCode(conversationId, code);
    }
  }

  static const _notInAGroup = CommandOutcome(
    notice: 'That only works inside a group.',
  );

  static const _notTheOwner = CommandOutcome(
    notice: 'Only the group\'s owner can do that.',
  );

  static String _unknown(String nickname) =>
      'Relay does not know anyone called $nickname.';

  /// Moves a group to a new code by *telling* people, not by moving them.
  ///
  /// Deliberately not automatic. Re-keying every member on a remote instruction
  /// means that anyone who takes the owner's key can move a whole group without
  /// a soul noticing; a visible message the members choose to act on cannot be
  /// used that way.
  Future<CommandOutcome> _announceNewCode(
    String conversationId,
    String rawCode,
  ) async {
    final RoomCode code;
    try {
      code = RoomCode.parse(rawCode);
    } on FormatException catch (error) {
      return CommandOutcome(notice: error.message);
    }

    await sendText(
      conversationId,
      'This group is moving. The new code is ${code.value} — join it to keep '
      'talking. Anyone who does not have the new code stays behind.',
    );

    final joined = await joinRoom(code.value);
    return CommandOutcome(
      openConversation: joined.conversationId,
      notice:
          'Told the group and joined ${code.value}. People who were here keep '
          'the old code until they move.',
    );
  }

  /// Called when `/nick` renames this device, so the choice can be persisted.
  ///
  /// A callback rather than a direct dependency: the runtime does not own the
  /// key store, and a rename that only lived in memory would be undone by the
  /// next restart without the user ever being told.
  void Function(String nickname)? onNicknameChanged;

  /// The identity key of whoever is currently called [nickname].
  ///
  /// Names are not identities — two people in a crowd can pick the same one —
  /// so this resolves against people actually in range first, then against
  /// contacts, and returns null rather than guessing when there is no match.
  Uint8List? _identityForNickname(
    String nickname, {
    bool includeBlocked = false,
  }) {
    final wanted = nickname.toLowerCase();

    for (final entry in _peerNickname.entries) {
      if (entry.value.toLowerCase() == wanted) {
        final key = _peerIdentity[entry.key];
        if (key != null) return key;
      }
    }
    for (final contact in store.contacts()) {
      if (contact.nickname.toLowerCase() == wanted) return contact.publicKey;
    }
    if (includeBlocked) {
      for (final entry in store.blocked()) {
        if (entry.nickname.toLowerCase() == wanted) return entry.publicKey;
      }
    }
    return null;
  }

  String? _conversationForNickname(String nickname) {
    final wanted = nickname.toLowerCase();
    for (final entry in _peerNickname.entries) {
      if (entry.value.toLowerCase() == wanted) {
        return conversationForPeer(entry.key)?.id;
      }
    }
    return null;
  }

  // ------------------------------------------------------- room ownership

  /// Who is understood to run a room, or null if nobody has claimed it.
  ///
  /// Understood, not enforced. A room's only real access control is its code:
  /// anyone holding it can read, write, and run a build that ignores every
  /// claim here. What the signature does buy is that nobody can make a claim in
  /// somebody else's name — which is worth having on its own, and is the only
  /// part of this the UI may present as certain.
  Uint8List? roomOwner(String conversationId) {
    final room = _rooms[conversationId];
    if (room == null) return null;
    return store.room(room.roomId)?.ownerKey;
  }

  bool isRoomOwner(String conversationId) {
    final owner = roomOwner(conversationId);
    return owner != null && _bytesEqual(owner, identity.publicKey);
  }

  /// Whether messages in a room should be kept on this device.
  ///
  /// True unless the owner has asked otherwise. Honoured here; a client that
  /// chooses not to honour it cannot be stopped, and the UI says so.
  bool roomRetains(String conversationId) {
    final room = _rooms[conversationId];
    if (room == null) return true;
    return store.room(room.roomId)?.retain ?? true;
  }

  /// Claims a room. First claim wins; a later one is ignored by everyone who
  /// already heard the first.
  Future<void> claimRoom(String conversationId) =>
      _issueRoomControl(conversationId, RoomControlKind.claim);

  Future<void> transferRoom(String conversationId, Uint8List newOwner) =>
      _issueRoomControl(
        conversationId,
        RoomControlKind.transfer,
        newOwnerKey: newOwner,
      );

  Future<void> setRoomRetention(
    String conversationId, {
    required bool retain,
  }) => _issueRoomControl(
    conversationId,
    RoomControlKind.retention,
    retain: retain,
  );

  Future<void> _issueRoomControl(
    String conversationId,
    RoomControlKind kind, {
    Uint8List? newOwnerKey,
    bool retain = true,
  }) async {
    final room = _rooms[conversationId];
    if (room == null) return;

    // Anything but an opening claim has to come from the current owner. Checked
    // here as well as on receipt so the device does not broadcast a statement
    // every other member will discard.
    if (kind != RoomControlKind.claim && !isRoomOwner(conversationId)) return;

    final unsigned = RoomControl(
      kind: kind,
      ownerKey: identity.publicKey,
      newOwnerKey: newOwnerKey,
      retain: retain,
      issuedAt: _clock(),
      signature: Uint8List(RoomControl.signatureLength),
    );
    final control = RoomControl(
      kind: kind,
      ownerKey: unsigned.ownerKey,
      newOwnerKey: unsigned.newOwnerKey,
      retain: unsigned.retain,
      issuedAt: unsigned.issuedAt,
      signature: await identity.sign(unsigned.signedBytes()),
    );

    // Applied locally first. The owner's own device must agree with what it is
    // about to tell everyone else, even if nothing is in range to hear it.
    _applyRoomControl(room.roomId, conversationId, control);
    await _messages.sendRoomControl(room.roomId, control.encode());
  }

  Future<void> _handleRoomControl(ReassembledMessage frame) async {
    final conversationId = _roomConversationId(frame.dstHash);
    final room = _rooms[conversationId];
    if (room == null) return;

    final payload = await _messages.openRoomControl(room.roomId, frame.payload);
    if (payload == null) return;

    final control = RoomControl.decode(payload);
    if (control == null) return;

    // The signature is the one hard rule in this whole feature: a claim in
    // somebody else's name is refused outright.
    if (!await verifySignature(
      control.signedBytes(),
      control.signature,
      control.ownerKey,
    )) {
      return;
    }

    _applyRoomControl(room.roomId, conversationId, control);
  }

  void _applyRoomControl(
    int roomId,
    String conversationId,
    RoomControl control,
  ) {
    final existing = store.room(roomId);
    final owner = existing?.ownerKey;

    // A captured claim replayed later must not overwrite a newer one.
    final claimedAt = existing?.claimedAt;
    if (claimedAt != null && !control.issuedAt.isAfter(claimedAt)) return;

    switch (control.kind) {
      case RoomControlKind.claim:
        // First one wins. Without this the owner is whoever spoke most
        // recently, which is not ownership at all.
        if (owner != null) return;
        store.saveRoomOwner(
          roomId: roomId,
          ownerKey: control.ownerKey,
          claimedAt: control.issuedAt,
        );

      case RoomControlKind.transfer:
        if (owner == null || !_bytesEqual(owner, control.ownerKey)) return;
        final next = control.newOwnerKey;
        if (next == null) return;
        store.saveRoomOwner(
          roomId: roomId,
          ownerKey: next,
          claimedAt: control.issuedAt,
        );

      case RoomControlKind.retention:
        if (owner == null || !_bytesEqual(owner, control.ownerKey)) return;
        store.setRoomRetention(roomId, retain: control.retain);
        // Turning retention off applies to what is already stored, not only to
        // what arrives next. Anything else would leave the request half done
        // and the user believing otherwise.
        if (!control.retain) store.deleteMessagesIn(conversationId);
        _loadConversations();
    }
  }

  /// Sends a claim signed by the wrong key, to prove such a thing is refused.
  @visibleForTesting
  Future<void> debugSendForgedClaim(
    String conversationId,
    Uint8List pretendingToBe,
  ) async {
    final room = _rooms[conversationId];
    if (room == null) return;

    final forged = RoomControl(
      kind: RoomControlKind.claim,
      ownerKey: pretendingToBe,
      issuedAt: _clock(),
      signature: Uint8List(RoomControl.signatureLength),
    );
    await _messages.sendRoomControl(room.roomId, forged.encode());
  }

  /// Erases the messages of every joined room whose owner asked for that.
  void _purgeUnkeptRooms() {
    for (final entry in _rooms.entries) {
      if (!roomRetains(entry.key)) store.deleteMessagesIn(entry.key);
    }
  }

  // --------------------------------------------------------- room history

  /// Replies waiting out their random pause, by room.
  final _pendingHistoryReplies = <int, Timer>{};

  /// Rooms this device has asked about and not yet given up on.
  final _pendingHistoryRequests = <int>{};

  /// The longest anyone waits before answering a history request.
  ///
  /// Every member of a room hears the same request at the same moment. Without
  /// a random pause and the suppression below, twenty phones would each send
  /// the same back catalogue at once and drown the room they were trying to be
  /// helpful in.
  static const Duration historyReplyJitter = Duration(milliseconds: 1200);

  /// How often this device is willing to answer for one room.
  static const Duration historyReplyCooldown = Duration(minutes: 1);

  final _lastHistoryReply = <int, DateTime>{};

  @visibleForTesting
  bool hasPendingHistoryReply(int roomId) =>
      _pendingHistoryReplies.containsKey(roomId);

  @visibleForTesting
  bool hasPendingHistoryRequest(int roomId) =>
      _pendingHistoryRequests.contains(roomId);

  /// Asks the room what was said before we arrived.
  ///
  /// Never in stealth mode: a request states that this device has just joined
  /// one particular room, which is exactly the kind of statement stealth mode
  /// exists to stop.
  Future<void> requestRoomHistory(String conversationId) async {
    final room = _rooms[conversationId];
    if (room == null || state.status.stealthMode) return;

    _pendingHistoryRequests.add(room.roomId);
    await _messages.sendHistoryRequest(room.roomId, const HistoryRequest());
  }

  Future<void> _handleHistoryRequest(
    ReassembledMessage frame,
    String fromPeer,
  ) async {
    final conversationId = _roomConversationId(frame.dstHash);
    final room = _rooms[conversationId];
    // Not in this room, so we have nothing and could not read the request
    // anyway. We may still have relayed it, which is the point of a mesh.
    if (room == null) return;

    final payload = await _messages.openRoomControl(room.roomId, frame.payload);
    if (payload == null) return;

    final request = HistoryRequest.decode(payload);
    if (request == null) return;

    final last = _lastHistoryReply[room.roomId];
    if (last != null && _clock().difference(last) < historyReplyCooldown) {
      return;
    }
    if (_pendingHistoryReplies.containsKey(room.roomId)) return;

    // A random pause, then answer — unless somebody else answers first, in
    // which case [_handleHistoryReply] cancels this.
    final wait = Duration(
      milliseconds: _random.nextInt(historyReplyJitter.inMilliseconds),
    );
    _pendingHistoryReplies[room.roomId] = Timer(wait, () {
      _pendingHistoryReplies.remove(room.roomId);
      _lastHistoryReply[room.roomId] = _clock();
      unawaited(
        _messages.sendHistoryReply(
          room.roomId,
          _messages.historyFor(conversationId, since: request.since),
          toPeer: fromPeer,
        ),
      );
    });
  }

  Future<void> _handleHistoryReply(ReassembledMessage frame) async {
    final conversationId = _roomConversationId(frame.dstHash);
    final room = _rooms[conversationId];
    if (room == null) return;

    // Somebody has answered. Whatever we were about to say is now redundant.
    _pendingHistoryReplies.remove(room.roomId)?.cancel();
    _pendingHistoryRequests.remove(room.roomId);

    final payload = await _messages.openRoomControl(room.roomId, frame.payload);
    if (payload == null) return;

    final bundle = HistoryBundle.decode(payload);
    if (bundle == null) return;

    if (_messages.applyHistory(conversationId, bundle) > 0) {
      _loadConversations();
    }
  }

  // -------------------------------------------------------------- mentions

  /// Names to offer when the user types `@` in [conversationId].
  ///
  /// Rooms only. A direct conversation has exactly one other person in it and
  /// offering to name them would be noise in front of the keyboard.
  List<String> mentionCandidatesFor(String conversationId) {
    if (!_rooms.containsKey(conversationId)) return const [];

    final names = <String>{};
    for (final peerId in _reachable.keys) {
      final name = _peerNickname[peerId];
      if (name != null && name.isNotEmpty) names.add(name);
    }
    // Plus whoever has already spoken here. Someone can leave the room and
    // still be worth naming in a reply to what they said.
    for (final message in store.messages(conversationId)) {
      if (message.fromMe) continue;
      final name = _nameForSenderKey(message.senderKey);
      if (name != null) names.add(name);
    }

    final own = state.nickname.toLowerCase();
    return (names.where((n) => n.toLowerCase() != own).toList())..sort();
  }

  /// Who sent a room message, by the four identity bytes its envelope carries.
  ///
  /// Four bytes is not an identity — it is a hint, and two people can share
  /// one. It is used only to put a name on a message in a group, never to
  /// decide anything about trust, blocking or routing, all of which key on the
  /// full public key.
  String? _nameForSenderKey(Uint8List? senderKey) {
    if (senderKey == null || senderKey.length < 4) return null;

    for (final entry in _peerIdentity.entries) {
      if (_startsWith(entry.value, senderKey)) {
        final name = _peerNickname[entry.key];
        if (name != null && name.isNotEmpty) return name;
      }
    }
    for (final contact in store.contacts()) {
      if (_startsWith(contact.publicKey, senderKey) &&
          contact.nickname.isNotEmpty) {
        return contact.nickname;
      }
    }
    return null;
  }

  static bool _startsWith(Uint8List key, Uint8List prefix) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }

  // -------------------------------------------------------------- blocking

  /// Stops showing anything from a person, and stops sending to them.
  ///
  /// It does **not** stop relaying their traffic. Blocking governs what this
  /// device shows its owner; refusing to forward would break the mesh for
  /// bystanders standing near the blocked person, and would make the block
  /// visible to them — a device that suddenly stops relaying for exactly one
  /// peer is not subtle.
  Future<void> block(Uint8List identityKey, {String nickname = ''}) async {
    store.blockPeer(publicKey: identityKey, nickname: nickname, at: _clock());
    // The two contradict. Left both set, the relay policy and the block would
    // disagree about the same person and one would win by accident.
    store.setFavourite(publicKey: identityKey, favourite: false);
    await _reloadFavourites();
    await _reloadBlocked();

    // Drop them from the peer list immediately rather than waiting for the
    // next announce. The user pressed block and expects them gone.
    final hash = await addressHashOf(identityKey);
    final peerId = _addressPeer[hash];
    if (peerId != null) handlePeerLost(peerId);
    _publishPeers();
  }

  Future<void> unblock(Uint8List identityKey) async {
    store.unblockPeer(identityKey);
    await _reloadBlocked();
    _publishPeers();
  }

  bool isBlocked(int addressHash) => _blockedHashes.contains(addressHash);

  /// The identity key of whoever is on the other end of a direct conversation,
  /// or null if this device has not learned it yet.
  ///
  /// Announce frames carry it, so it is known for anyone who has introduced
  /// themselves. Blocking needs the full key rather than the address hash: the
  /// hash is 32 bits and truncated, so blocking by it could silence a stranger
  /// who happens to collide.
  Uint8List? identityKeyFor(String conversationId) {
    final address = _addressForConversation(conversationId);
    if (address == null) return null;
    final peerId = _addressPeer[address];
    return peerId == null ? null : _peerIdentity[peerId];
  }

  Future<void> _reloadBlocked() async {
    _blockedHashes.clear();
    _peerIdentity.clear();
    for (final entry in store.blocked()) {
      _blockedHashes.add(await addressHashOf(entry.publicKey));
    }
  }

  /// Records that the user has looked at a conversation, and tells the peer.
  ///
  /// Two separate claims travel here. `delivered` means a device acknowledged
  /// the bytes; `read` means a person opened the screen. Collapsing them would
  /// assert something nobody did.
  ///
  /// Rooms send nothing: a group has many readers and no single one speaks for
  /// it, so there is no honest sender for a group read receipt.
  Future<void> markConversationRead(String conversationId) async {
    store.markRead(conversationId);
    _loadConversations();

    if (_rooms.containsKey(conversationId)) return;

    final newest = _newestInbound[conversationId];
    if (newest == null) return;

    await _sendAck(
      newest.address,
      newest.sequence,
      _addressPeer[newest.address] ?? '',
      read: true,
    );
  }

  void leaveRoom(String conversationId) {
    final room = _rooms.remove(conversationId);
    if (room == null) return;
    _messages.forgetRoom(room.roomId);
    // Including anything we were about to say on its behalf.
    _pendingHistoryReplies.remove(room.roomId)?.cancel();
    _pendingHistoryRequests.remove(room.roomId);

    // A room whose owner asked that it not be kept is erased on the way out.
    // Leaving it on disk would make the setting a decoration.
    if (!(store.room(room.roomId)?.retain ?? true)) {
      store.deleteMessagesIn(conversationId);
    }
    _loadConversations();
  }

  // ----------------------------------------------------------------- peers

  void _onPeerEvent(PeerEvent event) {
    switch (event.kind) {
      case PeerEventKind.discovered:
      case PeerEventKind.updated:
        _reachable[event.peer.peerId] = event.peer.hopDistance;
        _publishPeers();
        // Someone new is in range. Anything that could not be sent before may
        // be sendable now.
        unawaited(retryPending());
      case PeerEventKind.lost:
        handlePeerLost(event.peer.peerId);
    }
  }

  void handlePeerLost(String peerId) {
    final name = _peerNickname[peerId];
    if (name != null) log.info('$name went out of range');

    _reachable.remove(peerId);
    final address = _peerAddress.remove(peerId);
    _peerNickname.remove(peerId);
    _peerIdentity.remove(peerId);
    if (address != null) _addressPeer.remove(address);
    _publishPeers();
  }

  /// The conversation with a peer, creating it if this is the first contact.
  ///
  /// Returns null when the peer has not yet announced, because without an
  /// address hash there is nowhere to send.
  ui.Conversation? conversationForPeer(String peerId) {
    final address = _peerAddress[peerId];
    if (address == null) return null;

    final conversationId = conversationIdForAddress(address);
    store.upsertConversation(
      id: conversationId,
      kind: db.ConversationKind.direct,
      title: _peerNickname[peerId] ?? _shortId(peerId),
    );
    _loadConversations();
    return state.conversation(conversationId);
  }

  /// Conversation id for a mesh address.
  ///
  /// Keyed on the address rather than the radio peer id because a peer id
  /// changes whenever the link is re-established, and a conversation that
  /// forked every time someone walked out of range and back would be useless.
  String conversationIdForAddress(int address) =>
      'peer-${address.toRadixString(16)}';

  String _roomConversationId(int roomId) => 'room-${roomId.toRadixString(16)}';

  int? _addressForConversation(String conversationId) {
    if (!conversationId.startsWith('peer-')) return null;
    return int.tryParse(conversationId.substring(5), radix: 16);
  }

  void _ensureConversationRow(
    String conversationId,
    ReassembledMessage frame,
    String fromPeer,
  ) {
    final existing = state.conversation(conversationId);
    if (existing != null) return;

    store.upsertConversation(
      id: conversationId,
      kind: frame.type == FrameType.room
          ? db.ConversationKind.room
          : db.ConversationKind.direct,
      title: frame.type == FrameType.room
          ? _rooms[conversationId]?.code ?? 'Room'
          : _peerNickname[fromPeer] ?? _shortId(fromPeer),
    );
  }

  static String _shortId(String peerId) {
    final compact = peerId.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    return compact.isEmpty
        ? 'Someone nearby'
        : 'Someone (${compact.substring(0, compact.length.clamp(0, 4))})';
  }

  // ------------------------------------------------------------ verification

  /// This device's own pairing payload, for display as a QR code.
  PairingPayload pairingPayload({String nostrKey = ''}) => PairingPayload(
    identityKey: identity.publicKey,
    noiseKey: _sessions.localStaticKey ?? Uint8List(32),
    nostrKey: nostrKey,
    nickname: state.nickname,
  );

  /// The code both people compare after scanning.
  ///
  /// Computed over the two identity keys, so it is the same on both phones
  /// without either needing to know who scanned first.
  Future<SafetyCode> safetyCodeWith(Uint8List peerIdentityKey) =>
      SafetyCode.between(identity.publicKey, peerIdentityKey);

  /// Records that the user compared codes in person and they matched.
  ///
  /// What pinning buys is the verified badge, entry to the courier trust tier,
  /// and a safety code stored for re-comparison later.
  ///
  /// What it does *not* buy is a key-change warning, and the difference is
  /// worth stating because it is the opposite of what Signal trains people to
  /// expect. There, an identity is a phone number and the key beneath it can
  /// change; here the key *is* the identity, and every address, conversation
  /// and safety code is derived from it. Somebody impersonating a verified
  /// contact necessarily arrives under a different key, so they appear as a
  /// separate, unverified conversation rather than as a change to this one.
  /// The badge is what carries the signal, which is why its absence has to be
  /// as visible in the UI as its presence.
  Future<void> verifyContact(PairingPayload payload) async {
    final code = await safetyCodeWith(payload.identityKey);

    store.saveContact(
      publicKey: payload.identityKey,
      nickname: payload.nickname,
      trust: db.TrustState.verified,
      safetyCode: code.digits,
      pinnedAt: _clock(),
    );

    if (payload.nostrKey.isNotEmpty) {
      onRelayRouteLearned?.call(payload.identityKey, payload.nostrKey);
    }

    _publishPeers();
  }

  /// Called when a scanned contact publishes a relay key.
  ///
  /// A callback rather than a direct dependency: the runtime must work with no
  /// relay at all, which is the normal case and the only case in stealth mode.
  void Function(Uint8List identityKey, String nostrKey)? onRelayRouteLearned;

  // ------------------------------------------------------------- couriers

  /// The address this device knows a radio peer by, if it has announced one.
  @visibleForTesting
  int? addressForPeer(String peerId) => _peerAddress[peerId];

  /// Whether this device holds mail on other people's behalf.
  ///
  /// On by default: the mesh only reaches people who are not here because some
  /// phone carried a message for them, and a network where everybody opts out
  /// delivers nothing. But it spends this user's storage and battery on
  /// somebody else's conversation, so it is theirs to refuse.
  bool get carryForOthers => _carryForOthers;
  bool _carryForOthers = true;

  /// Turns carrying on or off. Does not discard what is already held — see
  /// [dropCarriedMail], which is a separate and more destructive decision.
  Future<void> setCarryForOthers(bool enabled) async {
    _carryForOthers = enabled;
    _publishStatus();
  }

  /// How many envelopes this device is holding for other people right now.
  int get carriedCount => couriers.count;

  /// Throws away everything held for other people. Returns how many went.
  ///
  /// Every one of them is somebody's undelivered message, and none of them can
  /// be recovered or re-requested — the sender has no way to know. That is why
  /// this is a deliberate action rather than a side effect of the switch above.
  int dropCarriedMail() {
    final dropped = couriers.dropAll();
    if (dropped > 0) _publishStatus();
    return dropped;
  }

  /// Sends an already-written message by courier as well as by radio.
  ///
  /// Returns how many carriers took it, or a [CourierRefusal] saying why none
  /// could. The ordinary outbox keeps retrying either way — this is an
  /// addition to it, never a replacement, because a courier may take hours and
  /// the radio may succeed in the next second.
  Future<({int carriers, CourierRefusal? refusal})> sendByCourier({
    required String conversationId,
    required String body,
  }) async {
    if (state.status.stealthMode) {
      return (carriers: 0, refusal: CourierRefusal.stealth);
    }

    final peerKey = store.peerKeyFor(conversationId);
    if (peerKey == null) {
      return (carriers: 0, refusal: CourierRefusal.notADirectMessage);
    }
    if (store.noiseKeyFor(peerKey) == null) {
      return (carriers: 0, refusal: CourierRefusal.recipientKeyUnknown);
    }

    final carriers = await depositWithCouriers(
      recipientIdentityKey: peerKey,
      body: body,
    );
    return (
      carriers: carriers,
      refusal: carriers == 0 ? CourierRefusal.noCarriers : null,
    );
  }

  /// Writes to somebody out of reach by handing sealed mail to whoever is here.
  ///
  /// Returns how many carriers took it. Zero is an ordinary answer — nobody
  /// trusted is nearby, or the recipient has never published a key to seal to —
  /// and is not an error the user needs telling about, because the ordinary
  /// outbox is still retrying in parallel.
  Future<int> depositWithCouriers({
    required Uint8List recipientIdentityKey,
    required String body,
    int copies = CourierEnvelope.maxCopies ~/ 2,
  }) async {
    if (state.status.stealthMode) return 0;

    // Sealing needs their X25519 key. There is no fallback: guessing, or
    // reusing their signing key, would produce mail nobody can ever open.
    final recipientNoise = store.noiseKeyFor(recipientIdentityKey);
    if (recipientNoise == null) return 0;

    final carriers = _trustedCarriers();
    if (carriers.isEmpty) return 0;

    final envelope = await CourierSeal.build(
      senderNoisePrivate: _noiseStaticKey,
      recipientNoiseStatic: recipientNoise,
      // The same envelope a direct message travels in, so the recipient
      // deduplicates couriered and radio-delivered copies of one message
      // against each other instead of showing it twice.
      payload: AppEnvelope.build(
        senderKey: Uint8List.sublistView(identity.publicKey, 0, 4),
        // Same counter a radio message uses, so the recipient deduplicates the
        // two paths against each other rather than showing one message twice.
        sequence: _messages.nextSequence(),
        body: Uint8List.fromList(utf8.encode(body)),
      ).encode(),
      now: _clock(),
      copies: copies,
    );

    var taken = 0;
    for (final peerId in carriers) {
      final address = _peerAddress[peerId];
      if (address == null) continue;
      if (await _messages.sendCourier(
        envelope,
        toPeer: peerId,
        peerHash: address,
      )) {
        taken++;
      }
    }
    return taken;
  }

  /// Takes somebody else's mail, subject to this device's quotas.
  ///
  /// Public so the deposit rule can be exercised without a radio. Returns
  /// whether there was room; a refusal is routine, not an error.
  @visibleForTesting
  Future<bool> carryMail(
    CourierEnvelope envelope, {
    required Uint8List depositor,
    required CourierTier tier,
  }) async => couriers.deposit(envelope, depositor: depositor, tier: tier);

  /// Hands a peer everything held for them, then everything worth spraying.
  ///
  /// Called on every announce, which is the only moment this device knows
  /// somebody is actually there. Both halves are best-effort: a handover that
  /// fails costs nothing, because the envelope is still held.
  Future<void> offerMail(String peerId) async {
    if (state.status.stealthMode) return;

    final address = _peerAddress[peerId];
    final identityKey = _peerIdentity[peerId];
    if (address == null || identityKey == null) return;
    if (_blockedHashes.contains(address)) return;

    couriers.pruneExpired();

    // Their tags, computed from the key they published. Without it we cannot
    // tell whether we are carrying anything for them, and cannot spray to them
    // safely either — see below.
    final noiseKey = _peerNoiseKey[peerId] ?? store.noiseKeyFor(identityKey);
    final tags = noiseKey == null
        ? const <Uint8List>[]
        : await CourierSeal.candidateTags(noiseKey, now: _clock());

    // Delivery first. It is the only handover that ends a message's journey,
    // and doing it before spraying means a met recipient never costs a copy.
    for (final envelope in couriers.envelopesFor(tags)) {
      if (await _messages.sendCourier(
        envelope,
        toPeer: peerId,
        peerHash: address,
      )) {
        // Only after the transport accepted it. Forgetting on the attempt
        // would drop mail on a dropped connection, which is exactly when
        // carrying it mattered.
        couriers.delivered(envelope);
      }
    }

    // Spraying is a favour asked of somebody, so it is asked only of people the
    // user chose or verified. Handing envelopes to any passer-by would tell
    // them this device is carrying traffic, and for roughly whom.
    //
    // A user who switched carrying off asks nobody. Note that this sits *after*
    // delivery, deliberately: mail already on this device still reaches the
    // person it is addressed to. Withholding it would be pure loss — the copy
    // is already here, handing it over costs one transmission, and it is the
    // only way that message ever arrives.
    if (!_carryForOthers) return;
    if (_carrierTier(peerId) == null) return;

    // Their own tags are passed so a copy is never sprayed to somebody who is
    // the recipient — that goes by the delivery path above, which is free.
    for (final copy in couriers.spraysFor(identityKey, courierTags: tags)) {
      if (await _messages.sendCourier(
        copy,
        toPeer: peerId,
        peerHash: address,
      )) {
        couriers.sprayed(copy, courierKey: identityKey);
      }
    }
  }

  Future<void> _handleCourier(ReassembledMessage frame, String fromPeer) async {
    final envelope = _messages.receiveCourier(frame.payload);
    if (envelope == null) return;

    // Ours? Try to open it before considering carrying it. An envelope for
    // this device is never also stored, so it cannot be sprayed onward.
    final opened = await CourierSeal.open(
      recipientNoisePrivate: _noiseStaticKey,
      envelope: envelope,
    );
    if (opened != null) {
      await _acceptCourieredMessage(opened.senderStatic, opened.payload);
      return;
    }

    // Somebody else's. Carried only for people the user chose or verified:
    // taking mail from anyone in range is a free disk-filling attack on every
    // phone in a crowd. And not at all if the user switched carrying off.
    if (!_carryForOthers) return;

    final tier = _carrierTier(fromPeer);
    final identityKey = _peerIdentity[fromPeer];
    if (tier == null || identityKey == null) return;

    couriers.deposit(envelope, depositor: identityKey, tier: tier);
  }

  /// Files a message that arrived by courier under the right conversation.
  ///
  /// The envelope names its sender by X25519 key, which is not the key
  /// conversations are addressed by, so this depends on having heard that
  /// person's announce at some point — stored, so it survives a restart. Mail
  /// from somebody entirely unknown is dropped: attributing a message to
  /// nobody would be worse than not showing it.
  Future<void> _acceptCourieredMessage(
    Uint8List senderNoiseKey,
    Uint8List payload,
  ) async {
    final senderIdentity = store.identityForNoiseKey(senderNoiseKey);
    if (senderIdentity == null) return;

    // Derived from the key, never looked up among the peers here now. The
    // sender of couriered mail is by definition somewhere else — that is why
    // it was carried — so a search of the current peer table would always
    // fail, and every delivered message would be dropped on arrival.
    final address = await addressHashOf(senderIdentity);
    if (_blockedHashes.contains(address)) return;

    final conversationId = conversationIdForAddress(address);
    store.upsertConversation(
      id: conversationId,
      kind: db.ConversationKind.direct,
      title:
          _favouriteNames[address] ??
          _nicknameForIdentity(senderIdentity) ??
          _shortId(conversationId),
    );

    if (_messages.acceptCourieredPayload(
      conversationId: conversationId,
      payload: payload,
      via: TransportKind.mesh,
    )) {
      _loadConversations();
    }
  }

  /// Peers here and now who could be asked to carry something.
  List<String> _trustedCarriers() => [
    for (final peerId in _reachable.keys)
      if (_peerAddress.containsKey(peerId) && _carrierTier(peerId) != null)
        peerId,
  ];

  /// How much of this device's storage a peer is entitled to, or null if they
  /// are entitled to none.
  CourierTier? _carrierTier(String peerId) {
    final address = _peerAddress[peerId];
    final identityKey = _peerIdentity[peerId];
    if (identityKey == null) return null;
    if (address != null && _blockedHashes.contains(address)) return null;

    if (address != null && _favouriteHashes.contains(address)) {
      return CourierTier.favourite;
    }
    if (store.isFavourite(identityKey)) return CourierTier.favourite;

    for (final contact in store.contacts()) {
      if (_bytesEqual(contact.publicKey, identityKey)) {
        return contact.trust == db.TrustState.verified
            ? CourierTier.verified
            : null;
      }
    }
    return null;
  }

  String? _nicknameForIdentity(Uint8List identityKey) {
    for (final entry in _peerIdentity.entries) {
      if (_bytesEqual(entry.value, identityKey)) {
        final name = _peerNickname[entry.key];
        if (name != null && name.isNotEmpty) return name;
      }
    }
    for (final contact in store.contacts()) {
      if (_bytesEqual(contact.publicKey, identityKey) &&
          contact.nickname.isNotEmpty) {
        return contact.nickname;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- settings

  Future<void> setStealth(bool enabled) async {
    state.setStealth(enabled);
    _router.stealthMode = enabled;
    // Silencing the Bluetooth beacon while still advertising on Wi-Fi would
    // make stealth mode worse than useless — it would look like it worked.
    await _wifi?.setStealthMode(enabled);
    if (!enabled) await announcePresence();
    _publishStatus();
  }

  void setPowerMode(PowerMode mode) => state.setPowerMode(mode);

  Future<void> refreshStatus() async => _publishStatus();

  /// Destroys everything on this device. Irreversible by design.
  Future<void> panicWipe() async {
    // Before anything is destroyed, and regardless of the haptics setting. It
    // is the only confirmation the user gets that three taps registered rather
    // than two, and afterwards there is nothing left to tell them with.
    unawaited(Haptics.panic());

    // Cleared first. Peer names and timings in the log are exactly the kind of
    // record the user just asked to destroy.
    log.clear();
    store.wipe();
    _sessions.wipe();
    _rooms.clear();
    _peerAddress.clear();
    _peerNickname.clear();
    _addressPeer.clear();
    _reachable.clear();
    _newestInbound.clear();
    for (final timer in _pendingHistoryReplies.values) {
      timer.cancel();
    }
    _pendingHistoryReplies.clear();
    _pendingHistoryRequests.clear();
    _lastHistoryReply.clear();
    _blockedHashes.clear();
    _favouriteHashes.clear();
    _favouriteNames.clear();
    _reassembler.clear();
    state.wipe();
  }

  // ------------------------------------------------------------- publishing

  void _onSendOutcome(SendOutcome outcome) {
    _loadConversations();

    // Felt, not just shown. This app is used with the phone in a pocket and
    // the user looking at something else; a delivery that arrives minutes
    // after the send is exactly the event a screen glance will miss.
    unawaited(switch (outcome.state) {
      db.MessageState.sent => Haptics.sent(),
      db.MessageState.delivered || db.MessageState.read => Haptics.delivered(),
      db.MessageState.failed || db.MessageState.expired => Haptics.failed(),
      db.MessageState.queued => Future<void>.value(),
    });
  }

  void _publishStatus() {
    // Read from the individual radios, never the merged status. Merged is
    // right for routing and wrong for the screen: "Bluetooth is off but Wi-Fi
    // is working" is two facts, and one combined verdict is false about at
    // least one of them.
    final bluetooth = _bluetooth.status;
    final wifi = _wifi?.status;

    state.updateStatus(
      ui.MeshStatus(
        bluetoothOn: bluetooth.adapterOn,
        permissionsGranted: bluetooth.permissionsGranted,
        peersInRange: state.peers.where((p) => p.isReachable).length,
        canAdvertise: bluetooth.canAdvertise,
        stealthMode: state.status.stealthMode,
        powerMode: state.powerMode.name,
        relayAvailable: _router.relayAvailable,
        wifiAvailable: wifi?.isHealthy ?? false,
        wifiPeers: wifi?.connectedPeerCount ?? 0,
        wifiDetail: wifi?.detail,
        carryForOthers: _carryForOthers,
        carriedCount: couriers.count,
      ),
    );
  }

  void _publishPeers() {
    final peers =
        <ui.Peer>[
            for (final entry in _reachable.entries)
              ui.Peer(
                id: entry.key,
                nickname: _peerNickname[entry.key] ?? _shortId(entry.key),
                hops: entry.value,
                trust: _trustFor(entry.key),
                isFavourite: _favouriteHashes.contains(_peerAddress[entry.key]),
                // Read from the transport rather than remembered, so the bars
                // fall as somebody walks away instead of freezing at whatever
                // was true when they were first seen.
                rssi: _rssiFor(entry.key),
              ),

            // Favourites who are not in range are listed anyway, with no hop count
            // so nothing pretends they are nearby. Without this there is nowhere to
            // tap to write to someone who has walked off, and the message that would
            // have waited in the outbox for them never gets composed.
            for (final hash in _favouriteHashes)
              if (!_addressPeer.containsKey(hash))
                ui.Peer(
                  id: favouritePeerId(hash),
                  nickname: _favouriteNames[hash] ?? 'Someone you chose',
                  hops: null,
                  isFavourite: true,
                ),
          ]
          // Favourites first, then by how close they are. A peer list in a crowd is
          // long, and the people the user chose are the ones they are looking for.
          ..sort((a, b) {
            if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
            return (a.hops ?? 1 << 20).compareTo(b.hops ?? 1 << 20);
          });

    state.updatePeers(peers);
    _publishStatus();
  }

  ui.TrustBadge _trustFor(String peerId) {
    final address = _peerAddress[peerId];
    if (address == null) return ui.TrustBadge.unverified;
    final key = _sessions.remoteStaticKey(address);
    if (key == null) return ui.TrustBadge.unverified;

    for (final contact in store.contacts()) {
      if (_bytesEqual(contact.publicKey, key)) {
        return switch (contact.trust) {
          db.TrustState.verified => ui.TrustBadge.verified,
          db.TrustState.keyChanged => ui.TrustBadge.keyChanged,
          db.TrustState.unverified => ui.TrustBadge.unverified,
        };
      }
    }
    return ui.TrustBadge.unverified;
  }

  /// Rebuilds the UI's conversation list from storage.
  ///
  /// Storage is the single source of truth. Mutating the view model directly
  /// would let the two drift, and the moment they drift the user is being shown
  /// something that is not what the device will do on restart.
  void _loadConversations() {
    for (final row in store.conversations()) {
      state.upsertConversation(
        ui.Conversation(
          id: row.id,
          title: row.title,
          kind: row.kind == db.ConversationKind.room
              ? ui.ConversationKind.room
              : ui.ConversationKind.direct,
          unread: row.unread,
          peer: _peerForConversation(row.id),
          messages: [
            for (final message in store.messages(row.id))
              ui.Message(
                id: message.id,
                body: message.body,
                fromMe: message.fromMe,
                state: _uiState(message.state),
                sentAt: message.createdAt,
                // In a room the conversation title is the group code, which
                // says nothing about who spoke. A group chat where every
                // message is anonymous is barely a group chat.
                senderName: message.fromMe
                    ? null
                    : row.kind == db.ConversationKind.room
                    ? _nameForSenderKey(message.senderKey) ??
                          'Someone in the group'
                    : row.title,
                voiceDurationMs: message.voiceDurationMs,
                // Decided here rather than stored, because the user can rename
                // themselves and a flag frozen at receipt time would then be
                // wrong in both directions. Never true of our own messages:
                // quoting your own name must not light up your own screen.
                mentionsYou:
                    !message.fromMe &&
                    Mentions.addresses(message.body, state.nickname),
                viaCourier: message.viaCourier,
              ),
          ],
        ),
      );
    }
  }

  /// The measured link strength to a radio peer, if the transport has one.
  ///
  /// Only Bluetooth reports this. A peer on the local network has no RSSI, and
  /// a peer heard through somebody else has one that belongs to the relay.
  int? _rssiFor(String peerId) {
    for (final peer in _mesh.peers) {
      if (peer.peerId == peerId) return peer.rssi;
    }
    return null;
  }

  ui.Peer? _peerForConversation(String conversationId) {
    final address = _addressForConversation(conversationId);
    if (address == null) return null;
    final peerId = _addressPeer[address];
    if (peerId == null) return null;
    for (final peer in state.peers) {
      if (peer.id == peerId) return peer;
    }
    return null;
  }

  static ui.MessageState _uiState(db.MessageState state) => switch (state) {
    db.MessageState.queued => ui.MessageState.queued,
    db.MessageState.sent => ui.MessageState.sent,
    db.MessageState.delivered => ui.MessageState.delivered,
    db.MessageState.read => ui.MessageState.read,
    db.MessageState.failed => ui.MessageState.failed,
    db.MessageState.expired => ui.MessageState.expired,
  };

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
