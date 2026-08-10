import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/mentions.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/theme.dart';
import 'package:relay_app/src/ui/widgets.dart';

/// A single conversation.
///
/// Two things here are deliberate and non-negotiable:
///  - every outgoing message shows its real state, including the states other
///    messengers hide;
///  - a room shows a standing reminder that its code is its only protection,
///    rather than a lock icon implying otherwise.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversation,
    this.onSend,
    this.onRecordVoice,
    this.onRetry,
    this.onBlock,
    this.onFavourite,
    this.mentionCandidates = const [],
    this.showBackButton = true,
    this.onSendByCourier,
    this.onLeave,
    this.onPlayVoice,
    this.playingMessageId,
  });

  /// Whether the header offers a way back to the list.
  ///
  /// False when this sits beside the list rather than on top of it: there is
  /// nothing to go back to, and an arrow that does nothing is worse than none.
  final bool showBackButton;

  final Conversation conversation;
  final void Function(String body)? onSend;
  final VoidCallback? onRecordVoice;
  final void Function(Message)? onRetry;

  /// Asks somebody nearby to carry a message that has not got through.
  ///
  /// Null when the screen has no runtime behind it, which is also how the
  /// action stays hidden rather than present and dead.
  final void Function(Message)? onSendByCourier;

  /// Stops showing anything from this person. Direct conversations only: a
  /// room has many senders and blocking one of them is a different feature.
  final VoidCallback? onBlock;

  /// Plays a voice note back. Null leaves the note showing as a plain
  /// duration rather than as a control that does nothing.
  final void Function(Message)? onPlayVoice;

  /// The note currently playing, so its control can show it.
  final String? playingMessageId;

  /// Gets out of this group. Rooms only — a direct conversation has nothing to
  /// leave, and blocking is the equivalent there.
  final VoidCallback? onLeave;

  /// Toggles whether this person is one the user has chosen.
  ///
  /// Direct conversations only, for the same reason as [onBlock].
  final VoidCallback? onFavourite;

  /// Names to offer when the user types `@`.
  ///
  /// Used only in a room. A direct conversation has exactly one other person in
  /// it, and offering to name them would be noise in front of the keyboard.
  final List<String> mentionCandidates;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend?.call(text);
    _controller.clear();
  }

  Future<void> _confirmBlock(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Block ${widget.conversation.title}?'),
        content: const Text(
          'You will stop seeing anything they send, and nothing more will be '
          'sent to them. Your phone keeps passing on other people\'s messages '
          'as normal, including theirs — that is what keeps the mesh working '
          'for everyone standing near them, and it means they cannot tell they '
          'have been blocked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-block'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Block',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) widget.onBlock?.call();
  }

  static bool _isDirect(Conversation conversation) =>
      conversation.kind == ConversationKind.direct;

  bool _menuHasAnything(Conversation conversation) => _isDirect(conversation)
      ? widget.onBlock != null || widget.onFavourite != null
      : widget.onLeave != null;

  Future<void> _confirmLeave(BuildContext context, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // Names the group. On a tablet two conversations are open at once, and
        // "leave this group?" is genuinely ambiguous there.
        title: Text('Leave $title?'),
        content: const Text(
          'Your phone will stop passing on what is said here, and stop '
          'answering other people who ask for this group\'s past. You can '
          'join again any time — but only with the code, so make sure you '
          'still have it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            key: const Key('leave-room-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Leave',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) widget.onLeave?.call();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    final peer = conversation.peer;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBackButton,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Both ellipsised. A long nickname at a large text size is wider
            // than a small phone on its own, and letting it push the verified
            // badge and the menu off the bar would cost the user the two
            // controls that matter most here.
            Text(
              conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              peer != null
                  ? peer.reach.label
                  : '${conversation.memberCount ?? 0} people',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: peer?.reach.color),
            ),
          ],
        ),
        actions: [
          if (peer?.trust == TrustBadge.verified)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(Icons.verified, size: 18, color: AppColors.direct),
            ),
          // Built from whatever actions this kind of conversation actually
          // has. A menu button that opens an empty sheet is worse than no
          // button, so the whole thing is absent when there is nothing in it.
          if (_menuHasAnything(conversation))
            PopupMenuButton<void>(
              key: const Key('conversation-menu'),
              itemBuilder: (context) => [
                if (widget.onFavourite != null && _isDirect(conversation))
                  PopupMenuItem<void>(
                    key: const Key('favourite-peer'),
                    onTap: widget.onFavourite,
                    // Says what it buys. Starring turns on the internet relay
                    // for this person, which hands a third party the fact that
                    // the two of you are talking — a real trade, and not one to
                    // hide behind a bare star icon.
                    child: Text(
                      peer?.isFavourite ?? false
                          ? 'Remove from favourites'
                          : 'Favourite — also reach them over the internet',
                    ),
                  ),
                if (widget.onBlock != null && _isDirect(conversation))
                  PopupMenuItem<void>(
                    key: const Key('block-peer'),
                    onTap: () => _confirmBlock(context),
                    child: const Text('Block this person'),
                  ),
                if (widget.onLeave != null && !_isDirect(conversation))
                  PopupMenuItem<void>(
                    key: const Key('leave-room'),
                    onTap: () => _confirmLeave(context, conversation.title),
                    child: const Text('Leave this group'),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (peer?.trust == TrustBadge.keyChanged) const _KeyChangedWarning(),
          if (conversation.kind == ConversationKind.room) const _RoomReminder(),
          Expanded(
            child: conversation.messages.isEmpty
                ? const Center(
                    key: Key('conversation-empty'),
                    child: Text('No messages yet'),
                  )
                : ListView.builder(
                    key: const Key('message-list'),
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: conversation.messages.length,
                    itemBuilder: (context, index) => _MessageBubble(
                      message: conversation.messages[index],
                      onRetry: widget.onRetry,
                      // Only in a direct conversation. An envelope is sealed to
                      // exactly one recipient's key, so there is no such thing
                      // as couriering to a room, and offering it would be a lie
                      // the user only discovers after tapping.
                      onSendByCourier:
                          conversation.kind == ConversationKind.direct
                          ? widget.onSendByCourier
                          : null,
                      onPlayVoice: widget.onPlayVoice,
                      isPlaying:
                          widget.playingMessageId ==
                          conversation.messages[index].id,
                    ),
                  ),
          ),
          _Composer(
            controller: _controller,
            onSend: _submit,
            onRecordVoice: widget.onRecordVoice,
            mentionCandidates: conversation.kind == ConversationKind.room
                ? widget.mentionCandidates
                : const [],
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onRetry,
    this.onSendByCourier,
    this.onPlayVoice,
    this.isPlaying = false,
  });

  final Message message;
  final void Function(Message)? onRetry;
  final void Function(Message)? onSendByCourier;
  final void Function(Message)? onPlayVoice;
  final bool isPlaying;

  /// How wide a bubble may get.
  ///
  /// Most of the line on a phone, so a message is not a narrow column; capped
  /// on a wide window, where a bubble spanning 1300 points would be unreadable
  /// for the same reason a paragraph is.
  static double _maxBubbleWidth(BuildContext context) {
    final available = MediaQuery.sizeOf(context).width - 32;
    return available * 0.78 > 460 ? 460 : available * 0.78;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.fromMe;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // A share of the width rather than a fixed 300 points. Fixed was wrong
        // in both directions: wider than a 320-point phone can show, and a
        // narrow ribbon down the middle of a tablet.
        constraints: BoxConstraints(maxWidth: _maxBubbleWidth(context)),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine && message.senderName != null)
              Text(
                message.senderName!,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: scheme.primary),
              ),
            if (message.isVoice)
              _VoiceBody(
                durationMs: message.voiceDurationMs!,
                messageId: message.id,
                isPlaying: isPlaying,
                onPlay: onPlayVoice == null
                    ? null
                    : () => onPlayVoice!(message),
              )
            else
              _MessageBody(message: message, scheme: scheme),
            const SizedBox(height: 4),
            // Wrap, not Row: a long state label such as "Never delivered"
            // beside a retry action overflows a narrow bubble.
            Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (mine) MessageStateChip(state: message.state),
                if (message.viaCourier) const CarriedChip(),
                // Offered while a message has not got through — which is the
                // only moment a courier is any use, and covers both "still
                // waiting" and "gave up".
                if (mine &&
                    !message.state.isConfirmed &&
                    onSendByCourier != null)
                  GestureDetector(
                    key: const Key('send-by-courier'),
                    onTap: () => onSendByCourier!(message),
                    child: Text(
                      'Send by hand',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                if (mine && message.state.isTerminal && onRetry != null)
                  GestureDetector(
                    key: const Key('retry-button'),
                    onTap: () => onRetry!(message),
                    child: Text(
                      'Try again',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Message text with any `@names` picked out.
///
/// A mention of the reader gets a marker of its own rather than only a colour:
/// colour alone is invisible to a large minority of users, and the whole point
/// of the feature is that this message is the one they must not miss.
class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message, required this.scheme});

  final Message message;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final found = Mentions.parse(message.body);
    final body = found.isEmpty
        ? Text(message.body)
        : Text.rich(TextSpan(children: _spans(found)));

    if (!message.mentionsYou) return body;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 6),
          child: Icon(
            Icons.alternate_email,
            key: Key('mention-mark-${message.id}'),
            size: 15,
            color: scheme.primary,
          ),
        ),
        Flexible(child: body),
      ],
    );
  }

  List<InlineSpan> _spans(List<Mention> found) {
    final spans = <InlineSpan>[];
    var at = 0;

    for (final mention in found) {
      if (mention.start > at) {
        spans.add(TextSpan(text: message.body.substring(at, mention.start)));
      }
      spans.add(
        TextSpan(
          text: message.body.substring(mention.start, mention.end),
          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
        ),
      );
      at = mention.end;
    }

    if (at < message.body.length) {
      spans.add(TextSpan(text: message.body.substring(at)));
    }
    return spans;
  }
}

