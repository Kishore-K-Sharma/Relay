import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:relay_app/src/domain/pairing_payload.dart';
import 'package:relay_app/src/ui/theme.dart';

/// Camera view for scanning a friend's pairing code.
///
/// Pops with the decoded [PairingPayload], or null if the user backs out.
/// Codes that are not ours are ignored silently: a camera pointed at a street
/// sees other QR codes constantly, and flashing an error at every one of them
/// would make the screen unusable.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.controller});

  /// Injectable so widget tests can drive the screen without a camera.
  final MobileScannerController? controller;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final MobileScannerController _controller =
      widget.controller ??
      MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );

  bool _handled = false;

  @override
  void dispose() {
    // Only ours to dispose if we made it.
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    // The scanner keeps firing while the pop animation runs; without this the
    // route is popped twice and the caller gets a result it never asked for.
    if (_handled) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final payload = PairingPayload.decode(raw);
      if (payload == null) continue;

      _handled = true;
      Navigator.of(context).pop(payload);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan their code')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          key: const Key('scanner-view'),
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _CameraUnavailable(error: error),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            color: Colors.black.withValues(alpha: 0.6),
            padding: const EdgeInsets.all(20),
            child: Text(
              'Point at the code on your friend\'s phone. '
              'Do this in person — that is the whole point of it.',
              key: const Key('scan-hint'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('camera-unavailable'),
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography, size: 40, color: AppColors.caution),
          const SizedBox(height: 12),
          Text(
            switch (error.errorCode) {
              MobileScannerErrorCode.permissionDenied =>
                'Relay needs camera permission to scan a code. You can still '
                    'verify by reading the numbers out loud instead.',
              MobileScannerErrorCode.unsupported =>
                'This device has no usable camera. Verify by reading the '
                    'numbers out loud instead.',
              _ =>
                'The camera could not be started. Verify by reading the '
                    'numbers out loud instead.',
            },
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}
