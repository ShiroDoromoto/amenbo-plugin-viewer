import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    FileProtectionBridge.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: FileProtectionBridge.channelName)!)
    BuildOriginBridge.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: BuildOriginBridge.channelName)!)
  }
}
