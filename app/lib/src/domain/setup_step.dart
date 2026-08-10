/// What still has to happen before the mesh works.
///
/// Modelled as explicit steps rather than a wizard because the battery step in
/// particular is not optional on many Android phones: skip it and the relay is
/// killed silently, and the user concludes the app is broken.
///
/// The icon for each step is a rendering decision and lives with the screen
/// that draws it — see the `SetupStepIcon` extension in `ui/screens/`. Keeping
/// it out of here is what lets `AppState`, which every headless mesh test
/// builds, work out what is outstanding without importing a widget.
enum SetupStep {
  permissions(
    'Allow Bluetooth',
    'Relay finds people nearby over Bluetooth. It never uses your location.',
  ),
  bluetoothOn(
    'Turn on Bluetooth',
    'Nothing can be sent or received while Bluetooth is off.',
  ),
  battery(
    'Stop your phone killing Relay',
    'This phone shuts down background apps aggressively. Without an '
        'exemption, Relay stops passing on messages the moment you close it.',
  ),
  identity(
    'Create your identity',
    'Generated on this phone. No account, no phone number, nothing sent '
        'anywhere.',
  );

  const SetupStep(this.title, this.detail);

  final String title;
  final String detail;
}
