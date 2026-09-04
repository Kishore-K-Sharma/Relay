import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/runtime/event_log.dart';
import 'package:relay_app/src/app/bootstrap.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/ui/screens/diagnostics_screen.dart';
import 'package:relay_app/src/runtime/haptics.dart';
import 'package:relay_app/src/ui/screens/home_screen.dart';
import 'package:relay_app/src/ui/screens/join_room_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/screens/onboarding_screen.dart';
import 'package:relay_app/src/domain/pairing_payload.dart';
import 'package:relay_app/src/ui/screens/radar_screen.dart';
import 'package:relay_app/src/ui/responsive.dart';
import 'package:relay_app/src/runtime/runtime.dart';
import 'package:relay_app/src/ui/screens/scan_screen.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';
import 'package:relay_app/src/ui/theme.dart';
import 'package:relay_app/src/runtime/voice.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:transport_ble/transport_ble.dart';
import 'package:transport_wifi/transport_wifi.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppBoot());
}

/// Builds the stack, showing what it is doing while it does.
///
/// Bootstrapping touches the keystore and opens a database, both of which can
/// be slow on a cold start and both of which can fail. A blank screen with no
/// explanation is the worst possible outcome, so each state has a face.
class AppBoot extends StatefulWidget {
  const AppBoot({super.key});

  @override
  State<AppBoot> createState() => _AppBootState();
}

class _AppBootState extends State<AppBoot> {
  late Future<AppBootstrap> _future = AppBootstrap.create();

  void _retry() => setState(() => _future = AppBootstrap.create());

