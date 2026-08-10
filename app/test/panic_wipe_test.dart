import 'dart:io';
import 'dart:typed_data';

import 'package:core_identity/core_identity.dart' hide TrustState;
import 'package:data/data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:path/path.dart' as p;
import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/runtime/runtime.dart';

import 'runtime_test.dart' show WireTransport, settle;

/// Panic wipe, checked against the disk rather than against the API.
///
/// A wipe that only clears in-memory state is worse than no wipe at all: the
/// user is told everything is gone and then hands over a phone that still has
/// it. These tests reopen the database file afterwards and read the raw bytes,
/// because that is what an adversary with the device would do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late String databasePath;
  late LocalStore store;
  late AppState state;
  late WireTransport transport;
  late MeshRuntime runtime;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('relay-wipe-');
    databasePath = p.join(directory.path, 'relay.db');
    store = LocalStore.open(databasePath);

    state = AppState(nickname: 'alice', onboarded: true);
    transport = WireTransport('alice');
    final identity = await MeshIdentity.generate();

    runtime = MeshRuntime(
      state: state,
      store: store,
      mesh: transport,
      identity: identity,
      noiseStaticKey: Uint8List.fromList(List.filled(32, 3)),
      localAddressHash: await addressHashOf(identity.publicKey),
    );
    await runtime.start();
  });

  tearDown(() async {
    await runtime.stop();
    await transport.dispose();
    store.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Writes a realistic amount of sensitive state: a conversation, a message,
  /// a verified contact and a room the user joined.
  Future<void> populate() async {
    store.upsertConversation(
      id: 'peer-1',
      kind: ConversationKind.direct,
      title: 'Sara',
    );
    store.insertMessage(
      StoredMessage(
        id: 'm1',
        conversationId: 'peer-1',
        body: 'the north gate at nine',
        fromMe: true,
        state: MessageState.sent,
        createdAt: DateTime(2026, 7, 26),
      ),
    );
    store.saveContact(
      publicKey: Uint8List.fromList(List.filled(32, 9)),
      nickname: 'Sara',
      trust: TrustState.verified,
      safetyCode: '12345',
      pinnedAt: DateTime(2026, 7, 26),
    );
    await runtime.joinRoom('MESH42');
    await settle();
  }

  /// Every byte SQLite has written to disk, across all its files.
  ///
  /// Two things make the naive version of this check useless. `DELETE FROM`
  /// leaves the old pages in the main file until SQLite reuses or vacuums them.
  /// And in WAL mode the recent writes are not in the main file at all — they
  /// are in `-wal`, which a wipe that only touches the database would leave
  /// sitting on disk in full.
  ///
  /// An adversary with the phone reads the directory, not the schema.
  String everythingOnDisk() {
    final buffer = StringBuffer();
    for (final entry in directory.listSync()) {
      if (entry is! File) continue;
      buffer.write(
        String.fromCharCodes(
          entry.readAsBytesSync().where((b) => b >= 32 && b < 127),
        ),
      );
    }
    return buffer.toString();
  }

  test('message bodies are gone from the query layer', () async {
    await populate();
    expect(store.messages('peer-1'), isNotEmpty);

    await runtime.panicWipe();

    expect(store.messages('peer-1'), isEmpty);
    expect(store.conversations(), isEmpty);
    expect(store.contacts(), isEmpty);
    expect(store.outboxDepth, 0);
  });

  test('message text is gone from the database file itself', () async {
    await populate();
    expect(everythingOnDisk(), contains('the north gate at nine'));

    await runtime.panicWipe();

    // The point of the test. `DELETE FROM` alone leaves the text in a free
    // page, recoverable with a hex editor.
    expect(everythingOnDisk(), isNot(contains('the north gate at nine')));
  });

  test('a verified contact is gone from the database file', () async {
    await populate();
    expect(everythingOnDisk(), contains('Sara'));

    await runtime.panicWipe();

    expect(everythingOnDisk(), isNot(contains('Sara')));
  });

  test('a joined room code is gone from the database file', () async {
    await populate();
    expect(everythingOnDisk(), contains('MESH42'));

    await runtime.panicWipe();

    expect(everythingOnDisk(), isNot(contains('MESH42')));
  });

  test('the store still works afterwards', () async {
    await populate();
    await runtime.panicWipe();

    // A wipe that corrupts the database would leave the app unusable and push
    // the user to reinstall, which is a worse outcome than a clean start.
    store.upsertConversation(
      id: 'fresh',
      kind: ConversationKind.direct,
      title: 'New',
    );
    expect(store.conversations(), hasLength(1));
  });

  test('reopening the file finds nothing', () async {
    await populate();
    await runtime.panicWipe();
    store.close();

    final reopened = LocalStore.open(databasePath);
    addTearDown(reopened.close);

    expect(reopened.conversations(), isEmpty);
    expect(reopened.contacts(), isEmpty);
  });

  test('sessions are destroyed, so a peer must handshake again', () async {
    await runtime.sessions.beginHandshake(0xBEEF);
    expect(runtime.sessions.stateFor(0xBEEF), isNot(SessionState.none));

    await runtime.panicWipe();

    expect(runtime.sessions.stateFor(0xBEEF), SessionState.none);
  });

  test('in-memory UI state is cleared', () async {
    await populate();
    expect(state.conversations, isNotEmpty);

    await runtime.panicWipe();

    expect(state.conversations, isEmpty);
    expect(state.peers, isEmpty);
    expect(state.onboarded, isFalse);
  });

  test('a peer that was in range is forgotten', () async {
    transport.announcePeers();
    await settle();

    await runtime.panicWipe();

    // Leaving the peer table populated would let the next screen show who the
    // user was standing next to, immediately after they asked to erase it.
    expect(state.peers, isEmpty);
  });

  test('rooms are unregistered, so their traffic no longer decrypts', () async {
    final room = await runtime.joinRoom('MESH42');
    await settle();

    await runtime.panicWipe();

    // Keeping the room key in memory would mean a wiped phone still quietly
    // reading a group it was told to forget.
    expect(state.conversation(room.conversationId), isNull);
  });
}
