import 'package:flutter/services.dart';

/// Feedback the user feels rather than reads.
///
/// This app is used with the phone in a pocket, in a crowd, at night, and often
/// while looking at something other than the screen. A buzz is frequently the
/// only signal that arrives — which is also why the vocabulary here is small
/// and each entry means one thing. A phone that buzzes at everything is one
/// people switch to silent, and then the mesh has no way to reach them at all.
abstract final class Haptics {
  /// Whether the user wants to feel anything.
  ///
  /// Mutable rather than passed around: every call site is a leaf, and
  /// threading a preference through the message layer to reach a vibration
  /// would put a UI concern in the transport.
  static bool enabled = true;

  /// A message left this device.
  static Future<void> sent() => _fire(HapticFeedback.selectionClick);

  /// A message was confirmed on somebody else's device.
  ///
  /// Deliberately different from [sent]. In a mesh those two are genuinely
  /// different events, often minutes apart, and the app's central promise is
  /// not to blur them.
  static Future<void> delivered() => _fire(HapticFeedback.lightImpact);

  /// A message could not be sent, or gave up.
  ///
  /// Heavier, so the user can tell without looking that something did not go.
  static Future<void> failed() => _fire(HapticFeedback.heavyImpact);

  /// Somebody wrote the user's name.
  static Future<void> mentioned() => _fire(HapticFeedback.mediumImpact);

  /// The emergency wipe fired.
  ///
  /// The one thing that buzzes even when haptics are switched off. A wipe is
  /// irreversible and otherwise silent, and this is the only confirmation the
  /// user gets that three taps registered rather than two — leaving somebody
  /// unsure whether their phone has just been erased is not an option.
  static Future<void> panic() => _fire(HapticFeedback.heavyImpact, force: true);

  static Future<void> _fire(
    Future<void> Function() feedback, {
    bool force = false,
  }) async {
    if (!enabled && !force) return;
    try {
      await feedback();
    } catch (_) {
      // Some devices have no vibrator and some throw. A message must never be
      // delayed, or lost, because the phone could not rumble.
    }
  }
}
