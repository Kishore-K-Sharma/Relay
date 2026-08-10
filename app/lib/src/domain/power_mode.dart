/// Power modes, with their real battery cost stated.
///
/// The app never picks silently. Draining someone's phone to keep a mesh lively
/// is the fastest route to being uninstalled, so the cost is on screen next to
/// the choice.
///
/// Lives in `domain/` rather than beside the settings screen that renders it:
/// the runtime picks announce intervals from this, and the native parity
/// vectors pin the numbers. A screen import is not a dependency the mesh should
/// have in order to know how often to beacon.
enum PowerMode {
  performance('Performance', 'Finds people fastest', 12.0, 15000),
  balanced('Balanced', 'Recommended for most days', 5.0, 45000),
  saver('Battery saver', 'Slower to find people', 2.5, 120000),

  /// The floor. Reachable, barely — for somebody on 4% of battery who still
  /// needs to be findable, which in a crowd is exactly when it matters most.
  ultraLow(
    'Last resort',
    'Almost no battery, much slower to find people',
    1.0,
    300000,
  );

  const PowerMode(
    this.label,
    this.detail,
    this.drainPercentPerHour,
    this.announceIntervalMs,
  );

  final String label;
  final String detail;

  /// Shown to the user next to their choice.
  ///
  /// Pinned by `testvectors/power/modes.json` alongside the Kotlin and Swift
  /// figures. If this drifts from the duty cycle native actually runs, the app
  /// is quoting a battery cost it does not deliver.
  final double drainPercentPerHour;

  /// How often the presence beacon repeats. The dominant cost in a crowd,
  /// because every beacon is heard by everyone.
  final int announceIntervalMs;
}
