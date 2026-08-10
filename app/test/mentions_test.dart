import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/domain/mentions.dart';

/// Naming someone in a group.
///
/// A room can hold everyone in a building. Without a way to address one person
/// inside it, either everybody reads everything or nobody reads anything.
void main() {
  group('parse', () {
    test('finds a name', () {
      final found = Mentions.parse('hey @sara are you here');

      expect(found.single.name, 'sara');
      expect(found.single.start, 4);
      expect(found.single.end, 9);
    });

    test('finds several', () {
      expect(Mentions.parse('@sara @ben both of you').map((m) => m.name), [
        'sara',
        'ben',
      ]);
    });

    test('ignores an @ inside a word', () {
      // Otherwise every email address in a message becomes a mention of a
      // person who does not exist.
      expect(Mentions.parse('write to sara@example.com'), isEmpty);
    });

    test('ignores a bare @', () {
      expect(Mentions.parse('what @ even is this'), isEmpty);
    });

    test('stops at punctuation', () {
      expect(Mentions.parse('thanks @ben!').single.name, 'ben');
      expect(Mentions.parse('(@ben) said so').single.name, 'ben');
    });

    test('allows the characters people actually use in names', () {
      expect(Mentions.parse('@a_b-c9 hi').single.name, 'a_b-c9');
    });

    test('handles names outside the Latin alphabet', () {
      // A mention feature that only works in English is not a mention feature.
      expect(Mentions.parse('@сара привет').single.name, 'сара');
      expect(Mentions.parse('@さくら こんにちは').single.name, 'さくら');
    });

    test('does not run past the end of the text', () {
      expect(Mentions.parse('@ben').single.name, 'ben');
    });
  });

  group('addresses', () {
    test('matches regardless of case', () {
      expect(Mentions.addresses('hi @Sara', 'sara'), isTrue);
      expect(Mentions.addresses('hi @sara', 'SARA'), isTrue);
    });

    test('does not match a different name', () {
      expect(Mentions.addresses('hi @sarah', 'sara'), isFalse);
    });

    test('is false for an empty nickname', () {
      // A device with no name set must not light up for every bare @.
      expect(Mentions.addresses('hi @', ''), isFalse);
      expect(Mentions.addresses('hi @sara', ''), isFalse);
    });
  });

  group('activeQuery', () {
    test('reports what is being typed after an @', () {
      final query = Mentions.activeQuery('hey @sa', 7);

      expect(query!.query, 'sa');
      expect(query.start, 4);
    });

    test('is null when the cursor is not in a mention', () {
      expect(Mentions.activeQuery('hey there', 9), isNull);
      expect(Mentions.activeQuery('hey @sara there', 15), isNull);
    });

    test('offers everyone the moment @ is typed', () {
      expect(Mentions.activeQuery('hey @', 5)!.query, '');
    });

    test('does not fire on an email address', () {
      expect(Mentions.activeQuery('sara@exa', 8), isNull);
    });

    test('uses the cursor, not the end of the text', () {
      final query = Mentions.activeQuery('hey @sa and more', 7);

      expect(query!.query, 'sa');
    });
  });

  group('complete', () {
    test('replaces the partial name and leaves a trailing space', () {
      // The space matters: without it the next word runs into the name and the
      // mention silently stops matching.
      final result = Mentions.complete('hey @sa', 7, 'sara');

      expect(result.text, 'hey @sara ');
      expect(result.cursor, 10);
    });

    test('keeps whatever follows the cursor', () {
      final result = Mentions.complete('hey @sa and more', 7, 'sara');

      expect(result.text, 'hey @sara  and more');
    });
  });

  group('suggestions', () {
    const names = ['sara', 'Sam', 'ben'];

    test('offers everyone for an empty query', () {
      expect(Mentions.suggest(names, ''), names);
    });

    test('filters by prefix, ignoring case', () {
      expect(Mentions.suggest(names, 'sa'), ['sara', 'Sam']);
      expect(Mentions.suggest(names, 'S'), ['sara', 'Sam']);
    });

    test('returns nothing rather than everything when nothing matches', () {
      expect(Mentions.suggest(names, 'zz'), isEmpty);
    });

    test('drops duplicates, which a crowd will produce', () {
      expect(Mentions.suggest(['sara', 'sara'], 's'), ['sara']);
    });
  });
}
