import 'package:flutter/foundation.dart';

import 'package:relay_app/src/domain/reach.dart';
import 'package:relay_app/src/domain/signal_strength.dart';

/// What actually happened to a message.
///
/// In a mesh, "sent" genuinely does not imply "arrived": the frame left this
/// device and may still be hopping, may be waiting for the recipient to come
/// back into range, or may already have expired. Collapsing these into one
/// checkmark would be a lie, and users make real decisions on it — whether to
/// go find someone, whether to say it again out loud.
enum MessageState {
  queued('Waiting to send', 'Nobody is in range yet'),
  sent('Sent into the mesh', 'On its way — not confirmed yet'),
  delivered('Delivered', 'Confirmed on their device'),
  read('Read', 'They opened it'),
  failed('Failed', 'Could not be sent'),
  expired('Never delivered', 'Gave up after 24 hours');

  const MessageState(this.label, this.explanation);

  final String label;

  /// Plain-language detail, shown the first time a user meets this state.
  final String explanation;

  bool get isConfirmed => this == delivered || this == read;
  bool get isTerminal => this == failed || this == expired;
}

enum TrustBadge { verified, unverified, keyChanged }

@immutable
class Peer {
  const Peer({
    required this.id,
    required this.nickname,
    required this.hops,
    this.trust = TrustBadge.unverified,
    this.isFavourite = false,
    this.rssi,
  });

  final String id;
  final String nickname;

  /// Null when the peer is known but not currently reachable.
  final int? hops;

  /// Radio strength of the link, in dBm, where there is one to measure.
  ///
  /// Null for a peer reached over Wi-Fi or through somebody else. See [signal],
  /// which is what the UI uses.
  final int? rssi;

  final TrustBadge trust;

  /// Chosen by the user. Favourites stay in the list when they go out of range,
  /// so there is somewhere to write to them, and they sort above everyone else.
  final bool isFavourite;

  Reach get reach => Reach.fromHops(hops);
  bool get isReachable => hops != null;

  /// How strong the link is, or null when there is nothing to report.
  ///
  /// Only ever answered for a peer one hop away. The RSSI of a relayed peer is
  /// the strength of the link to whoever passed the frame on — a different
  /// fact, about a different person — and showing it beside this one's name
  /// would be a lie about who is nearby.
  SignalStrength? get signal =>
      hops == 1 ? SignalStrength.fromRssi(rssi) : null;
}

@immutable
class Message {
  const Message({
    required this.id,
    required this.body,
    required this.fromMe,
    required this.state,
    required this.sentAt,
    this.senderName,
    this.voiceDurationMs,
    this.mentionsYou = false,
    this.viaCourier = false,
  });

  final String id;
  final String body;
  final bool fromMe;
  final MessageState state;
  final DateTime sentAt;
  final String? senderName;
  final int? voiceDurationMs;

  /// Someone wrote `@yourname` in this.
  ///
  /// Decided when the message is loaded rather than stored, because the user
  /// can change their nickname and a flag frozen at receipt time would then be
  /// wrong in both directions.
  final bool mentionsYou;

  /// Somebody carried this here in their pocket instead of it arriving over a
  /// radio link.
  ///
  /// Worth showing because it changes what the message means. It may have been
  /// written hours ago by someone who is still nowhere near, and the obvious
  /// reply — sending one straight back — will not reach them the same way.
  final bool viaCourier;

  bool get isVoice => voiceDurationMs != null;
}

enum ConversationKind { direct, room }

@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.kind,
    required this.messages,
    this.peer,
    this.memberCount,
    this.unread = 0,
  });

  final String id;
  final String title;
  final ConversationKind kind;
  final List<Message> messages;
  final Peer? peer;
  final int? memberCount;
  final int unread;

  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  /// Somebody named the user in here and they have not read it.
  ///
  /// Distinct from [unread]: in a busy room an unread count is background
  /// noise, and a direct request for the user's attention is not.
  bool get hasMention =>
      unread > 0 &&
      messages.reversed.take(unread).any((m) => m.mentionsYou && !m.fromMe);

  /// Rooms are keyed by a shared code, so anyone holding it can read them.
  /// The UI must never show them the same lock affordance as a direct message.
  bool get hasStrongEncryption => kind == ConversationKind.direct;
}

