import 'package:flutter/foundation.dart';

enum LogLevel { info, warning, error }

@immutable
class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.message,
  });

  final DateTime at;
  final LogLevel level;
  final String message;

  String get timestamp =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  @override
  String toString() => '$timestamp  ${level.name.toUpperCase()}  $message';
}

/// A short, in-memory record of what the mesh has been doing.
///
/// **Nothing here is ever sent anywhere.** There is no crash reporter, no
/// analytics, and no upload path — for an app whose users may be in a crowd
/// they would rather not be identified in, a background process quietly posting
/// diagnostics to a server would undo the point of the whole product. The log
/// exists so a user can see why the app is misbehaving and, if they choose,
/// read it out or copy it themselves.
///
/// In memory only, and bounded. Writing it to disk would create exactly the
/// kind of durable record that panic wipe exists to prevent, and it would
/// outlive the session that produced it.
class EventLog extends ChangeNotifier {
  EventLog({this.capacity = 200, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Older entries are dropped past this. Small on purpose: the log answers
  /// "what just went wrong", not "what happened all day".
  final int capacity;

  final DateTime Function() _clock;
  final _entries = <LogEntry>[];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Newest first, which is the order someone debugging actually reads in.
  List<LogEntry> get newestFirst => _entries.reversed.toList(growable: false);

  bool get isEmpty => _entries.isEmpty;

  void info(String message) => _add(LogLevel.info, message);
  void warning(String message) => _add(LogLevel.warning, message);
  void error(String message) => _add(LogLevel.error, message);

  void _add(LogLevel level, String message) {
    _entries.add(LogEntry(at: _clock(), level: level, message: message));
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// The whole log as text, for the user to copy if they want to.
  ///
  /// Copying is the user's decision and their clipboard. The app never does it
  /// on their behalf and never sends it.
  String asText() => _entries.map((e) => e.toString()).join('\n');
}
