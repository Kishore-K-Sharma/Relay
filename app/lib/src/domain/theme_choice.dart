/// How the user wants the app to look.
///
/// Dark is the default rather than the only option. The app is used at night,
/// outdoors and in crowds, where a bright screen ruins night vision and marks
/// somebody out — but that is a reason for a default, not for refusing a
/// daylight setting to a user who is standing in daylight.
///
/// The mapping onto Flutter's `ThemeMode` is in `ui/theme.dart`, because
/// `AppState` holds this preference and must not drag `material.dart` into
/// every test that constructs it.
enum ThemeChoice {
  dark('Dark', 'Best at night and in crowds'),
  light('Light', 'Best in daylight'),
  system('Match my phone', 'Follows the phone\'s own setting');

  const ThemeChoice(this.label, this.detail);

  final String label;
  final String detail;
}
