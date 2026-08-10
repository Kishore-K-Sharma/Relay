import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/commands.dart';

/// Typing a command instead of a message.
///
/// Pure parsing: nothing here touches a radio or a database, so every form a
/// user might type can be checked cheaply.
void main() {
  test('ordinary text is not a command', () {
    expect(Commands.parse('hello everyone'), isA<PlainMessage>());
    expect(Commands.parse(''), isA<PlainMessage>());
  });

  test('a lone slash is not a command', () {
    // Someone typing a path, a fraction, or nothing much.
    expect(Commands.parse('/'), isA<PlainMessage>());
    expect(Commands.parse('/ '), isA<PlainMessage>());
  });

  test('an escaped slash sends a literal slash', () {
    // The only way to start a message with a slash and mean it.
    final parsed = Commands.parse('//not a command');

    expect((parsed as PlainMessage).body, '/not a command');
  });

  test('joining a group', () {
    final parsed = Commands.parse('/j RUFF7A') as JoinCommand;

    expect(parsed.code, 'RUFF7A');
  });

  test('join accepts its long name too', () {
    expect((Commands.parse('/join RUFF7A') as JoinCommand).code, 'RUFF7A');
  });

  test('commands are case-insensitive', () {
    expect(Commands.parse('/WHO'), isA<WhoCommand>());
  });

  test('extra whitespace does not matter', () {
    expect((Commands.parse('  /j   RUFF7A  ') as JoinCommand).code, 'RUFF7A');
  });

  test('a direct message keeps the rest of the line intact', () {
    final parsed = Commands.parse('/msg sara are you here?') as WhisperCommand;

    expect(parsed.nickname, 'sara');
    expect(parsed.body, 'are you here?');
  });

  test('a direct message with no words is still valid', () {
    // It opens the conversation rather than sending an empty message.
    final parsed = Commands.parse('/msg sara') as WhisperCommand;

    expect(parsed.nickname, 'sara');
    expect(parsed.body, isEmpty);
  });

  test('who and channels take no argument', () {
    expect(Commands.parse('/who'), isA<WhoCommand>());
    expect(Commands.parse('/channels'), isA<ChannelsCommand>());
  });

  test('blocking names somebody', () {
    expect((Commands.parse('/block sara') as BlockCommand).nickname, 'sara');
    expect(
      (Commands.parse('/unblock sara') as UnblockCommand).nickname,
      'sara',
    );
  });

  test('blocking nobody in particular is an error, not a silent no-op', () {
    // `/block` on its own in a room could plausibly mean anyone. Refusing is
    // safer than guessing which person to silence.
    expect(Commands.parse('/block'), isA<BadCommand>());
  });

  test('favouriting names somebody', () {
    expect((Commands.parse('/fav sara') as FavouriteCommand).nickname, 'sara');
    expect(
      (Commands.parse('/unfav sara') as FavouriteCommand).nickname,
      'sara',
    );
    expect((Commands.parse('/unfav sara') as FavouriteCommand).on, isFalse);
  });

  test('clearing this conversation', () {
    expect(Commands.parse('/clear'), isA<ClearCommand>());
  });

  test('renaming yourself', () {
    expect((Commands.parse('/nick Sara') as NickCommand).name, 'Sara');
    expect(Commands.parse('/nick'), isA<BadCommand>());
  });

  test('claiming a room', () {
    expect(Commands.parse('/claim'), isA<ClaimCommand>());
  });

  test('handing a room over', () {
    expect(
      (Commands.parse('/transfer sara') as TransferCommand).nickname,
      'sara',
    );
    expect(Commands.parse('/transfer'), isA<BadCommand>());
  });

  test('turning saving on and off', () {
    expect((Commands.parse('/save on') as SaveCommand).on, isTrue);
    expect((Commands.parse('/save off') as SaveCommand).on, isFalse);
  });

  test('save with no argument reports the setting rather than guessing', () {
    expect((Commands.parse('/save') as SaveCommand).on, isNull);
  });

  test('save refuses anything that is not on or off', () {
    expect(Commands.parse('/save maybe'), isA<BadCommand>());
  });

  test('changing the code', () {
    expect((Commands.parse('/pass ZEBRA7') as PassCommand).code, 'ZEBRA7');
    expect(Commands.parse('/pass'), isA<BadCommand>());
  });

  test('help', () {
    expect(Commands.parse('/help'), isA<HelpCommand>());
    expect(Commands.parse('/?'), isA<HelpCommand>());
  });

  test('an unknown command says so rather than being sent as a message', () {
    // Sending `/blcok sara` to the room would leak the intent to everyone in
    // it, which is the worst possible outcome of a typo.
    final parsed = Commands.parse('/blcok sara') as BadCommand;

    expect(parsed.message, contains('/blcok'));
  });

  test('every command is listed in the help text', () {
    // The help is the only discovery mechanism there is, so it going stale is
    // a real failure rather than a documentation nicety.
    for (final name in Commands.names) {
      expect(
        Commands.help,
        contains('/$name'),
        reason: '/$name is missing from the help',
      );
    }
  });
  group('/slap', () {
    test('names the person', () {
      final command = Commands.parse('/slap sara') as SlapCommand;

      expect(command.nickname, 'sara');
    });

    test('is a message, not an instruction to the app', () {
      // It reads as an action but it is text, sent to the room like any other
      // message. Anything else would make it a way to do something to somebody
      // rather than say something about them.
      expect(Commands.parse('/slap sara'), isA<SlapCommand>());
    });

    test('with nobody named is refused rather than sent', () {
      expect(Commands.parse('/slap'), isA<BadCommand>());
    });

    test('the text says who did it and to whom', () {
      expect(
        const SlapCommand('sara').textFrom('zehra'),
        allOf(contains('zehra'), contains('sara')),
      );
    });

    test('it is listed in help', () {
      expect(Commands.help, contains('/slap'));
      expect(Commands.names, contains('slap'));
    });
  });

  /// Leaving a group.
  ///
  /// `MeshRuntime.leaveRoom` existed, was tested, and had no caller anywhere in
  /// the product: a user could join a group and never get out of it. That is
  /// not only an inconvenience — while you are in a room you keep answering
  /// other people's requests for its history, so staying in one you have
  /// forgotten about means serving its past to strangers indefinitely.
  group('/leave', () {
    test('is a command', () {
      expect(Commands.parse('/leave'), isA<LeaveCommand>());
    });

    test('takes the IRC spelling too', () {
      // Anybody who has used IRC will reach for /part first.
      expect(Commands.parse('/part'), isA<LeaveCommand>());
    });

    test('ignores anything after it', () {
      // `/leave now` is somebody leaving, not a syntax error worth refusing.
      expect(Commands.parse('/leave now'), isA<LeaveCommand>());
    });

    test('it is listed in help', () {
      expect(Commands.help, contains('/leave'));
      expect(Commands.names, contains('leave'));
    });
  });
}
