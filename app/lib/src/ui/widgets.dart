import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/theme.dart';

/// Avatar with a reachability ring.
///
/// The ring, not the avatar, carries the information: in a mesh the useful
/// question is never "who exists" but "who can I reach right now".
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.peer, this.size = 44});

  final Peer peer;
  final double size;

  @override
  Widget build(BuildContext context) {
    final reach = peer.reach;
    final initial = peer.nickname.isEmpty
        ? '?'
        : peer.nickname[0].toUpperCase();

    return Semantics(
      label:
          '${peer.nickname}, ${reach.label}'
          '${peer.trust == TrustBadge.verified ? ', verified' : ''}',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: reach.color.withValues(alpha: peer.isReachable ? 1 : 0.35),
              border: Border.all(color: reach.color, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.38,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F1115),
              ),
            ),
          ),
          if (peer.trust == TrustBadge.verified)
            const Positioned(
              right: -2,
              bottom: -2,
              child: _Badge(icon: Icons.verified, color: AppColors.direct),
            ),
          if (peer.trust == TrustBadge.keyChanged)
            const Positioned(
              right: -2,
              bottom: -2,
              child: _Badge(icon: Icons.error, color: AppColors.danger),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      shape: BoxShape.circle,
    ),
    child: Icon(icon, size: 13, color: color),
  );
}

/// Horizontal strip of who is actually reachable, above the chat list.
///
/// This is the core of the layout. A conventional messenger hides live
/// presence, but in a crowd it changes every few seconds as people move, and
/// it is the thing users are really asking the app.
class PresenceStrip extends StatelessWidget {
  const PresenceStrip({
    super.key,
    required this.peers,
    this.onTapPeer,
    this.maxShown = 8,
  });

  final List<Peer> peers;
  final void Function(Peer peer)? onTapPeer;
  final int maxShown;

  @override
  Widget build(BuildContext context) {
    // Favourites are listed whether or not they are in range. Everyone else
    // has to be reachable to appear: a strip full of people who left an hour
    // ago would misdescribe the room, which is the one thing this widget is
    // for. An absent favourite is shown as absent rather than hidden, because
    // the user needs somewhere to tap to write to them.
    final listed = peers.where((p) => p.isReachable || p.isFavourite).toList()
      ..sort((a, b) {
        if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
        return (a.hops ?? 99).compareTo(b.hops ?? 99);
      });

    if (listed.isEmpty) return const _EmptyPresence();

    final shown = listed.take(maxShown).toList();
    final overflow = listed.length - shown.length;

    return SizedBox(
      // Tall enough for an absent favourite's second line. Fixed rather than
      // measured so the strip does not change height as people come and go,
      // which would shove the conversation list up and down under the user's
      // thumb.
      height: 98,
      child: ListView.separated(
        key: const Key('presence-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: shown.length + (overflow > 0 ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          if (index >= shown.length) {
            return _PresenceItem(label: '+$overflow', sublabel: 'more');
          }
          final peer = shown[index];
          return GestureDetector(
            onTap: onTapPeer == null ? null : () => onTapPeer!(peer),
            child: _PresenceItem(
              avatar: PeerAvatar(peer: peer),
              sublabel: peer.nickname,
              // Stated, not implied by position. "Not in range" is the whole
              // reason this entry looks different from the ones beside it, and
              // leaving the user to infer it from a dimmer avatar would be
              // showing someone as present who is not.
              detail: peer.isReachable ? null : 'Not in range',
              // Only ever present for somebody one hop away; see [Peer.signal].
              signal: SignalBars(peer: peer),
              favouriteKey: peer.isFavourite
                  ? Key('favourite-mark-${peer.id}')
                  : null,
            ),
          );
        },
      ),
    );
  }
}

class _PresenceItem extends StatelessWidget {
  const _PresenceItem({
    this.avatar,
    this.label,
    required this.sublabel,
    this.detail,
    this.signal,
    this.favouriteKey,
  });

  final Widget? avatar;
  final String? label;
  final String sublabel;

  /// A second line, used to say "Not in range" rather than leaving the user to
  /// infer it.
  final String? detail;

  /// Radio strength, where there is one to show. Renders nothing otherwise.
  final Widget? signal;

  /// Non-null for a favourite; carries the key the tests look for.
  final Key? favouriteKey;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            avatar ??
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF3A3F4A),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    label ?? '',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            if (favouriteKey != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: Icon(
                  Icons.star_rounded,
                  key: favouriteKey,
                  size: 16,
                  color: AppColors.caution,
                ),
              ),
            // Top-left, clear of the favourite star. Strength answers a
            // different question from reach — "across the room" versus
            // "somewhere in the building" — and in a crowd that is the one
            // the user is actually asking.
            if (signal != null) Positioned(left: -1, top: -1, child: signal!),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          sublabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        if (detail != null)
          Text(
            detail!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).disabledColor,
            ),
          ),
      ],
    ),
  );
}

