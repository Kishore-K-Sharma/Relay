import 'package:flutter/foundation.dart';

/// One `@name` found in a message body.
@immutable
class Mention {
  const Mention({required this.start, required this.end, required this.name});

  /// Index of the `@`.
  final int start;

  /// Index just past the last character of the name.
  final int end;

  /// The name as written, without the `@`.
  final String name;
}

/// Where a partly-typed mention begins and what has been typed of it.
@immutable
class MentionQuery {
  const MentionQuery({required this.start, required this.query});

  final int start;
  final String query;
}

/// The text and cursor after accepting a suggestion.
@immutable
class MentionCompletion {
  const MentionCompletion({required this.text, required this.cursor});

  final String text;
  final int cursor;
}

/// Naming one person inside a group.
///
/// A room can hold everyone in a building, and without a way to address a
/// single person in it either everybody reads everything or nobody reads
/// anything. This is pure text handling, deliberately: it decides nothing about
/// notifications or storage, so it can be tested exhaustively on its own.
///
/// A name is letters, digits, `_` or `-` — in any script. Restricting mentions
/// to the Latin alphabet would make the feature useless in most of the world,
/// and Relay's nicknames are UTF-8 everywhere else.
abstract final class Mentions {
  /// One character of a name, in any script.
  static final RegExp _nameChar = RegExp(r'[\p{L}\p{N}_-]', unicode: true);

  static bool _isNameChar(String text, int index) =>
      index >= 0 && index < text.length && _nameChar.hasMatch(text[index]);

  /// Every mention in [body], in the order they appear.
  static List<Mention> parse(String body) {
    final found = <Mention>[];

    for (var i = 0; i < body.length; i++) {
      if (body[i] != '@') continue;

      // The `@` must start a word. Without this every email address in a
      // message becomes a mention of somebody who does not exist.
      if (_isNameChar(body, i - 1)) continue;

      var end = i + 1;
      while (_isNameChar(body, end)) {
        end++;
      }
      if (end == i + 1) continue; // A bare `@`.

      found.add(Mention(start: i, end: end, name: body.substring(i + 1, end)));
      i = end - 1;
    }

    return found;
  }

  /// Whether [body] names [nickname].
  ///
  /// Case-insensitive, because people type names the way they remember them
  /// rather than the way they were registered. An empty nickname matches
  /// nothing: a device whose owner has not set a name must not light up for
  /// every stray `@`.
  static bool addresses(String body, String nickname) {
    if (nickname.isEmpty) return false;
    final wanted = nickname.toLowerCase();
    return parse(body).any((m) => m.name.toLowerCase() == wanted);
  }

  /// The mention being typed at [cursor], or null if the cursor is not in one.
  static MentionQuery? activeQuery(String text, int cursor) {
    if (cursor < 0 || cursor > text.length) return null;

    var start = cursor;
    while (_isNameChar(text, start - 1)) {
      start--;
    }

    final at = start - 1;
    if (at < 0 || text[at] != '@') return null;
    if (_isNameChar(text, at - 1)) return null;

    return MentionQuery(start: at, query: text.substring(at + 1, cursor));
  }

  /// Accepts [name] as the completion of whatever is being typed at [cursor].
  ///
  /// Leaves a trailing space. Without it the next word runs straight into the
  /// name and the mention silently stops matching — the kind of failure a user
  /// cannot see and cannot diagnose.
  static MentionCompletion complete(String text, int cursor, String name) {
    final query = activeQuery(text, cursor);
    if (query == null) return MentionCompletion(text: text, cursor: cursor);

    final replacement = '@$name ';
    return MentionCompletion(
      text: text.replaceRange(query.start, cursor, replacement),
      cursor: query.start + replacement.length,
    );
  }

  /// Names worth offering for [query], in the order given, without duplicates.
  ///
  /// Duplicates are not hypothetical: two people in a crowd choose the same
  /// nickname regularly, and nothing stops them.
  static List<String> suggest(Iterable<String> names, String query) {
    final wanted = query.toLowerCase();
    final seen = <String>{};
    return [
      for (final name in names)
        if (name.toLowerCase().startsWith(wanted) &&
            seen.add(name.toLowerCase()))
          name,
    ];
  }
}
