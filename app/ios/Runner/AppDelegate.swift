import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// Held for the lifetime of the process. Releasing it would tear down the
  /// Pigeon handlers and, with them, every route between Dart and the radio.
  private var ble: MeshBlePlugin?

  /// Local-network discovery. Unlike the Bluetooth relay this one genuinely
  /// stops when the app is backgrounded — iOS closes the sockets — so it is
  /// tied to the engine rather than to the process.
  private var discovery: MeshDiscoveryPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Registered by hand rather than as a Flutter plugin: the mesh lives in the
    // app target, not a pub package, because the relay has to keep running when
    // iOS relaunches the process into the background with no engine attached.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MeshBlePlugin") {
      ble = MeshBlePlugin.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "MeshDiscoveryPlugin"
    ) {
      discovery = MeshDiscoveryPlugin.register(with: registrar.messenger())
    }
  }
}