/// Three quick taps, and everything on the phone is destroyed.
///
/// No confirmation, on purpose. The situation this exists for is somebody
/// reaching for the phone, and a dialog in that moment is the same as not
/// having the feature. That makes an accidental trigger unrecoverable, so two
/// things guard it: it is off until the user switches it on, having read what
/// it does, and the taps must be quick — three taps spread over two seconds is
/// somebody fidgeting, not an emergency.
class PanicTapTarget extends StatefulWidget {
  const PanicTapTarget({
    super.key,
    required this.child,
    required this.onTriggered,
    this.enabled = false,
    this.window = const Duration(milliseconds: 700),
    this.taps = 3,
  });

  final Widget child;
  final VoidCallback onTriggered;

  /// Off until the user opts in. See the comment above.
  final bool enabled;

  /// The longest gap allowed between consecutive taps.
  final Duration window;

  final int taps;

  @override
  State<PanicTapTarget> createState() => _PanicTapTargetState();
}

class _PanicTapTargetState extends State<PanicTapTarget> {
  int _count = 0;
  Timer? _expiry;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  void _onTap() {
    if (!widget.enabled) return;

    // A timer rather than comparing wall-clock stamps: the count has to lapse
    // on its own even if the user never taps again, and taps minutes apart
    // must never accumulate into a wipe.
    _expiry?.cancel();
    _count++;

    if (_count >= widget.taps) {
      // Reset before firing. A fourth tap must not run the whole thing again,
      // and the widget may well be gone by the time the callback returns.
      _count = 0;
      widget.onTriggered();
      return;
    }

    _expiry = Timer(widget.window, () => _count = 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const Key('panic-tap-target'),
    behavior: HitTestBehavior.opaque,
    onTap: _onTap,
    child: widget.child,
  );
}

class _EmptyPresence extends StatelessWidget {
  const _EmptyPresence();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('presence-empty'),
    height: 84,
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Text(
      'Nobody in range yet. Relay keeps looking.',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Radio strength, as bars.
///
/// Renders nothing at all when the strength is unknown — deliberately blank
/// rather than zero bars, because zero bars means "measured, and bad" and a
/// peer reached over Wi-Fi or through a relay was never measured.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.peer, this.height = 12});

  final Peer peer;
  final double height;

  @override
  Widget build(BuildContext context) {
    final signal = peer.signal;
    if (signal == null) return const SizedBox.shrink();

    final colour = peer.reach.color;
    return Semantics(
      label: signal.label,
      child: Row(
        key: const Key('signal-bars'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var bar = 1; bar <= 3; bar++) ...[
            if (bar > 1) const SizedBox(width: 2),
            Container(
              width: 3,
              height: height * (bar / 3),
              decoration: BoxDecoration(
                color: colour.withValues(alpha: bar <= signal.bars ? 1 : 0.22),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows message state honestly, including the states other apps hide.
class MessageStateChip extends StatelessWidget {
  const MessageStateChip({super.key, required this.state});

  final MessageState state;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      MessageState.queued => (Icons.schedule, AppColors.unreachable),
      MessageState.sent => (Icons.arrow_upward, AppColors.nearby),
      MessageState.delivered => (Icons.done_all, AppColors.direct),
      MessageState.read => (Icons.done_all, AppColors.direct),
      MessageState.failed => (Icons.error_outline, AppColors.danger),
      MessageState.expired => (Icons.timer_off, AppColors.danger),
    };

    return Semantics(
      label: state.label,
      child: ConstrainedBox(
        // This sits inside a Wrap, which hands its children unbounded width —
        // so a Flexible here would do nothing and "Never delivered" at a large
        // text size runs straight out of the bubble. The cap is what makes the
        // ellipsis below reachable.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            // Ellipsised only visually. The full label is on the Semantics
            // above, so a screen reader still says "Never delivered".
            Flexible(
              child: Text(
                state.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Persistent banner for a degraded transport. Never silently swallowed.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.status, this.onFix});

  final MeshStatus status;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final problem = status.problem;
    if (problem == null) return const SizedBox.shrink();

    final blocking = !status.isHealthy;

    return Material(
      key: const Key('status-banner'),
      color: (blocking ? AppColors.danger : AppColors.caution).withValues(
        alpha: 0.15,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              blocking ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: blocking ? AppColors.danger : AppColors.caution,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                problem,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (onFix != null)
              TextButton(onPressed: onFix, child: const Text('Fix')),
          ],
        ),
      ),
    );
  }
}

/// Marks a message somebody carried here rather than one that arrived by radio.
///
/// Deliberately quiet — an icon and two words beside the timestamp, not a
/// banner. It changes how a reader should treat the message without competing
/// with the message itself.
///
/// The wording avoids "courier" everywhere it faces the user. That word is from
/// the protocol notes and means nothing to somebody holding a phone; "carried"
/// is what actually happened.
class CarriedChip extends StatelessWidget {
  const CarriedChip({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message:
        'Somebody carried this to you. It may have been written a while ago, '
        'and the person who sent it may still be out of range.',
    child: Row(
      key: const Key('carried-chip'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.directions_walk, size: 13, color: AppColors.distant),
        const SizedBox(width: 4),
        Text(
          'Carried',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: AppColors.distant),
        ),
      ],
    ),
  );
}
