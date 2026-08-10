import 'package:core_identity/core_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relay_app/src/ui/responsive.dart';
import 'package:relay_app/src/ui/theme.dart';

/// Join a group room by code.
///
/// The security warning on this screen is a product requirement, not a nicety.
/// A 6-character code is roughly 30 bits of entropy and grants permanent read
/// access to everyone who learns it, with no forward secrecy. Presenting rooms
/// with the same lock affordance as a verified direct message would make the
/// app lie about what it protects.
class JoinRoomScreen extends StatefulWidget {
  const JoinRoomScreen({super.key, this.onJoin});

  final void Function(RoomCode code)? onJoin;

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  final _controller = TextEditingController();
  String? _error;

  /// True once the code on screen came from [RoomCode.generate].
  ///
  /// Tracked only to change what the screen says. A group exists as soon as
  /// anyone types its code, so creating and joining are the same act
  /// underneath — but they are not the same to the person doing them, and
  /// somebody who has just invented a group needs telling that nobody else
  /// will ever find it unless they pass the code on themselves.
  bool _generated = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Puts a random code in the field.
  ///
  /// Worth having as a button rather than leaving people to invent their own:
  /// a human-chosen code is not random. People pick FEST24 and PARTY7, and a
  /// guesser starts with exactly those. This one uses the full code space.
  void _generate() {
    setState(() {
      _controller.text = RoomCode.generate().value;
      _generated = true;
      _error = null;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Code copied')));
  }

  void _submit() {
    try {
      final code = RoomCode.parse(_controller.text);
      setState(() => _error = null);
      widget.onJoin?.call(code);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a group')),
      // Scrollable, and the button lives outside it. A fixed column here
      // overflowed by 849 points at the largest text setting: the notice about
      // what a code protects is several lines long, and it is the last thing
      // that should disappear when the text grows.
      body: ReadableWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Everyone types the same code',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'No scanning needed. Good for a group of friends at one place.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('room-code-field'),
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                maxLength: roomCodeLength,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 30,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w700,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp('[${roomCodeAlphabet}a-z]'),
                  ),
                ],
                decoration: InputDecoration(
                  hintText: 'FEST24',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  // Typed over, so it is no longer the code we generated and the
                  // "tell people about it" copy no longer applies.
                  if (_generated) setState(() => _generated = false);
                },
              ),
              // Wrapped, not a Row. Two labelled buttons do not fit side by side
              // on a 320-point screen, and at larger text sizes neither fits
              // alone.
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    key: const Key('generate-code'),
                    onPressed: _generate,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Start a new group'),
                  ),
                  if (_controller.text.isNotEmpty)
                    TextButton.icon(
                      key: const Key('copy-code'),
                      onPressed: _copy,
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy'),
                    ),
                ],
              ),
              if (_generated) ...[
                const SizedBox(height: 8),
                Text(
                  'Tell it to the people you want in the group. There is no '
                  'invite link and no list of groups — a code only reaches '
                  'someone if you pass it on.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              // Shown on the generated path too. A random code is harder to
              // guess; it is still read aloud across a room, and anyone who
              // hears it reads the group forever. Hiding this here would be the
              // moment the app started overstating what it protects.
              const RoomSecurityNotice(),
            ],
          ),
        ),
      ),
      // Kept out of the scroll view so the primary action is always reachable,
      // however long the text above it becomes.
      bottomNavigationBar: SafeArea(
        child: ReadableWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: FilledButton(
              key: const Key('join-button'),
              onPressed: _submit,
              child: Text(_generated ? 'Create group' : 'Join group'),
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain-language statement of what a room code does and does not protect.
class RoomSecurityNotice extends StatelessWidget {
  const RoomSecurityNotice({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('room-security-notice'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.caution.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.caution.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18, color: AppColors.caution),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Anyone who knows this code can read the group',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Group codes are short and easy to guess or overhear. They are '
                'for convenience, not secrecy. For a private conversation, scan '
                "a friend's code instead.",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
