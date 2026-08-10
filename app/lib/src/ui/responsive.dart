import 'package:flutter/material.dart';

/// How much room there is, in the only three amounts that change the layout.
///
/// Named after what the window can *hold* rather than after a device, because
/// a phone in landscape, a small tablet and a half-width desktop window are the
/// same layout problem and there is no useful sense in which one of them is
/// "the tablet case".
///
/// The thresholds are Material's, which matters less for being correct than for
/// being the ones every other app on the device already uses: a user who rotates
/// their phone should find things where rotating any other app puts them.
enum Breakpoint {
  /// A phone held upright. One thing on screen at a time.
  compact,

  /// A phone on its side, or a small tablet. Roomier, still one column —
  /// wide enough to look spacious and too narrow to hold a conversation beside
  /// a list without squeezing both.
  medium,

  /// A large tablet or a desktop window. Both panes at once.
  expanded;

  static const double _mediumFrom = 600;
  static const double _expandedFrom = 840;

  /// The breakpoint for a window [width] points wide.
  ///
  /// Zero and negative widths answer [compact] rather than throwing: both occur
  /// for a frame during startup and during some desktop resizes, and a crash
  /// there would be a crash nobody could reproduce.
  static Breakpoint of(double width) {
    if (width >= _expandedFrom) return expanded;
    if (width >= _mediumFrom) return medium;
    return compact;
  }

  /// The breakpoint for the window [context] is in.
  static Breakpoint from(BuildContext context) =>
      of(MediaQuery.sizeOf(context).width);

  /// Wide enough for two panes. Not sufficient on its own — see [Panes].
  bool get isWideEnoughForTwoPanes => this == expanded;
}

/// Whether the window can hold a list and a conversation at once.
///
/// Width alone is not the test, which is the mistake worth spelling out. A
/// phone in landscape is 844 points wide and 390 tall: wide enough by any
/// breakpoint table, and useless in practice, because raising the keyboard
/// leaves about 150 points for the conversation. Both dimensions have to be
/// there.
abstract final class Panes {
  /// Enough vertical room for a conversation, a composer, and a keyboard.
  static const double minHeight = 600;

  static bool twoIn(Size size) =>
      Breakpoint.of(size.width).isWideEnoughForTwoPanes &&
      size.height >= minHeight;

  static bool of(BuildContext context) => twoIn(MediaQuery.sizeOf(context));
}

/// Stops a column of text growing wider than it can comfortably be read.
///
/// A line spanning a 1400-point window is physically hard to read — the eye
/// loses the start of the next line on the way back. On a phone this does
/// nothing at all, which is the point: capping there would waste the only space
/// there is.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.maxWidth});

  /// Roughly 90 characters at this app's body size.
  static const double maximum = 720;

  final Widget child;

  /// Overrides [maximum] where a particular screen needs a different measure —
  /// a settings list can take more than a paragraph can.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cap = maxWidth ?? maximum;
      final excess = constraints.maxWidth.isFinite
          ? constraints.maxWidth - cap
          : 0.0;

      // Padding rather than an Align or a SizedBox, and the reason is worth
      // stating because both alternatives were tried and both broke something.
      //
      // An `Align` loosens the height constraint, and a scrolling child given
      // a loose height shrink-wraps to nothing: every control inside it is
      // painted, none of it can be tapped, and the screen looks entirely
      // normal. Forcing the height instead fixes that and breaks the opposite
      // case — in a `bottomNavigationBar` slot it makes the bar as tall as the
      // whole window, leaving the body no room at all.
      //
      // Padding changes neither axis's tightness. It only moves the edges in.
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: excess > 0 ? excess / 2 : 0),
        child: child,
      );
    },
  );
}

/// Honours the user's text size, up to the point where the app stops working.
///
/// Accessibility settings are not a suggestion, and ignoring them outright is
/// the most common way an app becomes unusable for somebody. But some platforms
/// offer 3x and beyond, and past a point every row on every screen overflows —
/// at which point the app shows nothing but overflow stripes, which helps
/// nobody. So it is clamped, not ignored: a user who asks for huge text gets
/// the largest this layout can actually render.
class AppTextScale extends StatelessWidget {
  const AppTextScale({super.key, required this.child});

  /// The largest multiplier every screen has been checked at.
  static const double maximum = 1.6;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(maxScaleFactor: maximum),
      ),
      child: child,
    );
  }
}
