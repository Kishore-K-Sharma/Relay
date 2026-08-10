/// The boundary every transport implements.
///
/// A transport moves opaque frames between devices. It never inspects, decrypts
/// or interprets frame contents — that separation is what lets BLE, the internet
/// relay, and the in-memory simulator be swapped freely.
library;

export 'src/composite_transport.dart';
export 'src/transport.dart';
