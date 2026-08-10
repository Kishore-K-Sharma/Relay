/// Distance bands, mapped from hop count.
///
/// Deliberately coarse. A precise hop number means nothing to a user; "right
/// here" versus "somewhere in the crowd" does.
///
/// The colour for each band is in `ui/theme.dart` — see the `ReachColor`
/// extension. A `Peer` has to know how far away it is; it does not have to know
/// what shade that is drawn in.
enum Reach {
  direct('In range'),
  nearby('Nearby'),
  distant('Far side'),
  gone('Not reachable');

  const Reach(this.label);

  final String label;

  static Reach fromHops(int? hops) => switch (hops) {
    null => Reach.gone,
    <= 1 => Reach.direct,
    2 => Reach.nearby,
    _ => Reach.distant,
  };
}
