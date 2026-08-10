import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_identity/core_identity.dart';
import 'package:data/data.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:transport_ble/transport_ble.dart';
import 'package:transport_wifi/transport_wifi.dart';

import 'package:relay_app/src/runtime/haptics.dart';
import 'package:relay_app/src/ui/theme.dart';

import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/runtime/runtime.dart';

/// This device's long-lived secrets.
///
/// Two separate keys, deliberately. The Ed25519 identity is what a contact
/// pins and what a safety code is computed over; the X25519 static key is what
/// Noise uses. Reusing one key for both signing and Diffie-Hellman is a
/// well-known way to weaken both.
class DeviceKeys {
  const DeviceKeys({
    required this.identity,
    required this.noiseStaticKey,
    required this.addressHash,
    required this.nickname,
    required this.onboarded,
    required this.wifiEnabled,
    required this.panicGestureEnabled,
    required this.themeChoice,
    required this.hapticsEnabled,
    required this.carryForOthers,
  });

  final MeshIdentity identity;
  final Uint8List noiseStaticKey;
  final int addressHash;
  final String nickname;
  final bool onboarded;

  /// Whether the user has left the local-network transport switched on.
  final bool wifiEnabled;

  /// Whether three quick taps on the title erase the phone. Off unless the
  /// user has deliberately turned it on.
  final bool panicGestureEnabled;

  /// How the user wants the app to look. Dark unless they changed it.
  final ThemeChoice themeChoice;

  /// Whether the phone buzzes. On unless the user switched it off.
  final bool hapticsEnabled;

  /// Whether this device holds sealed mail for people who are not here. On
  /// unless the user switched it off.
  final bool carryForOthers;
}

/// Loads or creates the device's keys.
///
/// Kept in the platform keystore — Keychain on iOS, EncryptedSharedPreferences
/// on Android — rather than in the database, so that a stolen database file is
/// not a stolen identity.
class KeyStore {
  KeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _identitySeedKey = 'relay.identity.seed.v1';
  static const _noiseKeyKey = 'relay.noise.static.v1';
  static const _nicknameKey = 'relay.nickname.v1';
  static const _onboardedKey = 'relay.onboarded.v1';
  static const _wifiKey = 'relay.wifi.enabled.v1';
  static const _panicGestureKey = 'relay.panic.gesture.v1';
  static const _themeKey = 'relay.theme.v1';
  static const _hapticsKey = 'relay.haptics.v1';
  static const _carryKey = 'relay.couriers.carry.v1';

  final FlutterSecureStorage _storage;

  Future<DeviceKeys> load() async {
    final identitySeed = await _readOrCreate(_identitySeedKey);
    final noiseKey = await _readOrCreate(_noiseKeyKey);

    final identity = await MeshIdentity.fromSeed(identitySeed);
    final storedTheme = await _storage.read(key: _themeKey);

    return DeviceKeys(
      identity: identity,
      noiseStaticKey: noiseKey,
      addressHash: await addressHashOf(identity.publicKey),
      nickname: await _storage.read(key: _nicknameKey) ?? '',
      onboarded: await _storage.read(key: _onboardedKey) == 'true',
      // Absent means never touched, and the default is on.
      wifiEnabled: await _storage.read(key: _wifiKey) != 'false',
      // Absent means off. An emergency wipe that fires without confirmation
      // must never be on by accident.
      panicGestureEnabled: await _storage.read(key: _panicGestureKey) == 'true',
      // Dark unless the user said otherwise, including when the stored value
      // is from a build that did not have this setting.
      themeChoice: ThemeChoice.values.firstWhere(
        (choice) => choice.name == storedTheme,
        orElse: () => ThemeChoice.dark,
      ),
      // Absent means never touched, and the default is on.
      hapticsEnabled: await _storage.read(key: _hapticsKey) != 'false',
      // Absent means never touched, and the default is on: a mesh where
      // everybody opts out of carrying delivers nothing to anybody absent.
      carryForOthers: await _storage.read(key: _carryKey) != 'false',
    );
  }

  Future<void> saveCarryForOthers(bool enabled) =>
      _storage.write(key: _carryKey, value: enabled ? 'true' : 'false');

