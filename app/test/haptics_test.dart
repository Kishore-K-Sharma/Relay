import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/haptics.dart';

/// Feedback the user feels rather than reads.
///
/// A mesh app is used with the phone in a pocket, in a crowd, at night. A
/// buzz is often the only signal that gets through — and for the same reason,
/// one at the wrong moment is worse here than in an ordinary app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  List<String> types() => [
    for (final call in calls)
      if (call.method == 'HapticFeedback.vibrate')
        '${call.arguments ?? 'heavy'}',
  ];

  test('sending is a light tap', () async {
    await Haptics.sent();

    expect(types(), isNotEmpty);
  });

  test('a delivery confirmation is distinct from a send', () async {
    await Haptics.sent();
    final afterSend = List<String>.from(types());
    calls.clear();

    await Haptics.delivered();

    expect(types(), isNot(afterSend));
  });

  test('a failure is heavier than a success', () async {
    // The user needs to be able to tell, without looking, that something did
    // not go out. That is the whole point of the distinction.
    await Haptics.failed();
    final failure = List<String>.from(types());
    calls.clear();

    await Haptics.sent();

    expect(failure, isNot(types()));
  });

  test('being named is felt', () async {
    // In a busy room a mention is the message the user must not miss.
    await Haptics.mentioned();

    expect(types(), isNotEmpty);
  });

  group('when it is switched off', () {
    setUp(() => Haptics.enabled = false);
    tearDown(() => Haptics.enabled = true);

    test('nothing is sent to the platform', () async {
      // Everything except the wipe, which is exempt — see below.
      await Haptics.sent();
      await Haptics.delivered();
      await Haptics.failed();
      await Haptics.mentioned();

      expect(calls, isEmpty);
    });
  });

  test('the emergency wipe is felt even when haptics are off', () async {
    // The one exception. A wipe is irreversible and silent, and the buzz is
    // the only confirmation the user gets that three taps registered rather
    // than two. Suppressing it would leave somebody unsure whether the thing
    // they just did happened.
    Haptics.enabled = false;
    addTearDown(() => Haptics.enabled = true);

    await Haptics.panic();

    expect(calls, isNotEmpty);
  });

  test('a failure to buzz is never a failure to send', () async {
    // Some devices have no vibrator, and some throw. A message must not be
    // held up, or lost, because the phone could not rumble.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => throw PlatformException(code: 'no vibrator'),
        );

    await expectLater(Haptics.sent(), completes);
  });
}
