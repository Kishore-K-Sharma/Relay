import 'package:flutter/foundation.dart';

import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/domain/setup_step.dart';
import 'package:relay_app/src/domain/power_mode.dart';
import 'package:relay_app/src/domain/theme_choice.dart';

/// Everything the UI renders from, in one observable place.
///
/// Deliberately transport-agnostic: it holds view models, not frames. Wiring
/// this to the real `messaging` service is a matter of feeding it — nothing in
/// the widget tree changes.
class AppState extends ChangeNotifier {
  AppState({
    MeshStatus? status,
    List<Peer>? peers,
    List<Conversation>? conversations,
    this.nickname = 'you',
    this.powerMode = PowerMode.balanced,
    bool onboarded = false,
  }) : _status =
           status ??
           const MeshStatus(
             bluetoothOn: false,
             permissionsGranted: false,
             peersInRange: 0,
           ),
       _peers = peers ?? const [],
       _conversations = conversations ?? const [],
       _onboarded = onboarded;

  MeshStatus _status;
  List<Peer> _peers;
  List<Conversation> _conversations;
  bool _onboarded;

  String nickname;
  PowerMode powerMode;

  /// Renames this device's owner.
  ///
  /// A method rather than a bare assignment so the screens showing the name
  /// actually redraw; `/nick` was silently invisible without it.
  void setNickname(String value) {
    nickname = value;
    notifyListeners();
  }

  MeshStatus get status => _status;
  List<Peer> get peers => List.unmodifiable(_peers);
  List<Conversation> get conversations => List.unmodifiable(_conversations);
  bool get onboarded => _onboarded;

  /// Setup steps still outstanding, in the order they should be handled.
  ///
  /// The battery step is included even though it is technically optional,
  /// because on the affected manufacturers skipping it means the relay dies
  /// silently and the app appears broken.
  List<SetupStep> get outstandingSteps => [
    if (!_status.permissionsGranted) SetupStep.permissions,
    if (!_status.bluetoothOn) SetupStep.bluetoothOn,
    if (_needsBatteryExemption) SetupStep.battery,
  ];

  bool _needsBatteryExemption = false;

  set needsBatteryExemption(bool value) {
    if (_needsBatteryExemption == value) return;
    _needsBatteryExemption = value;
    notifyListeners();
  }

  void updateStatus(MeshStatus status) {
    _status = status;
    notifyListeners();
  }

  void updatePeers(List<Peer> peers) {
    _peers = peers;
    _status = _status.copyWith(
      peersInRange: peers.where((p) => p.isReachable).length,
    );
    notifyListeners();
  }

  void upsertConversation(Conversation conversation) {
    final index = _conversations.indexWhere((c) => c.id == conversation.id);
    final next = List<Conversation>.from(_conversations);
    if (index >= 0) {
      next[index] = conversation;
    } else {
      next.insert(0, conversation);
    }
    _conversations = next;
    notifyListeners();
  }

  Conversation? conversation(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  void appendMessage(String conversationId, Message message) {
    final existing = conversation(conversationId);
    if (existing == null) return;
    upsertConversation(
      Conversation(
        id: existing.id,
        title: existing.title,
        kind: existing.kind,
        peer: existing.peer,
        memberCount: existing.memberCount,
        unread: message.fromMe ? existing.unread : existing.unread + 1,
        messages: [...existing.messages, message],
      ),
    );
  }

  /// Replaces a message's state in place, so the UI reflects reality as acks
  /// arrive rather than freezing on whatever was true at send time.
  void updateMessageState(
    String conversationId,
    String messageId,
    MessageState state,
  ) {
    final existing = conversation(conversationId);
    if (existing == null) return;

    upsertConversation(
      Conversation(
        id: existing.id,
        title: existing.title,
        kind: existing.kind,
        peer: existing.peer,
        memberCount: existing.memberCount,
        unread: existing.unread,
        messages: [
          for (final m in existing.messages)
            if (m.id == messageId)
              Message(
                id: m.id,
                body: m.body,
                fromMe: m.fromMe,
                state: state,
                sentAt: m.sentAt,
                senderName: m.senderName,
                voiceDurationMs: m.voiceDurationMs,
              )
            else
              m,
        ],
      ),
    );
  }

  void setStealth(bool enabled) {
    _status = _status.copyWith(
      stealthMode: enabled,
      // Stealth mode disables the internet relay outright.
      relayAvailable: enabled ? false : _status.relayAvailable,
    );
    notifyListeners();
  }

  /// Whether the user wants the local-network transport used.
  ///
  /// On by default. It is the one transport whose traffic a third party — the
  /// network's owner — can see happening, so it is theirs to switch off.
  bool get wifiEnabled => _wifiEnabled;
  bool _wifiEnabled = true;

  set wifiEnabled(bool value) {
    if (_wifiEnabled == value) return;
    _wifiEnabled = value;
    notifyListeners();
  }

  /// Whether three quick taps on the title erase the phone.
  ///
  /// Off unless deliberately turned on. It fires with no confirmation, so a
  /// default of "on" would make an accidental gesture unrecoverable.
  bool get panicGestureEnabled => _panicGestureEnabled;
  bool _panicGestureEnabled = false;

  set panicGestureEnabled(bool value) {
    if (_panicGestureEnabled == value) return;
    _panicGestureEnabled = value;
    notifyListeners();
  }

  /// How the user wants the app to look. See [ThemeChoice] for the default.
  ThemeChoice get themeChoice => _themeChoice;
  ThemeChoice _themeChoice = ThemeChoice.dark;

  set themeChoice(ThemeChoice value) {
    if (_themeChoice == value) return;
    _themeChoice = value;
    notifyListeners();
  }

  void setPowerMode(PowerMode mode) {
    powerMode = mode;
    notifyListeners();
  }

  void completeOnboarding() {
    _onboarded = true;
    notifyListeners();
  }

  /// Panic wipe. Irreversible by design.
  void wipe() {
    _conversations = const [];
    _peers = const [];
    _onboarded = false;
    notifyListeners();
  }
}