  @override
  Widget build(BuildContext context) => FutureBuilder<AppBootstrap>(
    future: _future,
    builder: (context, snapshot) {
      final boot = snapshot.data;
      // Listens to the state so changing the theme takes effect immediately
      // rather than at the next restart. Before the stack exists there is no
      // stored preference to honour, so the default stands.
      return AnimatedBuilder(
        animation: boot?.state ?? const AlwaysStoppedAnimation<double>(0),
        builder: (context, _) => MaterialApp(
          title: 'Relay',
          debugShowCheckedModeBanner: false,
          theme: appTheme(brightness: Brightness.light),
          darkTheme: appTheme(),
          themeMode: (boot?.state.themeChoice ?? ThemeChoice.dark).mode,
          // Wraps every screen, including anything pushed on top, so the text
          // clamp cannot be forgotten on a new route.
          builder: (context, child) => AppTextScale(child: child!),
          home: switch (snapshot) {
            AsyncSnapshot(hasError: true, :final error?) => _StartupFailure(
              error: error,
              onRetry: _retry,
            ),
            AsyncSnapshot(data: final ready?) => AppShell(boot: ready),
            _ => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
      );
    },
  );
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.danger),
            const SizedBox(height: 16),
            Text(
              'Relay could not start',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}

/// Owns navigation and connects every screen to the runtime.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.boot});

  final AppBootstrap boot;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _recorder = VoiceRecorder();
  final _player = VoicePlayer();

  /// The voice note currently playing, so its control can show it.
  String? _playingVoiceId;

  AppState get state => widget.boot.state;
  MeshRuntime get runtime => widget.boot.runtime;
  BleTransport get transport => widget.boot.transport;
  WifiTransport get wifi => widget.boot.wifi;

  @override
  void initState() {
    super.initState();
    state.addListener(_onChanged);
    // `/nick` changes the name in memory; without this it would be undone by
    // the next restart and the user would never be told why.
    runtime.onNicknameChanged = (name) async {
      await widget.boot.keyStore.saveNickname(name);
      // Native holds its own copy of the beacon and keeps broadcasting it with
      // no Dart alive, so a rename that is not pushed leaves the old name going
      // out on the air for as long as the app runs. The signature covers the
      // nickname, so a stale beacon is not merely wrong, it is unverifiable.
      await _pushPresence();
    };
    WidgetsBinding.instance.addObserver(this);
    if (state.onboarded) unawaitedStart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(_onChanged);
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // Coming back to the foreground is the moment to collect anything the
    // native relay stored while Dart was not running, and to retry whatever
    // could not go out earlier.
    if (lifecycle == AppLifecycleState.resumed && state.onboarded) {
      transport.drainInbox();
      transport.refresh();
      // Wi-Fi is the transport that genuinely dies when the app is
      // backgrounded: iOS closes the sockets and the mDNS registration goes
      // with them. Restarting on resume is what makes it come back at all.
      if (state.wifiEnabled) wifi.start();
      runtime.retryPending();
    }
  }

  void _onChanged() => setState(() {});

  /// Starts the radio, reporting any refusal rather than failing silently.
  void unawaitedStart() {
    () async {
      // Started first and separately. It needs no permission dialog and no
      // radio to be switched on, so a refused or disabled Bluetooth must not
      // take the local network down with it.
      if (state.wifiEnabled) await wifi.start();

      try {
        await transport.start();
        await _pushPresence();
        await runtime.announcePresence();
      } on BleNotReadyException catch (error) {
        await runtime.refreshStatus();
        _report(error.reason.message);
      }
    }();
  }

  /// Hands the presence beacon to native.
  ///
  /// Without this the device stops being discoverable the moment the app is
  /// closed: Dart's own announce dies with the isolate, and the native relay —
  /// which is the whole reason the mesh keeps working in the background — has
  /// nothing to broadcast. Stealth mode is expressed as an empty nickname,
  /// which native treats as "no beacon at all".
  ///
  /// The blob is the whole of the announce past the nickname — identity key,
  /// Noise key and the signature over both — built by Dart and appended by
  /// native verbatim. It used to be the identity key alone, which meant the
  /// beacon that actually runs, on its own timer, in the background, published
  /// no Noise key at all: mail could only ever be sealed to somebody whose
  /// Dart-side announce this device happened to catch, so couriering almost
  /// never worked. Native must be re-told whenever either part changes; see
  /// every call site of this method.
  Future<void> _pushPresence() async {
    if (state.status.stealthMode) {
      await transport.setAnnounce('', Uint8List(0));
      return;
    }
    final beacon = await runtime.presenceBeacon();
    await transport.setAnnounce(beacon.nickname, beacon.keyBlob);
  }

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------- onboarding

  Future<void> _resolveStep(SetupStep step) async {
    switch (step) {
      case SetupStep.permissions:
        final granted = await transport.requestPermissions();
        if (!granted) {
          _report(
            'Without Bluetooth permission Relay cannot find anyone. '
            'You can grant it later in Settings.',
          );
        }
        await transport.refresh();
      case SetupStep.bluetoothOn:
        await transport.requestEnableBluetooth();
        await transport.refresh();
      case SetupStep.battery:
        await transport.openBatterySettings();
        state.needsBatteryExemption = await transport.needsBatteryExemption();
      case SetupStep.identity:
        // Already created during bootstrap; the step exists so the user is
        // told an identity was generated rather than finding out later.
        break;
    }
  }

  Future<void> _finishOnboarding() async {
    await widget.boot.keyStore.markOnboarded();
    state.completeOnboarding();
    unawaitedStart();
  }

  // ---------------------------------------------------------------- actions

  /// The conversation shown in the second pane, on a window wide enough.
  ///
  /// Held here rather than on the navigator so it survives a rotation. A user
  /// who turns their tablet upright mid-sentence should still be in the same
  /// conversation, and a selection that lived only in a route stack would be
  /// destroyed by the layout change that made the route necessary.
  String? _selectedConversationId;

  /// The conversation currently pushed as its own screen, if any. Tracked so
  /// the reconcile below can tell "already showing" from "needs pushing".
  String? _pushedConversationId;

  Future<void> _openConversation(Conversation conversation) async {
    // Through the runtime, not straight to the store: opening a conversation
    // is also what sends the read receipt, and going round it would leave the
    // sender permanently on "delivered".
    await runtime.markConversationRead(conversation.id);
    if (!mounted) return;

    setState(() => _selectedConversationId = conversation.id);
    if (HomeScreen.opensByPushing(context)) await _pushConversation();
  }

  Future<void> _pushConversation() async {
    final id = _selectedConversationId;
    if (id == null || _pushedConversationId == id) return;
    _pushedConversationId = id;

    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => _conversationPane(id)));

