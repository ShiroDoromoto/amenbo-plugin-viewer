import Flutter
import Foundation

/// The iOS half of `NSFileProtectionComplete` on the local backlog.
///
/// SQLite keeps more than one file: the database, and — in WAL mode — a `-wal` and a `-shm`
/// beside it. Protecting only the first would leave the most recent writes readable on a locked
/// phone, so all three are set, and the two that do not exist yet are set again the next time the
/// store is opened.
///
/// Setting the attribute on a file that is already open is allowed; the class takes effect for
/// the next time the phone locks.
final class FileProtectionBridge: NSObject {
  static let channelName = "work.amenbo.viewer/file_protection"

  private let work = DispatchQueue(label: "work.amenbo.viewer.file_protection", qos: .utility)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let bridge = FileProtectionBridge()
    channel.setMethodCallHandler { [bridge] call, result in
      bridge.handle(call, result: result)
    }
    // The registrar lets go once registration returns; the closure above is what keeps this alive.
    objc_setAssociatedObject(channel, &associationKey, bridge, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "protect":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "protect needs a path", details: nil))
        return
      }
      work.async {
        let applied = Self.protect(path)
        DispatchQueue.main.async { result(applied) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// True when the database file itself came back protected. The journals are best effort — they
  /// may not exist yet, and they are recreated under the database's own class.
  private static func protect(_ path: String) -> Bool {
    let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
    var applied = false
    for candidate in [path, path + "-wal", path + "-shm"] {
      guard FileManager.default.fileExists(atPath: candidate) else { continue }
      do {
        try FileManager.default.setAttributes(attributes, ofItemAtPath: candidate)
        if candidate == path { applied = true }
      } catch {
        if candidate == path { return false }
      }
    }
    return applied
  }
}

private var associationKey: UInt8 = 0
