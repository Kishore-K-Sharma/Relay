import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/event_log.dart';

void main() {
  var now = DateTime(2026, 7, 26, 14, 5, 9);

  EventLog build({int capacity = 200}) =>
      EventLog(capacity: capacity, clock: () => now);

  test('records what happened, in order', () {
    final log = build()
      ..info('radio started')
      ..warning('bluetooth turned off');

    expect(log.entries.map((e) => e.message), [
      'radio started',
      'bluetooth turned off',
    ]);
  });

  test('reads newest first, which is how anyone debugging reads it', () {
    final log = build()
      ..info('first')
      ..info('second');

    expect(log.newestFirst.first.message, 'second');
  });

  test('drops the oldest entries past capacity', () {
    final log = build(capacity: 3);
    for (var i = 0; i < 10; i++) {
      log.info('entry $i');
    }

    // Unbounded, this would grow for as long as the app runs and would hold a
    // full session's activity in memory.
    expect(log.entries, hasLength(3));
    expect(log.entries.first.message, 'entry 7');
  });

  test('notifies listeners so the screen updates live', () {
    final log = build();
    var notifications = 0;
    log.addListener(() => notifications++);

    log.info('something');

    expect(notifications, 1);
  });

  test('clearing empties it', () {
    final log = build()..info('something');

    log.clear();

    expect(log.isEmpty, isTrue);
  });

  test('renders as copyable text with times and levels', () {
    now = DateTime(2026, 7, 26, 9, 4, 3);
    final log = build()..error('gatt write failed');

    expect(log.asText(), '09:04:03  ERROR  gatt write failed');
  });

  test('exposes no way to send itself anywhere', () {
    // A tripwire for a product promise rather than a behaviour test. The log
    // is read, cleared, or rendered to text for the user to copy — nothing
    // else. If someone later adds an upload, they have to edit the list below
    // to get past this, and that is the moment to have the conversation.
    const forbidden = ['upload', 'send', 'report', 'submit', 'post', 'sync'];
    for (final name in forbidden) {
      expect(
        _eventLogApi.any((member) => member.toLowerCase().contains(name)),
        isFalse,
        reason: 'EventLog must not gain a "$name" member',
      );
    }
  });
}

/// The public members of [EventLog], listed by hand.
///
/// Dart has no runtime reflection outside `dart:mirrors`, which is unavailable
/// in Flutter. Listing them keeps the guard above honest: adding an upload
/// method means editing this list, which is the moment someone has to think
/// about what they are doing.
const _eventLogApi = [
  'capacity',
  'entries',
  'newestFirst',
  'isEmpty',
  'info',
  'warning',
  'error',
  'clear',
  'asText',
];
