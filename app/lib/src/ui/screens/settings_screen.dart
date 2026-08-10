import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/domain/power_mode.dart';
import 'package:relay_app/src/ui/responsive.dart';
import 'package:relay_app/src/ui/theme.dart';

export 'package:relay_app/src/domain/power_mode.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.status,
    required this.nickname,
    this.powerMode = PowerMode.balanced,
    this.onPowerModeChanged,
    this.onStealthChanged,
    this.onPanicWipe,
    this.onOpenDiagnostics,
    this.wifiEnabled = true,
    this.onWifiChanged,
    this.blocked = const [],
    this.onUnblock,
    this.panicGestureEnabled = false,
    this.onPanicGestureChanged,
    this.coverTrafficEnabled = false,
    this.onCoverTrafficChanged,
    this.coverTrafficFramesPerHour = 0,
    this.themeChoice = ThemeChoice.dark,
    this.onThemeChanged,
    this.hapticsEnabled = true,
    this.onHapticsChanged,
    this.onCarryForOthersChanged,
    this.onDropCarriedMail,
  });

  /// Whether the phone buzzes for sends, deliveries and mentions.
  ///
  /// On by default: this app is used with the phone in a pocket, and a buzz is
  /// often the only signal that arrives. The emergency wipe buzzes regardless —
  /// see [Haptics.panic].
  final bool hapticsEnabled;

  /// Whether this device holds sealed mail for people who are not here.
  /// The current value is read from [status], like every other mesh fact.
  final void Function(bool)? onCarryForOthersChanged;

  /// Throws away everything currently held for other people.
  final VoidCallback? onDropCarriedMail;

  final void Function(bool)? onHapticsChanged;

  /// How the user wants the app to look. See [ThemeChoice].
  final ThemeChoice themeChoice;

  final void Function(ThemeChoice)? onThemeChanged;

  final MeshStatus status;
  final String nickname;
  final PowerMode powerMode;
  final void Function(PowerMode)? onPowerModeChanged;
  final void Function(bool)? onStealthChanged;
  final VoidCallback? onPanicWipe;
  final VoidCallback? onOpenDiagnostics;

  /// Whether the user wants the local-network transport used at all.
  ///
  /// On by default and worth leaving on, but it is the one transport whose
  /// traffic is visible to a third party — the network's owner — so the choice
  /// belongs to the user rather than to us.
  final bool wifiEnabled;

  final void Function(bool)? onWifiChanged;

  /// People this device is hiding, newest first.
  ///
  /// Listed rather than merely counted. A block with no way to see who it
  /// applies to is a trap: someone silences a stranger in a crowd, later wants
  /// to undo it, and has no way to find them again.
  final List<({String nickname, DateTime blockedAt})> blocked;

  final void Function(int index)? onUnblock;

  /// Whether three quick taps on the title erase the phone.
  ///
  /// Off by default and deliberately so. It fires with no confirmation, which
  /// is what makes it useful when somebody is reaching for the phone and what
  /// makes an accidental trigger unrecoverable.
  final bool panicGestureEnabled;

  final void Function(bool)? onPanicGestureChanged;

  /// Whether this device pads its traffic pattern with meaningless frames and
  /// random delays. Off by default; it costs battery and buys partial cover.
  final bool coverTrafficEnabled;

  final void Function(bool)? onCoverTrafficChanged;

  /// Roughly how many extra frames an hour the setting costs, stated next to
  /// the switch so it is never presented as free.
  final int coverTrafficFramesPerHour;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    // Settings is a column of text and controls, so it gets the same reading
    // cap as anything else. Full-width rows on a desktop window put the switch
    // a foot away from the label it belongs to.
    body: ReadableWidth(
      maxWidth: 840,
      child: ListView(
        children: [
          ListTile(
            title: const Text('Your name'),
            subtitle: Text(nickname),
            leading: const Icon(Icons.person_outline),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'APPEARANCE',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          RadioGroup<ThemeChoice>(
            groupValue: themeChoice,
            onChanged: (value) =>
                value == null ? null : onThemeChanged?.call(value),
            child: Column(
              children: [
                for (final choice in ThemeChoice.values)
                  RadioListTile<ThemeChoice>(
                    key: Key('theme-${choice.name}'),
                    value: choice,
                    title: Text(choice.label),
                    subtitle: Text(choice.detail),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            key: const Key('haptics-switch'),
            value: hapticsEnabled,
            onChanged: onHapticsChanged,
            secondary: const Icon(Icons.vibration),
            title: const Text('Vibrate'),
            subtitle: const Text(
              'A short buzz when a message goes out, when one is confirmed on '
              'the other phone, and when somebody writes your name. The '
              'emergency wipe always buzzes, so you know it fired.',
            ),
            isThreeLine: true,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'BATTERY',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          RadioGroup<PowerMode>(
            groupValue: powerMode,
            onChanged: (value) =>
                value == null ? null : onPowerModeChanged?.call(value),
            child: Column(
              children: [
                for (final mode in PowerMode.values)
                  RadioListTile<PowerMode>(
                    key: Key('power-${mode.name}'),
                    value: mode,
                    title: Text(mode.label),
                    subtitle: Text(
                      '${mode.detail} · about '
                      '${mode.drainPercentPerHour}% battery per hour',
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          SwitchListTile(
            key: const Key('wifi-switch'),
            value: wifiEnabled,
            onChanged: onWifiChanged,
            secondary: const Icon(Icons.wifi),
            title: const Text('Use Wi-Fi when there is one'),
            subtitle: Text(
              'If you and someone else are on the same Wi-Fi, Relay sends '
              'messages over it as well as by Bluetooth. It is much faster, and '
              'it works even when that Wi-Fi has no internet. Whoever runs the '
              'network can see that you are sending something, though not what.'
              '${status.wifiDetail == null ? '' : '\n\n${status.wifiDetail}'}',
            ),
            isThreeLine: true,
          ),
          const Divider(),
          SwitchListTile(
            key: const Key('carry-for-others'),
            value: status.carryForOthers,
            onChanged: onCarryForOthersChanged,
            secondary: const Icon(Icons.markunread_mailbox_outlined),
            // Never "couriers". The word means nothing to somebody who has not
            // read the protocol notes, and this setting spends their battery.
            title: const Text('Carry messages for other people'),
            subtitle: const Text(
              'When someone you trust wants to reach a person who is not here, '
              'your phone can hold their message — sealed, so you cannot read '
              'it — and hand it over if you meet them. It is how anyone out of '
              'range is reached at all. It uses a little storage and battery.',
            ),
            isThreeLine: true,
          ),
          if (status.carriedCount > 0)
            ListTile(
              key: const Key('drop-carried'),
              leading: const Icon(Icons.delete_outline),
              title: Text(
                'Holding ${status.carriedCount} '
                'message${status.carriedCount == 1 ? '' : 's'} for other people',
              ),
              subtitle: const Text('Tap to throw them away'),
              onTap: () => _confirmDrop(context),
            ),
          const Divider(),
          SwitchListTile(
            key: const Key('stealth-switch'),
            value: status.stealthMode,
            onChanged: onStealthChanged,
            secondary: const Icon(Icons.visibility_off),
            title: const Text('Stealth mode'),
            subtitle: const Text(
              'Stop broadcasting your name and presence, and never use the '
              'internet relay. You keep passing on other people\'s messages, '
              'which is what hides your own.',
            ),
          ),
          const Divider(),
          SwitchListTile(
            key: const Key('cover-traffic-switch'),
            value: coverTrafficEnabled,
            onChanged: onCoverTrafficChanged,
            secondary: const Icon(Icons.blur_on),
            title: const Text('Hide when you are talking'),
            subtitle: Text(
              'Sends occasional messages that mean nothing, and waits a random '
              'moment before sending real ones, so that somebody watching the '
              'radio cannot tell when you are in a conversation. It does not '
              'hide everything — someone watching a quiet area for long enough '
              'can still work it out — and it uses more battery'
              '${coverTrafficFramesPerHour > 0 ? ', about $coverTrafficFramesPerHour extra messages an hour' : ''}.',
            ),
            isThreeLine: true,
          ),
          const Divider(),
          ExpansionTile(
            key: const Key('blocked-list'),
            leading: const Icon(Icons.block),
            title: const Text('Blocked people'),
            subtitle: Text(
              blocked.isEmpty
                  ? 'Nobody is blocked'
                  : '${blocked.length} blocked',
            ),
            children: [
              for (var i = 0; i < blocked.length; i++)
                ListTile(
                  key: Key('blocked-$i'),
                  title: Text(
                    blocked[i].nickname.isEmpty
                        ? 'Someone you blocked'
                        : blocked[i].nickname,
                  ),
                  trailing: TextButton(
                    onPressed: onUnblock == null ? null : () => onUnblock!(i),
                    child: const Text('Unblock'),
                  ),
                ),
            ],
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('Diagnostics'),
            subtitle: const Text(
              'Relay counters, dropped frames, service health',
            ),
            onTap: onOpenDiagnostics,
          ),
          const Divider(),
          const _ThreatModelSummary(),
          const Divider(),
          SwitchListTile(
            key: const Key('panic-gesture-switch'),
            value: panicGestureEnabled,
            onChanged: onPanicGestureChanged,
            secondary: const Icon(
              Icons.touch_app_outlined,
              color: AppColors.danger,
            ),
            title: const Text('Erase with three taps'),
            subtitle: const Text(
              'Tapping the title three times quickly erases everything on this '
              'phone straight away, with no question asked. That is the point: '
              'if someone is taking your phone there is no time for a question. '
              'It also means a stray triple-tap erases you.',
            ),
            isThreeLine: true,
          ),
          const Divider(),
          ListTile(
            key: const Key('panic-wipe'),
            leading: const Icon(Icons.delete_forever, color: AppColors.danger),
            title: const Text(
              'Erase everything',
              style: TextStyle(color: AppColors.danger),
            ),
            subtitle: const Text(
              'Destroys your identity, contacts and messages on this phone. '
              'Cannot be undone.',
            ),
            onTap: () => _confirmWipe(context),
          ),
        ],
      ),
    ),
  );

  Future<void> _confirmWipe(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erase everything?'),
        content: const Text(
          'Your identity, every contact you have verified, and all messages '
          'on this phone will be destroyed. There is no way to recover them, '
          'and contacts will have to verify you again from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-wipe'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Erase',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) onPanicWipe?.call();
  }

  Future<void> _confirmDrop(BuildContext context) async {
    final held = status.carriedCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Throw away what you are carrying?'),
        // Says what is lost and to whom. These are not this user's messages,
        // so the cost of dropping them falls entirely on somebody else — and
        // that somebody is never told.
        content: Text(
          'You are holding $held sealed message${held == 1 ? '' : 's'} for '
          'other people. Nobody else may be carrying a copy, so throwing '
          'them away can mean they never arrive. The people who sent them '
          'will not be told.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep carrying'),
          ),
          TextButton(
            key: const Key('drop-carried-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Throw away',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) onDropCarriedMail?.call();
  }
}

/// What the app does and does not protect, in plain language.
///
/// Stated in the product rather than buried in a document, because users make
/// safety decisions on their understanding of it.
class _ThreatModelSummary extends StatelessWidget {
  const _ThreatModelSummary();

  @override
  Widget build(BuildContext context) => const ExpansionTile(
    key: Key('threat-model'),
    leading: Icon(Icons.shield_outlined),
    title: Text('What Relay protects'),
    childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
    children: [
      _Point(
        good: true,
        text:
            'Direct messages are end-to-end encrypted. Phones passing them '
            'along cannot read them.',
      ),
      _Point(
        good: true,
        text:
            'Verified contacts cannot be impersonated once you have scanned '
            'their code in person.',
      ),
      _Point(
        good: false,
        text:
            'Group codes are short. Anyone who overhears or guesses one can '
            'read that group.',
      ),
      _Point(
        good: false,
        text:
            'Someone watching radio traffic can tell that you are using '
            'Relay and roughly when, even if they cannot read messages.',
      ),
      _Point(
        good: false,
        text:
            'When a message goes over Wi-Fi, whoever runs the Wi-Fi can see '
            'that your phone is talking to another one, and when. They cannot '
            'read anything you send.',
      ),
      _Point(
        good: false,
        text:
            'If your unlocked phone is taken, everything on it is readable. '
            'Erase it before that happens, not after.',
      ),
      _Point(
        good: false,
        text:
            'Relay has not yet had an independent security review. Do not '
            'rely on it where being wrong would be dangerous.',
      ),
    ],
  );
}

class _Point extends StatelessWidget {
  const _Point({required this.good, required this.text});

  final bool good;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          good ? Icons.check_circle_outline : Icons.remove_circle_outline,
          size: 16,
          color: good ? AppColors.direct : AppColors.caution,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