class _VoiceBody extends StatelessWidget {
  const _VoiceBody({
    required this.durationMs,
    required this.messageId,
    this.onPlay,
    this.isPlaying = false,
  });

  final int durationMs;
  final String messageId;
  final VoidCallback? onPlay;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    if (onPlay == null) return row;

    // A control, not a decoration. The arrow was an Icon with nothing behind
    // it for as long as voice notes have existed.
    return Semantics(
      button: true,
      label: isPlaying
          ? 'Stop this voice message'
          : 'Play this voice message, ${_seconds}s',
      child: InkWell(
        key: Key('play-voice-$messageId'),
        onTap: onPlay,
        child: row,
      ),
    );
  }

  String get _seconds => (durationMs / 1000).round().toString();

  Widget _row(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(isPlaying ? Icons.stop : Icons.play_arrow, size: 20),
      const SizedBox(width: 6),
      // A real waveform needs the decoded audio; a fixed bar row communicates
      // "this is a voice note of roughly this length" without pretending to
      // show data we do not have yet.
      //
      // Flexible, because at a large text size the duration beside it needs
      // the room more than the decoration does.
      Flexible(
        child: SizedBox(
          width: 90,
          height: 18,
          child: ClipRect(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(
                14,
                (i) => Container(
                  width: 3,
                  height: 4.0 + (i * 7 % 13),
                  decoration: BoxDecoration(
                    color: AppColors.direct.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('${(durationMs / 1000).round()}s'),
    ],
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    this.onRecordVoice,
    this.mentionCandidates = const [],
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onRecordVoice;

  /// Names offered when the user types `@`. Empty in a direct conversation,
  /// where there is exactly one other person and naming them is noise.
  final List<String> mentionCandidates;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MentionSuggestions(
          controller: controller,
          candidates: mentionCandidates,
        ),
        _inputRow(context),
      ],
    ),
  );

  Widget _inputRow(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('composer-field'),
            controller: controller,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: const InputDecoration(
              hintText: 'Message',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        IconButton(
          key: const Key('voice-button'),
          onPressed: onRecordVoice,
          icon: const Icon(Icons.mic),
          tooltip: 'Hold to record a voice note (max 30s)',
        ),
        IconButton(
          key: const Key('send-button'),
          onPressed: onSend,
          icon: const Icon(Icons.send),
        ),
      ],
    ),
  );
}

/// The names on offer while an `@` is being typed.
///
/// Listens to the controller rather than being rebuilt by the screen, so a
/// keystroke does not rebuild the whole message list underneath it.
class _MentionSuggestions extends StatelessWidget {
  const _MentionSuggestions({
    required this.controller,
    required this.candidates,
  });

  final TextEditingController controller;
  final List<String> candidates;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        // The cursor, not the end of the text. Someone editing the middle of a
        // sentence is mentioning whoever is under their cursor.
        final cursor = value.selection.isValid
            ? value.selection.baseOffset
            : value.text.length;
        final query = Mentions.activeQuery(value.text, cursor);
        if (query == null) return const SizedBox.shrink();

        final matches = Mentions.suggest(candidates, query.query);
        if (matches.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          key: const Key('mention-suggestions'),
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: matches.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => ActionChip(
              label: Text(matches[index]),
              onPressed: () {
                final completed = Mentions.complete(
                  value.text,
                  cursor,
                  matches[index],
                );
                controller.value = TextEditingValue(
                  text: completed.text,
                  selection: TextSelection.collapsed(offset: completed.cursor),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _RoomReminder extends StatelessWidget {
  const _RoomReminder();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('room-reminder'),
    width: double.infinity,
    color: AppColors.caution.withValues(alpha: 0.12),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      'Anyone with this group code can read these messages',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

class _KeyChangedWarning extends StatelessWidget {
  const _KeyChangedWarning();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('key-changed-warning'),
    width: double.infinity,
    color: AppColors.danger.withValues(alpha: 0.18),
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        const Icon(Icons.error, size: 18, color: AppColors.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'This contact\'s security code changed. It may not be them. '
            'Scan their code again in person before trusting this chat.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}
