import 'package:flutter/foundation.dart';

/// Something the user typed into the composer.
///
/// A sealed hierarchy so the runtime's switch over it is exhaustive: adding a
/// command without handling it becomes a compile error rather than a command
/// that silently does nothing.
@immutable
sealed class Command {
  const Command();
}

/// Not a command at all. [body] is what should actually be sent.
class PlainMessage extends Command {
  const PlainMessage(this.body);

  final String body;
}

class JoinCommand extends Command {
  const JoinCommand(this.code);

  final String code;
}

/// `/msg name words…` — a direct message to one person.
class WhisperCommand extends Command {
  const WhisperCommand(this.nickname, this.body);

  final String nickname;

  /// Empty means "just open the conversation".
  final String body;
}

/// `/slap name` — the IRC standby.
///
/// A *message*, not an instruction to the app. It reads as an action, and
/// treating it as one would make the command a way to do something to somebody
/// rather than a way to say something about them. What goes out is text, in the
/// room, attributable to whoever typed it.
class SlapCommand extends Command {
  const SlapCommand(this.nickname);

  final String nickname;

  /// The line to send, as [sender] said it.
  String textFrom(String sender) =>
      '$sender slaps $nickname around a bit with a large trout';
}

class WhoCommand extends Command {
  const WhoCommand();
}

class ChannelsCommand extends Command {
  const ChannelsCommand();
}

class BlockCommand extends Command {
  const BlockCommand(this.nickname);

  final String nickname;
}

class UnblockCommand extends Command {
  const UnblockCommand(this.nickname);

  final String nickname;
}

class FavouriteCommand extends Command {
  const FavouriteCommand(this.nickname, {required this.on});

  final String nickname;
  final bool on;
}

/// `/leave` — get out of this group.
///
/// Also `/part`, because anybody who has used IRC reaches for that first.
class LeaveCommand extends Command {
  const LeaveCommand();
}

class ClearCommand extends Command {
  const ClearCommand();
}

class NickCommand extends Command {
  const NickCommand(this.name);

  final String name;
}

class ClaimCommand extends Command {
  const ClaimCommand();
}

class TransferCommand extends Command {
  const TransferCommand(this.nickname);

  final String nickname;
}

/// `/save on|off` — whether this room is kept on disk. Null reports it.
class SaveCommand extends Command {
  const SaveCommand(this.on);

  final bool? on;
}

/// `/pass CODE` — move the room to a new code.
class PassCommand extends Command {
  const PassCommand(this.code);

  final String code;
}

class HelpCommand extends Command {
  const HelpCommand();
}

/// The user typed something that looks like a command and is not one.
///
/// Never sent as a message: `/blcok sara` going out to the room would announce
/// the intent to everyone in it, which is the worst possible outcome of a typo.
class BadCommand extends Command {
  const BadCommand(this.message);

  final String message;
}

/// Turns a line of text into a [Command].
abstract final class Commands {
  /// Every command name, in help order. Checked against [help] by a test, so
  /// the two cannot drift apart.
  static const List<String> names = [
    'join',
    'msg',
    'who',
    'channels',
    'fav',
    'unfav',
    'block',
    'unblock',
    'nick',
    'clear',
    'leave',
    'slap',
    'claim',
    'transfer',
    'save',
    'pass',
    'help',
  ];

  static const String help = '''
/join CODE — join or create a group (also /j)
/msg NAME … — message one person directly
/who — who is in range
/channels — groups you are in
/fav NAME — favourite someone, so you can also reach them over the internet
/unfav NAME — stop that
/block NAME — stop seeing anything from someone
/unblock NAME — undo it
/nick NAME — change your name
/clear — erase this conversation on this phone
/leave — get out of this group and stop passing on its past (also /part)
/slap NAME — the old IRC one. Sends a message, does nothing else
/claim — claim this group, if nobody has
/transfer NAME — hand the group to someone else
/save on|off — whether this group is kept on this phone
/pass CODE — move this group to a new code
/help — this list (also /?)''';

  static Command parse(String input) {
    final text = input.trim();
    if (!text.startsWith('/')) return PlainMessage(text);

    // `//x` is how you send a message that really does start with a slash.
    if (text.startsWith('//')) return PlainMessage(text.substring(1));

    final space = text.indexOf(' ');
    final name = (space < 0 ? text.substring(1) : text.substring(1, space))
        .toLowerCase();
    final rest = space < 0 ? '' : text.substring(space + 1).trim();

    if (name.isEmpty) return PlainMessage(text);

    String? oneWord() => rest.isEmpty ? null : rest.split(RegExp(r'\s+')).first;

    switch (name) {
      case 'j':
      case 'join':
        final code = oneWord();
        return code == null
            ? const BadCommand('Which group? Try /join RUFF7A')
            : JoinCommand(code);

      case 'msg':
      case 'w':
        if (rest.isEmpty) return const BadCommand('Who? Try /msg sara hello');
        final split = rest.indexOf(' ');
        return split < 0
            ? WhisperCommand(rest, '')
            : WhisperCommand(
                rest.substring(0, split),
                rest.substring(split + 1).trim(),
              );

      case 'slap':
        return rest.isEmpty
            ? const BadCommand('Slap who? Try /slap sara')
            : SlapCommand(rest);

      case 'who':
        return const WhoCommand();

      case 'channels':
        return const ChannelsCommand();

      case 'fav':
      case 'unfav':
        final who = oneWord();
        return who == null
            ? BadCommand('Who? Try /$name sara')
            : FavouriteCommand(who, on: name == 'fav');

      case 'block':
        final who = oneWord();
        // Refused rather than guessed. In a room, `/block` on its own could
        // plausibly mean anyone present, and silencing the wrong person is a
        // worse failure than making the user type a name.
        return who == null
            ? const BadCommand('Who? Try /block sara')
            : BlockCommand(who);

      case 'unblock':
        final who = oneWord();
        return who == null
            ? const BadCommand('Who? Try /unblock sara')
            : UnblockCommand(who);

      case 'nick':
        final who = oneWord();
        return who == null
            ? const BadCommand('What name? Try /nick sara')
            : NickCommand(who);

      case 'clear':
        return const ClearCommand();

      // Takes no argument, and anything typed after it is ignored rather than
      // refused: "/leave now" is somebody leaving, not a syntax error.
      case 'leave':
      case 'part':
        return const LeaveCommand();

      case 'claim':
        return const ClaimCommand();

      case 'transfer':
        final who = oneWord();
        return who == null
            ? const BadCommand('Hand it to whom? Try /transfer sara')
            : TransferCommand(who);

      case 'save':
        return switch (oneWord()?.toLowerCase()) {
          null => const SaveCommand(null),
          'on' => const SaveCommand(true),
          'off' => const SaveCommand(false),
          _ => const BadCommand('Try /save on or /save off'),
        };

      case 'pass':
        final code = oneWord();
        return code == null
            ? const BadCommand('What code? Try /pass ZEBRA7')
            : PassCommand(code);

      case 'help':
      case '?':
        return const HelpCommand();

      default:
        return BadCommand('/$name is not a command. Type /help for the list.');
    }
  }
}