    // The route is gone, by back button or by the reconcile popping it. Only
    // clear the selection in the first case: popping to hand the conversation
    // to the second pane must not also close it.
    _pushedConversationId = null;
    if (!mounted) return;
    if (HomeScreen.opensByPushing(context)) {
      setState(() => _selectedConversationId = null);
    }
  }

  /// Keeps the route stack and the layout agreeing after a resize.
  ///
  /// Called after every frame. Rotating a tablet upright has to push the open
  /// conversation, or the user loses their place; rotating it back has to pop
  /// it, or the conversation appears twice — once beside the list and once on
  /// top of it.
  void _reconcileLayout() {
    if (!mounted || _selectedConversationId == null) return;

    if (HomeScreen.opensByPushing(context)) {
      unawaited(_pushConversation());
    } else if (_pushedConversationId != null) {
      Navigator.of(context).pop();
    }
  }

  Widget _conversationPane(String id) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final current = state.conversation(id);
      if (current == null) return const SizedBox.shrink();
      return ConversationScreen(
        conversation: current,
        // Through the command runner, not straight to send. A line beginning
        // with a slash may be an instruction, and a mistyped one must never be
        // broadcast to the room.
        onSend: (body) => _runCommand(body, current.id),
        onRecordVoice: () => _recordVoice(current.id),
        onRetry: (_) => runtime.retryPending(),
        onSendByCourier: (message) => _sendByCourier(current.id, message),
        onBlock: () => _blockPeerIn(current),
        onLeave: () => _leaveRoom(current),
        onPlayVoice: _playVoice,
        playingMessageId: _playingVoiceId,
        onFavourite: () => _toggleFavouriteIn(current),
        mentionCandidates: runtime.mentionCandidatesFor(current.id),
        // No back button when it sits beside the list: there is nothing to go
        // back to, and an arrow that does nothing is worse than no arrow.
        showBackButton: HomeScreen.opensByPushing(context),
      );
    },
  );

  /// Runs a composer line, which may be a message or a command.
  Future<void> _runCommand(String body, String conversationId) async {
    final outcome = await runtime.runCommand(
      body,
      conversationId: conversationId,
    );
    if (!mounted) return;

    if (outcome.notice != null) _report(outcome.notice!);

    final opened = outcome.openConversation;
    if (opened != null && opened != conversationId) {
      final conversation = state.conversation(opened);
      if (conversation != null) await _openConversation(conversation);
    }
  }

  Future<void> _recordVoice(String conversationId) async {
    if (_recorder.isRecording) {
      final note = await _recorder.stop();
      if (note != null) await runtime.sendVoice(conversationId, note);
      return;
    }

    if (!await _recorder.start()) {
      _report('Relay needs microphone permission to record a voice note.');
      return;
    }
    _report('Recording. Tap the microphone again to send.');
  }

  /// Opens the conversation with a peer, or explains why it cannot yet.
  ///
  /// A peer the radio has seen but who has not announced has no mesh address,
  /// so there is nowhere to send. Saying so beats a tap that does nothing.
  Future<void> _openPeerConversation(Peer peer) async {
    final conversation = runtime.conversationForPeer(peer.id);
    if (conversation == null) {
      _report(
        '${peer.nickname} has not introduced themselves yet. '
        'Wait a moment and try again.',
      );
      return;
    }
    await _openConversation(conversation);
  }

  Future<void> _openRadar() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => RadarScreen(
          peers: state.peers,
          onTapPeer: (peer) {
            Navigator.of(context).pop();
            _openPeerConversation(peer);
          },
        ),
      ),
    ),
  );

  Future<void> _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => SettingsScreen(
          status: state.status,
          nickname: state.nickname,
          powerMode: state.powerMode,
          onPowerModeChanged: (mode) {
            runtime.setPowerMode(mode);
            transport.setPowerMode(mode.name);
          },
          onStealthChanged: (enabled) async {
            await runtime.setStealth(enabled);
            await transport.setStealthMode(enabled);
            // Native holds its own copy of the beacon and keeps broadcasting
            // it with no Dart alive, so it has to be told too.
            await _pushPresence();
          },
          wifiEnabled: state.wifiEnabled,
          onWifiChanged: _setWifiEnabled,
          blocked: [
            for (final entry in widget.boot.store.blocked())
              (nickname: entry.nickname, blockedAt: entry.blockedAt),
          ],
          onUnblock: (index) async {
            final entry = widget.boot.store.blocked()[index];
            await runtime.unblock(entry.publicKey);
            setState(() {});
          },
          onPanicWipe: _panicWipe,
          panicGestureEnabled: state.panicGestureEnabled,
          onPanicGestureChanged: _setPanicGestureEnabled,
          coverTrafficEnabled: runtime.coverTraffic.enabled,
          coverTrafficFramesPerHour: const CoverTrafficPolicy(
            enabled: true,
          ).extraFramesPerHour,
          onCoverTrafficChanged: _setCoverTraffic,
          onOpenDiagnostics: _openDiagnostics,
          themeChoice: state.themeChoice,
          onThemeChanged: _setThemeChoice,
          hapticsEnabled: Haptics.enabled,
          onHapticsChanged: _setHapticsEnabled,
          onCarryForOthersChanged: _setCarryForOthers,
          onDropCarriedMail: _dropCarriedMail,
        ),
      ),
    ),
  );

  /// Blocks whoever is on the other end of a direct conversation.
  ///
  /// Identified by the pinned identity key where there is one, and otherwise
  /// by the key the session established. Blocking by address hash would be
  /// wrong: it is 32 bits and truncated, so it can silence the wrong person.
  Future<void> _blockPeerIn(Conversation conversation) async {
    final key = runtime.identityKeyFor(conversation.id);
    if (key == null) {
      _report(
        'Relay does not know who this is yet, so it cannot block them. '
        'Wait until they have introduced themselves.',
      );
      return;
    }

    await runtime.block(key, nickname: conversation.title);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _report('${conversation.title} is blocked. You can undo this in Settings.');
  }

  /// Stars or unstars the person in a conversation.
  ///
  /// Keyed on the identity key for the same reason as blocking: an address hash
  /// is truncated, and unlocking the internet relay for the wrong person would
  /// leak their metadata to a third party.
  Future<void> _toggleFavouriteIn(Conversation conversation) async {
    final key = runtime.identityKeyFor(conversation.id);
    if (key == null) {
      _report(
        'Relay does not know who this is yet. Wait until they have '
        'introduced themselves.',
      );
      return;
    }

    final wasFavourite = conversation.peer?.isFavourite ?? false;
    if (wasFavourite) {
      await runtime.unfavourite(key);
    } else {
      await runtime.favourite(key, nickname: conversation.title);
    }
    if (!mounted) return;

    _report(
      wasFavourite
          ? '${conversation.title} is no longer a favourite. Messages will '
                'only go over Bluetooth and Wi-Fi.'
          : '${conversation.title} is a favourite. Messages can now also go '
                'over the internet when they are out of range.',
    );
  }

  /// Turns the local-network transport on or off, and remembers the choice.
  Future<void> _setWifiEnabled(bool enabled) async {
    state.wifiEnabled = enabled;
    await widget.boot.keyStore.saveWifiEnabled(enabled);
    if (enabled) {
      await wifi.start();
      await runtime.announcePresence();
    } else {
      await wifi.stop();
    }
    await runtime.refreshStatus();
  }

  Future<void> _openDiagnostics() async {
    var stats = BleRelayStats.empty;
    try {
      stats = await transport.stats();
    } catch (_) {
      // The service is not running. Zeroes plus the status banner already say
      // so, and an error dialog on a diagnostics screen helps nobody.
    }
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LiveDiagnostics(
          state: state,
          log: runtime.log,
          readStats: transport.stats,
          outboxDepth: () => widget.boot.store.outboxDepth,
          initial: stats,
        ),
      ),
    );
  }

  /// Turns traffic-pattern cover on or off.
  ///
  /// Not persisted across restarts on purpose, for now: it is a per-situation
  /// choice rather than a preference, and a user who turned it on once in a
  /// crowd should not silently keep paying for it every day afterwards.
  Future<void> _setCoverTraffic(bool enabled) async {
    setState(() => runtime.setCoverTraffic(enabled));
    _report(
      enabled
          ? 'Relay will pad your traffic. This uses more battery.'
          : 'Traffic padding is off.',
    );
  }

  /// Turns the three-tap emergency wipe on or off, and remembers the choice.
  Future<void> _setThemeChoice(ThemeChoice choice) async {
    state.themeChoice = choice;
    await widget.boot.keyStore.saveThemeChoice(choice);
  }

  Future<void> _setHapticsEnabled(bool enabled) async {
    Haptics.enabled = enabled;
    await widget.boot.keyStore.saveHapticsEnabled(enabled);
    if (mounted) setState(() {});
  }

  /// Plays a voice note, or stops the one already playing.
  ///
  /// Pressing the control while it is playing stops it. Without that the only
  /// way out of a long note is to wait, and a voice note is exactly the kind of
  /// thing somebody starts by accident in a room full of people.
  Future<void> _playVoice(Message message) async {
    if (_playingVoiceId == message.id) {
      await _player.stop();
      if (mounted) setState(() => _playingVoiceId = null);
      return;
    }

    final bytes = MeshRuntime.voiceBytesOf(message);
    if (bytes == null) {
      // Arrived malformed, or is not a voice note at all. Say so rather than
      // appearing to play silence.
      _report('This voice message did not arrive in one piece.');
      return;
    }

    setState(() => _playingVoiceId = message.id);
    try {
      await _player.play(message.id, bytes);
    } catch (_) {
      // A codec the platform will not open. One dead note, not a dead screen.
      if (mounted) _report('This phone could not play that voice message.');
    }
    if (mounted) setState(() => _playingVoiceId = null);
  }

  /// Gets out of a group.
  ///
  /// Routed through the command runner rather than calling `leaveRoom`
  /// directly, so the menu item and `/leave` cannot drift apart — one wording,
  /// one set of rules, one place to change them.
  Future<void> _leaveRoom(Conversation conversation) async {
    final outcome = await runtime.runCommand(
      '/leave',
      conversationId: conversation.id,
    );
    if (!mounted) return;
    if (outcome.notice != null) _report(outcome.notice!);
    // The conversation the user was looking at is gone, so nothing should
    // still be pointing at it.
    setState(() => _selectedConversationId = null);
    if (_pushedConversationId != null) Navigator.of(context).pop();
  }

  /// Asks people nearby to carry a message the radio has not got through.
  ///
  /// Adds to the ordinary outbox rather than replacing it: the retry loop keeps
  /// going, because a courier may take hours and the radio may succeed in the
  /// next second. Whichever arrives first, the recipient sees one message —
  /// both copies carry the same sequence number and the far end deduplicates.
  Future<void> _sendByCourier(String conversationId, Message message) async {
    final result = await runtime.sendByCourier(
      conversationId: conversationId,
      body: message.body,
    );
    if (!mounted) return;

    final refusal = result.refusal;
    _report(
      refusal != null
          ? refusal.explanation
          : 'Given to ${result.carriers} '
                '${result.carriers == 1 ? 'person' : 'people'} nearby to carry. '
                'It will be handed over if they meet them.',
    );
  }

  Future<void> _setCarryForOthers(bool enabled) async {
    await runtime.setCarryForOthers(enabled);
    await widget.boot.keyStore.saveCarryForOthers(enabled);
    if (!mounted) return;
    _report(
      enabled
          ? 'Your phone will hold sealed messages for people who are not here, '
                'and hand them over if you meet them.'
          : 'Your phone will not take on any new messages for other people. '
                'Anything it is already holding will still be delivered.',
    );
  }

  void _dropCarriedMail() {
    final dropped = runtime.dropCarriedMail();
    if (!mounted) return;
    _report(
      dropped == 0
          ? 'There was nothing to throw away.'
          : 'Threw away $dropped message${dropped == 1 ? '' : 's'} you were '
                'carrying. Nobody was told.',
    );
  }

  Future<void> _setPanicGestureEnabled(bool enabled) async {
    state.panicGestureEnabled = enabled;
    await widget.boot.keyStore.savePanicGestureEnabled(enabled);
    if (!mounted) return;
    _report(
      enabled
          ? 'Three quick taps on the title will now erase this phone, with no '
                'question asked.'
          : 'The three-tap wipe is off.',
    );
  }

  Future<void> _panicWipe() async {
    await transport.wipe();
    await transport.stop();
    // Every open link is a record of who this device was talking to, held by
    // the phone at the other end. Leaving them up after a wipe would keep the
    // device advertising an identity that no longer exists.
    await wifi.stop();
    await runtime.panicWipe();
    await widget.boot.keyStore.wipe();

    if (!mounted) return;
    // Everything the app knew is gone, including the identity. Continuing into
    // the normal UI would show a device that is no longer this device.
    Navigator.of(context).popUntil((route) => route.isFirst);
    _report('Everything on this phone has been erased.');
  }

  Future<void> _openPairing() async {
    final payload = runtime.pairingPayload();

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PairingScreen(
          myPublicKeyHex: payload.encode(),
          onScan: () => _scanAndVerify(context),
        ),
      ),
    );
  }

  Future<void> _scanAndVerify(BuildContext pairingContext) async {
    final scanned = await Navigator.of(pairingContext).push<PairingPayload>(
      MaterialPageRoute<PairingPayload>(builder: (_) => const ScanScreen()),
    );
    if (scanned == null || !pairingContext.mounted) return;

    final code = await runtime.safetyCodeWith(scanned.identityKey);
    if (!pairingContext.mounted) return;

    await Navigator.of(pairingContext).push(
      MaterialPageRoute<void>(
        builder: (_) => PairingScreen(
          myPublicKeyHex: runtime.pairingPayload().encode(),
          safetyCode: code.formatted,
          peerName: scanned.nickname,
          onConfirm: () async {
            await runtime.verifyContact(scanned);
            if (!pairingContext.mounted) return;
            Navigator.of(pairingContext).pop();
          },
        ),
      ),
    );
  }

  Future<void> _joinRoom() async {
    final navigator = Navigator.of(context);

    final code = await navigator.push<String>(
      MaterialPageRoute<String>(
        builder: (routeContext) => JoinRoomScreen(
          onJoin: (code) => Navigator.of(routeContext).pop(code.value),
        ),
      ),
    );
    if (code == null || !mounted) return;

    final room = await runtime.joinRoom(code);
    if (!mounted) return;

    final conversation = state.conversation(room.conversationId);
    if (conversation != null) await _openConversation(conversation);
  }

  @override
  Widget build(BuildContext context) {
    if (!state.onboarded) {
      return OnboardingScreen(
        outstanding: state.outstandingSteps,
        onResolve: _resolveStep,
        onFinish: _finishOnboarding,
      );
    }

    // Scheduled every frame rather than in didChangeMetrics: a resize can also
    // come from the window manager on desktop, and from a keyboard appearing,
    // neither of which is guaranteed to reach that callback.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcileLayout());

    final selected = _selectedConversationId;
    return HomeScreen(
      status: state.status,
      peers: state.peers,
      conversations: state.conversations,
      selectedConversationId: selected,
      // Built only when there are two panes, so a phone never pays to
      // construct a screen it cannot show.
      detail: selected == null || HomeScreen.opensByPushing(context)
          ? null
          : _conversationPane(selected),
      onOpenRadar: _openRadar,
      onOpenConversation: _openConversation,
      onOpenSettings: _openSettings,
      onJoinRoom: _joinRoom,
      onOpenPairing: _openPairing,
      onFixStatus: _fixProblem,
      onTapPeer: _openPeerConversation,
      panicGestureEnabled: state.panicGestureEnabled,
      // No confirmation, on purpose. See [PanicTapTarget].
      onPanicGesture: _panicWipe,
    );
  }

  Future<void> _fixProblem() async {
    if (!state.status.permissionsGranted) {
      return _resolveStep(SetupStep.permissions);
    }
    if (!state.status.bluetoothOn) {
      return _resolveStep(SetupStep.bluetoothOn);
    }
    await transport.refresh();
  }
}

