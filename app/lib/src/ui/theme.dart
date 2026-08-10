import 'package:flutter/material.dart';

import 'package:relay_app/src/domain/reach.dart';
import 'package:relay_app/src/domain/theme_choice.dart';

// Re-exported so that a screen importing the theme still gets the enum and the
// extension that renders it together. Splitting them was about which layer may
// depend on Flutter, not about making every call site import two files.
export 'package:relay_app/src/domain/reach.dart';
export 'package:relay_app/src/domain/signal_strength.dart';
export 'package:relay_app/src/domain/theme_choice.dart';

/// Design tokens.
///
/// Dark-first: the app is used at night, outdoors, in crowds, and a bright
/// screen both ruins night vision and marks you out. A light theme exists for
/// daytime and accessibility, but dark is the default rather than an option.
abstract final class AppColors {
  static const seed = Color(0xFF5FD97A);

  // Reachability is the one thing this app must communicate constantly, so it
  // gets its own dedicated, consistent colour scale rather than borrowing the
  // generic semantic palette.
  static const direct = Color(0xFF5FD97A); // in range, 1 hop
  static const nearby = Color(0xFF7AA7F0); // 2 hops
  static const distant = Color(0xFFE0B34D); // 3+ hops
  static const unreachable = Color(
    0xFF6B7280,
  ); // known, not currently reachable

  static const danger = Color(0xFFE5484D);
  static const caution = Color(0xFFE0B34D);
}

/// The drawing half of [Reach]. The band itself is a domain enum, because a
/// `Peer` has to know how far away it is without knowing what colour that is.
extension ReachColor on Reach {
  Color get color => switch (this) {
    Reach.direct => AppColors.direct,
    Reach.nearby => AppColors.nearby,
    Reach.distant => AppColors.distant,
    Reach.gone => AppColors.unreachable,
  };
}

/// The Flutter half of [ThemeChoice], which itself is a plain domain enum so
/// that `AppState` can hold the preference without importing `material.dart`.
extension ThemeChoiceMode on ThemeChoice {
  ThemeMode get mode => switch (this) {
    ThemeChoice.dark => ThemeMode.dark,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.system => ThemeMode.system,
  };
}

ThemeData appTheme({Brightness brightness = Brightness.dark}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? const Color(0xFF0F1115)
        : scheme.surface,
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14),
      bodySmall: TextStyle(fontSize: 12),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
    ),
    dividerTheme: const DividerThemeData(space: 1, thickness: 1),
  );
}
