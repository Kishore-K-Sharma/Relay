import 'dart:math';

import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/theme.dart';

/// Signal-strength radar.
///
/// Distance from the centre is **signal strength, not position**. BLE gives no
/// bearing, so any layout implying direction would be a fabrication. The screen
/// says so on its face: users walking toward someone see them pull inward,
/// which is the honest and genuinely useful reading.
class RadarScreen extends StatelessWidget {
  const RadarScreen({super.key, required this.peers, this.onTapPeer});

  final List<Peer> peers;
  final void Function(Peer)? onTapPeer;

  @override
  Widget build(BuildContext context) {
    final reachable = peers.where((p) => p.isReachable).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Radar')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Text(
              'Closer to the centre means a stronger signal. '
              'This is not a map — it cannot show which direction someone is in.',
              key: const Key('radar-disclaimer'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: reachable.isEmpty
                ? const Center(
                    key: Key('radar-empty'),
                    child: Text('Nobody in range'),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => CustomPaint(
                      painter: _RadarPainter(
                        peers: reachable,
                        rings: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      child: Stack(
                        key: const Key('radar-field'),
                        children: [
                          for (final (index, peer) in reachable.indexed)
                            _positioned(
                              constraints,
                              peer,
                              index,
                              reachable.length,
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _positioned(
    BoxConstraints constraints,
    Peer peer,
    int index,
    int total,
  ) {
    final centre = Offset(constraints.maxWidth / 2, constraints.maxHeight / 2);
    final maxRadius = min(centre.dx, centre.dy) - 40;

    // Hops map to rings. The angle is arbitrary and evenly spread, because BLE
    // provides no bearing — it exists only to stop dots overlapping.
    final ring = ((peer.hops ?? 4).clamp(1, 4)) / 4.0;
    final angle = (2 * pi * index) / max(total, 1);
    final position =
        centre + Offset(cos(angle), sin(angle)) * (maxRadius * ring);

    return Positioned(
      left: position.dx - 22,
      top: position.dy - 22,
      child: GestureDetector(
        onTap: onTapPeer == null ? null : () => onTapPeer!(peer),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: peer.reach.color,
              ),
              alignment: Alignment.center,
              child: Text(
                peer.nickname.isEmpty ? '?' : peer.nickname[0].toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F1115),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(peer.nickname, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({required this.peers, required this.rings});

  final List<Peer> peers;
  final Color rings;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(centre.dx, centre.dy) - 40;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = rings;

    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(centre, maxRadius * (i / 4), paint);
    }

    canvas.drawCircle(centre, 7, Paint()..color = AppColors.direct);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) => oldDelegate.peers != peers;
}
