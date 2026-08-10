import 'package:flutter/material.dart';

/// The Relay mark, drawn rather than loaded.
///
/// A message leaves one phone, rides over a phone in between, and lands on
/// another. The middle node is a ring and not a dot because the phone that
/// relays your message carries it and cannot read it — which is the one fact
/// about this app worth putting in its logo.
///
/// This is the same geometry as `brand/relay-mark.svg`, restated as a painter:
/// sharp at any size, no asset to ship or forget to update, and it takes its
/// colour from the theme rather than being a green PNG that disappears against
/// a light background.
class RelayMark extends StatelessWidget {
  const RelayMark({super.key, required this.size, this.color});

  final double size;

  /// Overrides the theme colour, for the places the mark sits on a fixed
  /// surface whatever the user's theme is doing.
  final Color? color;

  /// The colour this mark would paint with in [context].
  Color resolveColor(BuildContext context) =>
      color ?? Theme.of(context).colorScheme.primary;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Relay',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(resolveColor(context))),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.color);

  final Color color;

  /// The mark is defined in a 100-unit square, exactly as the SVG is, so the
  /// two cannot drift apart without somebody editing both.
  static const double _unit = 100;
  static const double _stroke = 7.5;
  static const double _node = 8;
  static const double _ringStroke = 3.6;

  /// The gap punched through the wave where it passes the middle node. Matches
  /// the ring's inner edge, so the hole and the ring are the same circle.
  static const double _hole = _node - _ringStroke / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / _unit;
    canvas.save();
    canvas.scale(s);

    final wave = Path()
      ..moveTo(22, 50)
      ..quadraticBezierTo(36, -6, 50, 50)
      ..quadraticBezierTo(64, 106, 78, 50);

    // saveLayer, then clear a disc: the wave has to be genuinely absent inside
    // the ring, not covered by a disc of background colour. Painting over it
    // would look right on the dark theme it was drawn against and show as a
    // grey blob the moment the mark sits on anything else.
    canvas.saveLayer(const Rect.fromLTWH(0, 0, _unit, _unit), Paint());
    canvas.drawPath(
      wave,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      const Offset(50, 50),
      _hole,
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();

    final fill = Paint()..color = color;
    // Sender and recipient: solid. They hold the message.
    canvas.drawCircle(const Offset(22, 50), _node, fill);
    canvas.drawCircle(const Offset(78, 50), _node, fill);
    // The relay: hollow.
    canvas.drawCircle(
      const Offset(50, 50),
      _node,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.color != color;
}