/// Diagnostics that refresh while the screen is open.
class _LiveDiagnostics extends StatefulWidget {
  const _LiveDiagnostics({
    required this.state,
    required this.log,
    required this.readStats,
    required this.outboxDepth,
    required this.initial,
  });

  final AppState state;
  final EventLog log;
  final Future<BleRelayStats> Function() readStats;
  final int Function() outboxDepth;
  final BleRelayStats initial;

  @override
  State<_LiveDiagnostics> createState() => _LiveDiagnosticsState();
}

class _LiveDiagnosticsState extends State<_LiveDiagnostics> {
  late BleRelayStats _stats = widget.initial;

  Future<void> _refresh() async {
    try {
      final stats = await widget.readStats();
      if (mounted) setState(() => _stats = stats);
    } catch (_) {
      // Service not running; the banner already explains why.
    }
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: widget.log.asText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to this phone\'s clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // Both, so the screen updates as the mesh does rather than only on refresh.
    animation: Listenable.merge([widget.state, widget.log]),
    builder: (context, _) => DiagnosticsScreen(
      status: widget.state.status,
      stats: _stats,
      outboxDepth: widget.outboxDepth(),
      log: widget.log.newestFirst,
      onRefresh: _refresh,
      onCopyLog: widget.log.isEmpty ? null : _copyLog,
    ),
  );
}

/// Route builders, kept here so tests can push screens without the shell.
abstract final class AppRoutes {
  static Widget joinRoom() => const JoinRoomScreen();

  static Widget settings(AppState state) => SettingsScreen(
    status: state.status,
    nickname: state.nickname,
    powerMode: state.powerMode,
    onPowerModeChanged: state.setPowerMode,
    onStealthChanged: state.setStealth,
    onPanicWipe: state.wipe,
  );

  static Widget conversation(Conversation conversation) =>
      ConversationScreen(conversation: conversation);
}