@immutable
class MeshStatus {
  const MeshStatus({
    required this.bluetoothOn,
    required this.permissionsGranted,
    required this.peersInRange,
    this.canAdvertise = true,
    this.stealthMode = false,
    this.powerMode = 'balanced',
    this.relayAvailable = false,
    this.wifiAvailable = false,
    this.wifiPeers = 0,
    this.wifiDetail,
    this.carryForOthers = true,
    this.carriedCount = 0,
  });

  final bool bluetoothOn;
  final bool permissionsGranted;
  final int peersInRange;
  final bool canAdvertise;
  final bool stealthMode;
  final String powerMode;
  final bool relayAvailable;

  /// The local network is usable and the transport is on it.
  ///
  /// Reported separately from [bluetoothOn] rather than merged into one
  /// verdict: the two fail independently, they reach different people, and the
  /// user's next action differs completely.
  final bool wifiAvailable;

  /// People reachable over the local network right now.
  final int wifiPeers;

  /// Why the local network is unusable, when it is. Null otherwise.
  final String? wifiDetail;

  /// This device holds sealed mail for people who are not here.
  ///
  /// On by default. The mesh only reaches somebody who is absent because a
  /// phone carried a message for them, so a network where everybody opts out
  /// delivers nothing — but it spends this user's storage and battery on
  /// somebody else's conversation, which makes it theirs to refuse.
  final bool carryForOthers;

  /// How many envelopes are being held for other people right now.
  final int carriedCount;

  /// Copies with selected fields replaced.
  ///
  /// Exists because rebuilding this by hand — which several call sites used to
  /// do — silently drops whichever field was added most recently. That is how
  /// the Wi-Fi state would vanish every time the peer list changed.
  MeshStatus copyWith({
    bool? bluetoothOn,
    bool? permissionsGranted,
    int? peersInRange,
    bool? canAdvertise,
    bool? stealthMode,
    String? powerMode,
    bool? relayAvailable,
    bool? wifiAvailable,
    int? wifiPeers,
    String? wifiDetail,
    bool? carryForOthers,
    int? carriedCount,
  }) => MeshStatus(
    bluetoothOn: bluetoothOn ?? this.bluetoothOn,
    permissionsGranted: permissionsGranted ?? this.permissionsGranted,
    peersInRange: peersInRange ?? this.peersInRange,
    canAdvertise: canAdvertise ?? this.canAdvertise,
    stealthMode: stealthMode ?? this.stealthMode,
    powerMode: powerMode ?? this.powerMode,
    relayAvailable: relayAvailable ?? this.relayAvailable,
    wifiAvailable: wifiAvailable ?? this.wifiAvailable,
    wifiPeers: wifiPeers ?? this.wifiPeers,
    wifiDetail: wifiDetail ?? this.wifiDetail,
    carryForOthers: carryForOthers ?? this.carryForOthers,
    carriedCount: carriedCount ?? this.carriedCount,
  );

  /// At least one radio can carry a message.
  ///
  /// Wi-Fi alone counts. Refusing to call the mesh healthy because Bluetooth is
  /// off, while messages are crossing the room over a router, would be false —
  /// and the router that reads it would stop sending.
  bool get isHealthy => (bluetoothOn && permissionsGranted) || wifiAvailable;

  /// The single most important thing to tell the user, or null when fine.
  ///
  /// Ordered by severity: a problem that stops messages entirely outranks one
  /// that only reduces reach.
  String? get problem {
    if (!permissionsGranted) {
      return wifiAvailable
          ? 'Relay needs Bluetooth permission to find people. For now it can '
                'only reach people on this Wi-Fi'
          : 'Relay needs Bluetooth permission to find people';
    }
    if (!bluetoothOn) {
      // Two different situations, and conflating them would misdescribe what
      // the user is looking at. With Wi-Fi up, messages really are moving; the
      // loss is everyone who is not on that network.
      return wifiAvailable
          ? 'Bluetooth is off. You can still reach people on this Wi-Fi, '
                'but nobody else'
          : 'Bluetooth is off — turn it on to reach people nearby';
    }
    if (!canAdvertise) {
      return 'This phone can receive and pass on messages, but others cannot discover it';
    }
    return null;
  }
}
