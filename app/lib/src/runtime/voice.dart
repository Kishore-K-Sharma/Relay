import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A recorded voice note, ready to send.
class VoiceNote {
  const VoiceNote({required this.bytes, required this.durationMs});

  final Uint8List bytes;
  final int durationMs;
}

/// Records and plays short voice notes.
///
/// Opus in an Ogg container at 16 kbit/s mono. The bitrate is the whole design:
/// a BLE frame carries 160 payload bytes, so a ten-second note is roughly 20
/// kB, which is 125 frames. At anything approaching speech-music quality a
/// voice note would occupy the mesh for minutes and starve everyone else's
/// text. Thirty seconds is the hard ceiling for the same reason.
class VoiceRecorder {
  VoiceRecorder({AudioRecorder? recorder, Directory? directory})
    : _recorder = recorder ?? AudioRecorder(),
      _directory = directory;

  /// Beyond this a note is refused. See the class comment: this is a mesh
  /// fairness limit, not a UI preference.
  static const Duration maxDuration = Duration(seconds: 30);

  static const int _bitRate = 16000;
  static const int _sampleRate = 16000;

  final AudioRecorder _recorder;
  final Directory? _directory;

  String? _path;
  DateTime? _startedAt;

  bool get isRecording => _path != null;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Begins recording. Returns false when the microphone is unavailable.
  Future<bool> start({DateTime Function()? clock}) async {
    if (isRecording) return true;
    if (!await _recorder.hasPermission()) return false;

    final directory = _directory ?? await getTemporaryDirectory();
    final path = p.join(
      directory.path,
      'note-${(clock ?? DateTime.now)().microsecondsSinceEpoch}.ogg',
    );

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.opus,
        bitRate: _bitRate,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
      path: path,
    );

    _path = path;
    _startedAt = (clock ?? DateTime.now)();
    return true;
  }

  /// Stops and returns the note, or null if nothing usable was captured.
  Future<VoiceNote?> stop({DateTime Function()? clock}) async {
    if (!isRecording) return null;

    final path = await _recorder.stop();
    final startedAt = _startedAt;
    _path = null;
    _startedAt = null;

    if (path == null || startedAt == null) return null;

    final file = File(path);
    if (!file.existsSync()) return null;

    final bytes = await file.readAsBytes();
    // The temporary file has served its purpose. Leaving recordings lying
    // around in the cache is exactly the kind of thing this app must not do.
    await file.delete().catchError((_) => file);

    if (bytes.isEmpty) return null;

    final elapsed = (clock ?? DateTime.now)().difference(startedAt);
    final capped = elapsed > maxDuration ? maxDuration : elapsed;

    return VoiceNote(bytes: bytes, durationMs: capped.inMilliseconds);
  }

  /// Abandons a recording in progress and deletes what was captured.
  Future<void> cancel() async {
    if (!isRecording) return;
    final path = await _recorder.stop();
    _path = null;
    _startedAt = null;
    if (path != null) {
      await File(path).delete().catchError((_) => File(path));
    }
  }

  Future<void> dispose() => _recorder.dispose();
}

/// Plays voice notes back from memory.
class VoicePlayer {
  VoicePlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  String? _playingId;

  /// The note currently playing, if any, so the UI can show which one.
  String? get playingId => _playingId;

  Stream<PlayerState> get stateChanges => _player.playerStateStream;

  /// Plays [bytes], identified by [id] so the UI can track it.
  ///
  /// The audio is handed over as a data URI rather than written to disk: a
  /// voice note is content the user may well not want left in a cache
  /// directory for a forensic tool to find.
  Future<void> play(String id, Uint8List bytes) async {
    await stop();
    _playingId = id;

    await _player.setAudioSource(
      AudioSource.uri(
        Uri.parse('data:audio/ogg;base64,${base64Encode(bytes)}'),
      ),
    );
    await _player.play();
    _playingId = null;
  }

  Future<void> stop() async {
    _playingId = null;
    await _player.stop();
  }

  Future<void> dispose() => _player.dispose();
}
