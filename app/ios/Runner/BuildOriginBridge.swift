import Flutter
import Foundation

/// The iOS half of "where did this copy come from".
///
/// The App Store and TestFlight deliver the same app — same identifier, same version — so the
/// only thing that separates them is the receipt iOS put in the bundle. Its **name** is the
/// answer, and reading the name is the whole of the job: `sandboxReceipt` is TestFlight,
/// `receipt` is the store.
///
/// A build installed from Xcode has no receipt file. The URL is still handed out, pointing at
/// something that is not there, so the file has to be looked for rather than the URL trusted.
///
/// Nothing is validated here. A receipt is a signed document and checking it is what you do
/// before unlocking a purchase; this app sells nothing, and the name is on the outside.
final class BuildOriginBridge: NSObject {
  static let channelName = "work.amenbo.viewer/build_origin"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let bridge = BuildOriginBridge()
    channel.setMethodCallHandler { [bridge] call, result in
      bridge.handle(call, result: result)
    }
    // The registrar lets go once registration returns; the closure above is what keeps this alive.
    objc_setAssociatedObject(channel, &associationKey, bridge, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "read":
      result(Self.origin())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One of the words the Dart side knows. Anything unaccounted for is `unknown` rather than a
  /// guess at the likeliest of them.
  private static func origin() -> String {
    guard let receipt = Bundle.main.appStoreReceiptURL else { return "unknown" }
    guard FileManager.default.fileExists(atPath: receipt.path) else { return "none" }
    switch receipt.lastPathComponent {
    case "sandboxReceipt": return "testflight"
    case "receipt": return "store"
    default: return "unknown"
    }
  }
}

private var associationKey: UInt8 = 0
