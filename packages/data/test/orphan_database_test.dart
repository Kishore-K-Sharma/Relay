import 'dart:io';

import 'package:data/data.dart';
import 'package:test/test.dart';

/// A database file the app no longer opens is a database panic wipe cannot
/// reach.
///
/// `wipe()` erases the database this process has open. Anything else sitting in
/// the same directory — a file left behind by an older build under a name this
/// build has never heard of — survives untouched, with its message history in
/// it, while the app reports a successful wipe. That is the worst possible
/// combination: intact plaintext plus an assurance it is gone.
///
/// The guard is deliberately an allow-list rather than a list of old names. A
/// list of names has to be maintained by whoever renames a file next, which is
/// precisely the person who has already forgotten.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('orphan_db_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File touch(String name) =>
      File('${dir.path}/$name')
        ..writeAsStringSync('pretend this is a conversation');

  test('deletes a database this build does not own', () {
    final orphan = touch('older-build.db');

    LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'});

    expect(orphan.existsSync(), isFalse);
  });

  test('deletes the write-ahead log and shared-memory files with it', () {
    // The WAL is the whole point. Recent writes live there and not in the main
    // database, so deleting only the `.db` can leave the most recent
    // conversation — the one most worth protecting — perfectly readable.
    final wal = touch('older-build.db-wal');
    final shm = touch('older-build.db-shm');
    touch('older-build.db');

    LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'});

    expect(wal.existsSync(), isFalse);
    expect(shm.existsSync(), isFalse);
  });

  test('keeps the database this build does own, and its sidecars', () {
    final db = touch('relay.db');
    final wal = touch('relay.db-wal');
    final shm = touch('relay.db-shm');

    LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'});

    expect(db.existsSync(), isTrue);
    expect(wal.existsSync(), isTrue);
    expect(shm.existsSync(), isTrue);
  });

  test('leaves files that are not databases alone', () {
    // The application support directory is not ours alone. Deleting everything
    // unrecognised would be a wipe of somebody else's data, which is the same
    // class of bug in the other direction.
    final other = touch('cache.json');

    LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'});

    expect(other.existsSync(), isTrue);
  });

  test('does nothing when the directory does not exist', () {
    // First launch on a fresh install. Throwing here would take out startup
    // for every new user to protect data that cannot be there.
    expect(
      () => LocalStore.eraseForeignDatabases('${dir.path}/never', keep: {}),
      returnsNormally,
    );
  });

  test('is safe to run twice', () {
    touch('older-build.db');

    LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'});

    expect(
      () => LocalStore.eraseForeignDatabases(dir.path, keep: {'relay.db'}),
      returnsNormally,
    );
  });
}
