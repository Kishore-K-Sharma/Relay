import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:relay_app/src/domain/setup_step.dart';
import 'package:relay_app/src/ui/brand.dart';
import 'package:relay_app/src/ui/theme.dart';

export 'package:relay_app/src/domain/setup_step.dart';

/// The drawing half of [SetupStep].
///
/// The step itself is a plain domain enum, so that `AppState` can work out
/// what is still outstanding without importing a widget.
extension SetupStepIcon on SetupStep {
  IconData get icon => switch (this) {
    SetupStep.permissions => Icons.bluetooth,
    SetupStep.bluetoothOn => Icons.bluetooth_disabled,
    SetupStep.battery => Icons.battery_alert,
    SetupStep.identity => Icons.key,
  };
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({
    super.key,
    required this.outstanding,
    required this.onResolve,
    this.onFinish,
  });

  /// Steps not yet satisfied, in the order they should be handled.
  final List<SetupStep> outstanding;

  final void Function(SetupStep) onResolve;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    final done = outstanding.isEmpty;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Beside the name rather than above it, and the reason is
              // vertical room: stacked, the mark costs 72 points of fixed
              // header, and on a 320-point phone at the largest text size the
              // step list below it overflows. Alongside, it costs nothing —
              // the row is already as tall as the title — and it matches the
              // lockup in brand/.
              Row(
                children: [
                  const RelayMark(size: 40),
                  const SizedBox(width: 12),
                  // Shrinks rather than wraps. At the largest text size on a
                  // 320-point phone the name no longer fits beside the mark,
                  // and a wordmark broken across two lines reads as a layout
                  // fault rather than a logo.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'Relay',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Chat with people around you when there is no signal. '
                'Messages hop phone to phone.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              Expanded(
                child: done
                    ? const _AllSet()
                    : ListView.separated(
                        key: const Key('setup-steps'),
                        itemCount: outstanding.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final step = outstanding[index];
                          return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              key: Key('step-${step.name}'),
                              leading: Icon(step.icon),
                              title: Text(step.title),
                              subtitle: Text(step.detail),
                              isThreeLine: true,
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => onResolve(step),
                            ),
                          );
                        },
                      ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('onboarding-continue'),
                  onPressed: done ? onFinish : null,
                  child: Text(done ? 'Start' : 'Finish the steps above'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllSet extends StatelessWidget {
  const _AllSet();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('setup-complete'),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, size: 48, color: AppColors.direct),
        const SizedBox(height: 12),
        Text('Ready', style: Theme.of(context).textTheme.titleLarge),
      ],
    ),
  );
}

/// Shows this device's pairing code and the safety code to compare aloud.
///
/// Verification is a two-person act: both sides must see the same code, so the
/// screen shows it prominently rather than tucking it behind a menu.
class PairingScreen extends StatelessWidget {
  const PairingScreen({
    super.key,
    required this.myPublicKeyHex,
    this.safetyCode,
    this.peerName,
    this.onScan,
    this.onConfirm,
  });

  final String myPublicKeyHex;

  /// Present once a peer has been scanned and a shared code computed.
  final String? safetyCode;

  final String? peerName;
  final VoidCallback? onScan;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify a friend')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        // Scrollable: a QR code big enough to scan plus its text fallback does
        // not fit a small phone in landscape, and clipping the code would make
        // the screen useless for the one thing it exists to do.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (safetyCode == null) ...[
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Show this to your friend',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          key: const Key('pairing-qr'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            // White regardless of theme: a dark-on-dark QR code
                            // does not scan, and this one is to be pointed at.
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: QrImageView(
                            data: myPublicKeyHex,
                            size: 220,
                            backgroundColor: Colors.white,
                            // Medium survives a fingerprint on the screen
                            // without making the modules too small to read in
                            // poor light.
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Also shown as text: a cracked screen or a dead camera
                      // makes the code unscannable, and verification must
                      // still be possible.
                      Container(
                        key: const Key('pairing-payload'),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          myPublicKeyHex,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('scan-button'),
                onPressed: onScan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan their code'),
              ),
            ] else ...[
              Text(
                'Check this matches on both phones',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'If the numbers differ, someone may be impersonating '
                '${peerName ?? 'them'}. Do not continue.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Container(
                key: const Key('safety-code'),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  safetyCode!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    letterSpacing: 2,
                    height: 1.6,
                  ),
                ),
              ),
              const Spacer(),
              FilledButton(
                key: const Key('confirm-verify'),
                onPressed: onConfirm,
                child: const Text('They match — verify'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
