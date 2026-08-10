import 'package:flutter/material.dart';
import 'package:transport_ble/transport_ble.dart';

import 'package:relay_app/src/runtime/event_log.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/theme.dart';

/// What the mesh is actually doing.
///
/// A mesh fails invisibly. Nothing arrives, and the user has no way to tell
/// whether nobody is nearby, the radio is off, the phone killed the service, or
/// their messages are going out and being ignored. Every counter here exists to
/// distinguish one of those from the others, and each is explained in words
/// rather than left as a labelled number.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({
    super.key,
    required this.status,
    required this.stats,
    required this.outboxDepth,
    this.log = const [],
    this.onRefresh,
    this.onCopyLog,
  });

  final MeshStatus status;
  final BleRelayStats stats;

  /// Messages written but not yet acknowledged.
  final int outboxDepth;

  /// Recent activity, newest first. Held in memory only and never uploaded.
  final List<LogEntry> log;

  final VoidCallback? onRefresh;

  /// Puts the log on the clipboard. The user's decision and their clipboard;
  /// the app never sends it anywhere itself.
  final VoidCallback? onCopyLog;

  bool get _idle => stats.framesReceived == 0 && stats.framesRelayed == 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Diagnostics'),
      actions: [
        IconButton(
          key: const Key('diagnostics-refresh'),
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (status.problem != null)
          _Banner(key: const Key('diagnostics-problem'), text: status.problem!),
        const _Section(title: 'RIGHT NOW'),
        _Counter(
          label: 'People in range',
          value: status.peersInRange,
          explanation: 'Phones this one can currently reach directly.',
        ),
        _Counter(
          key: const Key('diagnostics-wifi'),
          label: 'People on this Wi-Fi',
          value: status.wifiPeers,
          explanation: status.wifiDetail == null
              ? 'Phones reachable over the local network. These are the '
                    'fastest, and they work even if the network has no '
                    'internet.'
              // A count of zero has two very different causes, and the user
              // can only act on one of them.
              : 'The local network is not being used. ${status.wifiDetail}',
        ),
        _Counter(
          key: const Key('diagnostics-outbox'),
          label: 'Waiting to send',
          value: outboxDepth,
          explanation:
              'Messages written on this phone that have not been confirmed '
              'by the other side yet. They keep retrying for 24 hours.',
        ),
        _Counter(
          label: 'Held for someone else',
          value: stats.storedForForward,
          explanation:
              'Other people\'s messages this phone is carrying until their '
              'recipient comes back into range.',
        ),
        _Counter(
          label: 'Waiting to be read',
          value: stats.inboxDepth,
          explanation:
              'Messages that arrived while the app was closed and have not '
              'been picked up yet.',
        ),
        const Divider(),
        const _Section(title: 'SINCE THE MESH STARTED'),
        if (_idle)
          const _Note(
            key: Key('diagnostics-idle'),
            text:
                'No traffic yet. That is normal if nobody is nearby — this '
                'phone only sees messages from people within Bluetooth range '
                'of it or of someone relaying to it.',
          ),
        _Counter(
          label: 'Frames received',
          value: stats.framesReceived,
          explanation: 'Everything heard on the radio, for anyone.',
        ),
        _Counter(
          label: 'Frames passed on',
          value: stats.framesRelayed,
          explanation:
              'Messages for other people that this phone carried a hop '
              'further. This is what makes the mesh work.',
        ),
        _Counter(
          label: 'Not passed on',
          value: stats.framesSuppressed,
          explanation:
              'Frames this phone chose not to repeat because enough '
              'neighbours were already carrying them. A high number here is '
              'good: it means the crowd is dense and nothing is being wasted.',
        ),
        _Counter(
          label: 'Dropped',
          value: stats.framesDropped,
          explanation:
              'Duplicates, frames that had run out of hops, and frames this '
              'phone had already seen.',
        ),
        const Divider(),
        const _Section(title: 'RADIO'),
        _Flag(label: 'Bluetooth on', value: status.bluetoothOn),
        _Flag(label: 'Permission granted', value: status.permissionsGranted),
        _Flag(
          label: 'Discoverable by others',
          value: status.canAdvertise && !status.stealthMode,
          falseExplanation: status.stealthMode
              ? 'Stealth mode is on. You still carry other people\'s '
                    'messages, which is what hides your own.'
              : 'This phone can receive and pass on messages but cannot '
                    'advertise, so others will not find it first.',
        ),
        _Flag(
          label: 'Internet relay available',
          value: status.relayAvailable,
          falseExplanation:
              'Messages can only reach people within Bluetooth range, '
              'directly or through others.',
        ),
        const Divider(),
        Row(
          children: [
            const Expanded(child: _Section(title: 'RECENT ACTIVITY')),
            if (onCopyLog != null)
              TextButton.icon(
                key: const Key('diagnostics-copy-log'),
                onPressed: onCopyLog,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            const SizedBox(width: 8),
          ],
        ),
        const _Note(
          text:
              'Kept on this phone only, in memory, and erased when you close '
              'the app. Relay has no crash reporter and sends nothing '
              'anywhere. Copy it yourself if you want to share it.',
        ),
        if (log.isEmpty)
          const _Note(key: Key('diagnostics-log-empty'), text: 'Nothing yet.')
        else
          for (final entry in log.take(50))
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Text(
                entry.timestamp,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              title: Text(
                entry.message,
                style: TextStyle(
                  fontSize: 13,
                  color: switch (entry.level) {
                    LogLevel.error => AppColors.danger,
                    LogLevel.warning => AppColors.caution,
                    LogLevel.info => null,
                  },
                ),
              ),
            ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelSmall),
  );
}

class _Counter extends StatelessWidget {
  const _Counter({
    super.key,
    required this.label,
    required this.value,
    required this.explanation,
  });

  final String label;
  final int value;
  final String explanation;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(label),
    subtitle: Text(explanation),
    isThreeLine: true,
    trailing: Text(
      '$value',
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontFeatures: const []),
    ),
  );
}

class _Flag extends StatelessWidget {
  const _Flag({
    required this.label,
    required this.value,
    this.falseExplanation,
  });

  final String label;
  final bool value;
  final String? falseExplanation;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(
      value ? Icons.check_circle_outline : Icons.remove_circle_outline,
      color: value ? AppColors.direct : AppColors.caution,
      size: 20,
    ),
    title: Text(label),
    subtitle: value || falseExplanation == null
        ? null
        : Text(falseExplanation!),
  );
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: AppColors.caution.withValues(alpha: 0.14),
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        const Icon(Icons.warning_amber, size: 18, color: AppColors.caution),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
