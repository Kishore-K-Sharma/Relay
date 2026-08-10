/// How strong the radio link to somebody is.
///
/// Distinct from `Reach`, which counts hops. Two people can both be one hop
/// away with one of them across the room and the other through a wall, and in a
/// crowd that difference is what the user is actually trying to judge.
///
/// The raw number is dBm — negative, closer to zero is stronger — and means
/// nothing to anybody who is not a radio engineer, so it never reaches the
/// screen.
enum SignalStrength {
  strong('Strong signal', 3),
  fair('Fair signal', 2),
  weak('Weak signal', 1);

  const SignalStrength(this.label, this.bars);

  final String label;
  final int bars;

  /// The band for an RSSI reading, or null if there is not one.
  ///
  /// Null is a real answer and not a failure: a peer reached over Wi-Fi or
  /// through a relay has no measured link strength, and inventing a bar count
  /// for one would put a confident number on something nobody measured.
  static SignalStrength? fromRssi(int? rssi) {
    if (rssi == null) return null;
    // Some chipsets report 127 for "unknown" and others return nonsense on a
    // disconnect, so the ends are clamped rather than trusted.
    final clamped = rssi.clamp(-120, 0);
    if (clamped >= -65) return strong;
    if (clamped >= -85) return fair;
    return weak;
  }
}
