import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'link_codec.dart';

/// One TCP connection to one peer on the local network.
///
/// Owns exactly two things: the framing, and the socket's lifetime. It knows
/// nothing about discovery, nothing about the mesh, and nothing about what a
/// frame contains. Everything it can be told by the far end is treated as
/// hostile until it parses.
class LanLink {
  LanLink(
    this._socket, {
    required int localAddressHash,
    required this.dialedByUs,
  }) {
    // Frames are small and latency matters more than packing: without this,
    // Nagle holds a message back waiting for a second one that is not coming.
    _socket.setOption(SocketOption.tcpNoDelay, true);

    _subscription = _socket.listen(
      _onData,
      // Any socket error is the end of this link. There is no partial
      // recovery worth attempting on a stream whose position we have lost.
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
      cancelOnError: true,
    );

    // A write that fails does not surface on the read subscription; it is
    // delivered to `done`. Unwatched, a peer resetting the connection while a
    // frame is in flight becomes an unhandled asynchronous error that crashes
    // the zone rather than closing one link — and a peer resetting mid-write
    // is completely ordinary.
    unawaited(
      _socket.done.then((_) => close(), onError: (Object _) => close()),
    );

    _write(LinkCodec.encodeHello(localAddressHash));
  }

  final Socket _socket;

  /// True when this device opened the connection.
  ///
  /// Two devices discovering each other simultaneously both dial, which leaves
  /// two connections where one is wanted. The tie-break needs to know which
  /// side each connection came from, and both ends must agree — so it is
  /// recorded here rather than inferred later.
  final bool dialedByUs;

  final _reader = LinkReader();
  final _frames = StreamController<Uint8List>.broadcast();
  final _ready = Completer<int>();
  final _done = Completer<void>();

  late final StreamSubscription<Uint8List> _subscription;

  int? _peerHash;
  bool _closed = false;

  /// The far end's mesh address, once it has introduced itself.
  int? get peerHash => _peerHash;

  /// Completes when the peer's hello arrives.
  ///
  /// Never completes if it does not. That is deliberate: a caller should time
  /// this out and drop the link rather than be handed a link with no identity.
  Future<int> get ready => _ready.future;

  /// Whole mesh frames, in arrival order. Closes when the link does.
  Stream<Uint8List> get frames => _frames.stream;

  /// Completes when the link is finished, however it finished.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  String get remoteAddress => _socket.remoteAddress.address;

  int get remotePort => _socket.remotePort;

  /// Queues a frame. Silently does nothing once the link is closed.
  ///
  /// Throws [LinkProtocolException] only for a frame this protocol cannot
  /// carry, which is a bug in the caller rather than a network condition.
  void send(Uint8List frame) {
    final encoded = LinkCodec.encodeFrame(frame);
    if (_closed) return;
    _write(encoded);
  }

  void _write(Uint8List bytes) {
    try {
      _socket.add(bytes);
    } on Object {
      // The peer went away between the check and the write. Ordinary.
      unawaited(close());
    }
  }

  void _onData(Uint8List chunk) {
    final Iterable<LinkMessage> messages;
    try {
      messages = _reader.offer(chunk).toList();
    } on LinkProtocolException {
      unawaited(close());
      return;
    }

    for (final message in messages) {
      switch (message) {
        case HelloMessage(:final addressHash):
          if (!_ready.isCompleted) {
            _peerHash = addressHash;
            _ready.complete(addressHash);
          }
        case FrameMessage(:final bytes):
          if (!_frames.isClosed) _frames.add(bytes);
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _subscription.cancel();
    try {
      await _socket.close();
    } on Object {
      // Already gone, in any of the several ways a socket can be already gone.
    }
    _socket.destroy();

    if (!_frames.isClosed) await _frames.close();
    if (!_done.isCompleted) _done.complete();
  }
}