  Future<void> saveWifiEnabled(bool enabled) =>
      _storage.write(key: _wifiKey, value: enabled ? 'true' : 'false');

  Future<void> savePanicGestureEnabled(bool enabled) =>
      _storage.write(key: _panicGestureKey, value: enabled ? 'true' : 'false');

  Future<void> saveThemeChoice(ThemeChoice choice) =>
      _storage.write(key: _themeKey, value: choice.name);

  Future<void> saveHapticsEnabled(bool enabled) =>
      _storage.write(key: _hapticsKey, value: enabled ? 'true' : 'false');

  Future<void> saveNickname(String nickname) =>
      _storage.write(key: _nicknameKey, value: nickname);

  Future<void> markOnboarded() =>
      _storage.write(key: _onboardedKey, value: 'true');

  /// Destroys the identity. Part of panic wipe; contacts must verify again
  /// from scratch afterwards, which is the point.
  Future<void> wipe() => _storage.deleteAll();

  Future<Uint8List> _readOrCreate(String key) async {
    final existing = await _storage.read(key: key);
    if (existing != null) {
      final decoded = base64Decode(existing);
      if (decoded.length == 32) return Uint8List.fromList(decoded);
    }

    final random = Random.secure();
    final fresh = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _storage.write(key: key, value: base64Encode(fresh));
    return fresh;
  }
}

/// Everything the app needs, built and connected.
class AppBootstrap {
  const AppBootstrap({
    required this.state,
    required this.runtime,
    required this.transport,
    required this.wifi,
    required this.keys,
    required this.keyStore,
    required this.store,
  });

  final AppState state;
  final MeshRuntime runtime;
  final BleTransport transport;

  /// The local-network transport. Always constructed; started only where a
  /// usable network exists and the user has left it switched on.
  final WifiTransport wifi;

  final DeviceKeys keys;
  final KeyStore keyStore;
  final LocalStore store;

  /// Builds the whole stack.
  ///
  /// Does not start the radio: that needs permissions the user has not
  /// necessarily granted yet, and calling into the platform without them makes
  /// Android throw on a background thread, which reaches the user as the app
  /// dying for no visible reason.
  static Future<AppBootstrap> create() async {
    final keyStore = KeyStore();
    final keys = await keyStore.load();

    final directory = await getApplicationSupportDirectory();

    // Before the store is opened, so an orphan left by an earlier build never
    // survives a single launch. Panic wipe only erases the database this
    // process has open; anything under a name this build does not know would
    // sit there with its history intact while the app reports a clean wipe.
    LocalStore.eraseForeignDatabases(directory.path, keep: const {'relay.db'});

    final store = LocalStore.open(p.join(directory.path, 'relay.db'));

    final state = AppState(
      nickname: keys.nickname.isEmpty ? 'Someone' : keys.nickname,
      onboarded: keys.onboarded,
    );

    state.wifiEnabled = keys.wifiEnabled;
    state.panicGestureEnabled = keys.panicGestureEnabled;
    state.themeChoice = keys.themeChoice;
    Haptics.enabled = keys.hapticsEnabled;

    final transport = BleTransport(addressHash: keys.addressHash);

    final discovery = PlatformLanDiscovery();
    await discovery.refresh();
    final wifi = WifiTransport(
      addressHash: keys.addressHash,
      discovery: discovery,
    );

    final runtime = MeshRuntime(
      state: state,
      store: store,
      mesh: transport,
      wifi: wifi,
      identity: keys.identity,
      noiseStaticKey: keys.noiseStaticKey,
      localAddressHash: keys.addressHash,
    );
    // Before start(), so the first announce this device answers already
    // respects the user's choice. Applied after construction rather than
    // through the constructor because it is a preference, not a dependency.
    await runtime.setCarryForOthers(keys.carryForOthers);
    await runtime.start();

    state.needsBatteryExemption = await transport
        .needsBatteryExemption()
        .catchError((_) => false);

    return AppBootstrap(
      state: state,
      runtime: runtime,
      transport: transport,
      wifi: wifi,
      keys: keys,
      keyStore: keyStore,
      store: store,
    );
  }
}
