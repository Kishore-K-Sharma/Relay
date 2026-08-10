import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/responsive.dart';
import 'package:relay_app/src/ui/theme.dart';
import 'package:relay_app/src/ui/widgets.dart';

/// Layout C: live presence above, conversations below.
///
/// The ordering is the whole design argument. A crowd user's first question is
/// "who can I reach", which changes constantly; their second is "what did I
/// miss". A standard messenger answers only the second.
///
/// On a wide window the same content becomes two panes. That is not a different
/// design — the list keeps its order and its meaning — it is the same one with
/// the conversation shown beside it instead of on top of it.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.status,
    required this.peers,
    required this.conversations,
    this.roomName,
    this.onOpenConversation,
    this.onTapPeer,
    this.onFixStatus,
    this.onOpenRadar,
    this.onOpenSettings,
    this.onJoinRoom,
    this.onOpenPairing,
    this.panicGestureEnabled = false,
    this.onPanicGesture,
    this.selectedConversationId,
    this.detail,
  });

  /// How wide the list is when there are two panes.
  ///
  /// Fixed rather than a fraction: a list of one-line rows given half a
  /// 1400-point window is a column of mostly whitespace, and the conversation
  /// beside it is the part that benefits from the room.
  static const double listPaneWidth = 360;

  /// Whether tapping a conversation should push a screen.
  ///
  /// The caller decides what to do; this answers what the layout expects, so
  /// the two cannot drift apart.
  static bool opensByPushing(BuildContext context) => !Panes.of(context);

  final MeshStatus status;
  final List<Peer> peers;
  final List<Conversation> conversations;
  final String? roomName;
  final void Function(Conversation)? onOpenConversation;
  final void Function(Peer)? onTapPeer;
  final VoidCallback? onFixStatus;
  final VoidCallback? onOpenRadar;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onJoinRoom;
  final VoidCallback? onOpenPairing;

  /// Whether three quick taps on the title erase the phone.
  ///
  /// Off unless the user has turned it on, having read what it does. There is
  /// no confirmation once it fires — that is the point of it.
  final bool panicGestureEnabled;

  final VoidCallback? onPanicGesture;

  /// Which conversation the second pane is showing, when there is one.
  final String? selectedConversationId;

  /// The second pane. Built by the caller and ignored entirely on a narrow
  /// window, so a phone never pays to construct a screen it cannot show.
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final reachable = peers.where((p) => p.isReachable).length;
    final verifiedInRange = peers
        .where((p) => p.isReachable && p.trust == TrustBadge.verified)
        .length;
    final twoPanes = Panes.of(context);

    return Scaffold(
      appBar: AppBar(
        // The emergency wipe lives on the title, and does nothing unless the
        // user has switched it on in Settings. See [PanicTapTarget] for why it
        // has no confirmation.
        title: PanicTapTarget(
          enabled: panicGestureEnabled,
          onTriggered: onPanicGesture ?? () {},
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                roomName ?? 'Relay',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // Ellipsised rather than allowed to push the action buttons off
              // the bar. At the largest text setting "Looking for people
              // nearby" is wider than a 320-point screen on its own.
              Text(
                _subtitle(reachable, verifiedInRange),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Shown only when it is true, because a permanent "Wi-Fi: off" chip
          // would be noise. It earns its place by changing what the user can
          // expect: those people are reachable fast, and over a network
          // somebody else owns.
          if (status.wifiAvailable && status.wifiPeers > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: '${status.wifiPeers} reachable on this Wi-Fi',
                child: Row(
                  key: const Key('wifi-indicator'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      // The words are dropped, not the number. On a small
                      // phone at a large text size the full label pushes the
                      // radar and settings buttons off the bar, and a count
                      // beside a Wi-Fi icon says the same thing.
                      Breakpoint.from(context) == Breakpoint.compact
                          ? '${status.wifiPeers}'
                          : '${status.wifiPeers} on Wi-Fi',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          if (status.stealthMode)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(
                Icons.visibility_off,
                key: Key('stealth-indicator'),
                size: 20,
              ),
            ),
          IconButton(
            onPressed: onOpenRadar,
            icon: const Icon(Icons.radar),
            tooltip: 'Radar',
          ),
          IconButton(
            key: const Key('open-settings'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: twoPanes
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: listPaneWidth, child: _list(context)),
                const VerticalDivider(width: 1),
                Expanded(
                  child:
                      detail ??
                      const _NoConversationSelected(
                        key: Key('no-conversation-selected'),
                      ),
                ),
              ],
            )
          : _list(context),
      // Two ways to start something, because they are different acts: a room
      // is typed and shared aloud, a friend is scanned in person. Burying
      // either behind the other would push people toward the wrong one.
      floatingActionButton: onJoinRoom == null && onOpenPairing == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (onOpenPairing != null)
                  FloatingActionButton.small(
                    key: const Key('open-pairing'),
                    heroTag: 'pairing',
                    onPressed: onOpenPairing,
                    tooltip: 'Verify a friend in person',
                    child: const Icon(Icons.qr_code_2),
                  ),
                const SizedBox(height: 12),
                if (onJoinRoom != null)
                  FloatingActionButton.extended(
                    key: const Key('join-room'),
                    heroTag: 'room',
                    onPressed: onJoinRoom,
                    icon: const Icon(Icons.groups),
                    label: const Text('Join a group'),
                  ),
              ],
            ),
    );
  }

  Widget _list(BuildContext context) => Column(
    children: [
      StatusBanner(status: status, onFix: onFixStatus),
      PresenceStrip(peers: peers, onTapPeer: onTapPeer),
      const Divider(),
      Expanded(
        child: conversations.isEmpty
            ? const _EmptyConversations()
            : ListView.separated(
                key: const Key('conversation-list'),
                itemCount: conversations.length,
                separatorBuilder: (_, _) => const Divider(indent: 72),
                itemBuilder: (context, index) => _ConversationTile(
                  conversation: conversations[index],
                  onTap: onOpenConversation,
                  // Only meaningful beside a second pane. On a phone the
                  // conversation is on top of this list, not next to it, so
                  // highlighting a row would mark something the user cannot see.
                  selected:
                      Panes.of(context) &&
                      conversations[index].id == selectedConversationId,
                ),
              ),
      ),
    ],
  );

  String _subtitle(int reachable, int verified) {
    if (!status.isHealthy) return 'Not connected';
    if (reachable == 0) return 'Looking for people nearby';
    final friends = verified == 0
        ? ''
        : ' · $verified ${verified == 1 ? 'friend' : 'friends'}';
    return '$reachable nearby$friends';
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    this.onTap,
    this.selected = false,
  });

  final Conversation conversation;
  final void Function(Conversation)? onTap;

  /// Shown open in the pane beside this list.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final last = conversation.lastMessage;
    final peer = conversation.peer;

    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.10),
      onTap: onTap == null ? null : () => onTap!(conversation),
      leading: peer != null
          ? PeerAvatar(peer: peer, size: 42)
          : const CircleAvatar(
              radius: 21,
              backgroundColor: AppColors.distant,
              child: Icon(Icons.groups, size: 20, color: Color(0xFF0F1115)),
            ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (conversation.memberCount != null) ...[
            const SizedBox(width: 6),
            Text(
              '· ${conversation.memberCount}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
      subtitle: last == null
          ? const Text('No messages yet')
          : Text(
              last.isVoice
                  ? 'Voice note · ${(last.voiceDurationMs! / 1000).round()}s'
                  : last.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (peer != null)
            _ReachChip(reach: peer.reach)
          else
            const SizedBox.shrink(),
          if (conversation.unread > 0) ...[
            const SizedBox(height: 6),
            CircleAvatar(
              // A direct request for the user's attention, distinguished from
              // an unread count. In a room that has said forty things since
              // breakfast, "someone named you" and "forty messages" are not the
              // same fact and must not look the same.
              key: conversation.hasMention
                  ? Key('mention-badge-${conversation.id}')
                  : null,
              radius: 9,
              backgroundColor: conversation.hasMention
                  ? AppColors.caution
                  : AppColors.direct,
              child: Text(
                conversation.hasMention ? '@' : '${conversation.unread}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F1115),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReachChip extends StatelessWidget {
  const _ReachChip({required this.reach});

  final Reach reach;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: reach.color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: reach.color.withValues(alpha: 0.4)),
    ),
    child: Text(
      reach.label,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: reach.color),
    ),
  );
}

/// The second pane before anything is chosen.
///
/// A prompt rather than blank space: half an empty screen reads as something
/// having failed to load.
class _NoConversationSelected extends StatelessWidget {
  const _NoConversationSelected({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Pick a conversation',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    ),
  );
}

class _EmptyConversations extends StatelessWidget {
  const _EmptyConversations();

  @override
  // Scrollable. At the largest text setting this copy is taller than the space
  // left under a presence strip on a small phone, and an empty state that
  // overflows is a worse first impression than one the user can scroll.
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const Key('conversations-empty'),
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.forum_outlined, size: 40),
        const SizedBox(height: 12),
        Text(
          'No conversations yet',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Scan a friend\'s code, or join a group with a 6-character code.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
