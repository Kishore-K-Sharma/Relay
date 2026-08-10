/// The Bluetooth LE mesh transport.
///
/// Owns the single platform channel to the native radio layer. Nothing above
/// this package knows a platform channel exists; nothing below it knows what a
/// frame means.
library;

export 'src/ble_transport.dart';
export 'src/generated/ble_api.g.dart' show PeerInfo;
