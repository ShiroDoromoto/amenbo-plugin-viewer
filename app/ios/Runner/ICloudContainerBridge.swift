import Flutter
import UIKit

/// The iOS half of the iCloud path.
///
/// The app reads its **own** iCloud container — nobody picks anything. That removes the picker
/// and the security-scoped bookmark the earlier folder path needed, and leaves two joins worth
/// writing by hand: resolving the container, and reading a file whose contents are not on the
/// device (`startDownloadingUbiquitousItem` plus `NSFileCoordinator`).
///
/// The container is granted by entitlements (`Runner.entitlements`), so there is nothing to ask
/// the person for and nothing to keep across launches. Not being signed in to iCloud is a normal
/// state, reported as `available: false` rather than as an error.
///
/// Everything that touches the file system runs off the main thread: resolving the container and
/// a coordinated read of a file that is not downloaded yet both block on the file provider, which
/// is a network round trip. The platform channel's reply goes back on the main thread afterwards.
final class ICloudContainerBridge: NSObject {
  static let channelName = "work.amenbo.viewer/icloud_container"

  /// The app's own container. It has no team prefix, and on disk the dots become tildes:
  /// `~/Library/Mobile Documents/iCloud~work~amenbo~viewer/` — which is the path the plugin on
  /// the Mac writes into.
  private static let containerIdentifier = "iCloud.work.amenbo.viewer"

  private let work = DispatchQueue(label: "work.amenbo.viewer.icloud_container", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let bridge = ICloudContainerBridge()
    channel.setMethodCallHandler { [bridge] call, result in
      bridge.handle(call, result: result)
    }
    // The registrar drops its reference once registration returns; the closure above is what
    // keeps the bridge alive.
    objc_setAssociatedObject(channel, &associationKey, bridge, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      async(result) { try self.status() }
    case "list":
      async(result) { try self.list() }
    case "read":
      guard let name = (call.arguments as? [String: Any])?["name"] as? String else {
        result(FlutterError(code: "bad_args", message: "read needs a file name", details: nil))
        return
      }
      async(result) { try self.read(name: name) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Runs `body` off the main thread and replies on it, turning a thrown error into a channel
  /// error rather than a crash.
  private func async(_ result: @escaping FlutterResult, _ body: @escaping () throws -> Any?) {
    work.async {
      do {
        let value = try body()
        DispatchQueue.main.async { result(value) }
      } catch {
        let message = (error as NSError).localizedDescription
        DispatchQueue.main.async {
          result(FlutterError(code: "icloud_container", message: message, details: nil))
        }
      }
    }
  }

  // MARK: - 1. Resolve the container

  /// The directory both sides agree on, or nil when iCloud is not usable on this device.
  ///
  /// Creating `Documents/` is the app's job and only the app's: `~/Library/Mobile Documents` is
  /// not writable by an ordinary process, so the Mac's write target does not exist until an
  /// iPhone has run this once. Everything downstream depends on that order.
  private func documents() throws -> URL? {
    guard
      let container = FileManager.default.url(
        forUbiquityContainerIdentifier: Self.containerIdentifier)
    else { return nil }
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    if !FileManager.default.fileExists(atPath: documents.path) {
      try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }
    return documents
  }

  /// The same directory for callers that cannot do anything without one.
  private func requireDocuments() throws -> URL {
    guard let documents = try documents() else {
      throw Failure("iCloud is not available on this device")
    }
    return documents
  }

  private func status() throws -> [String: Any] {
    guard let documents = try documents() else { return ["available": false] }
    return ["available": true, "path": documents.path]
  }

  // MARK: - 2. Read what is not on the device

  private static let entryKeys: [URLResourceKey] = [
    .fileSizeKey, .isDirectoryKey, .isUbiquitousItemKey,
    .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey,
  ]

  private func list() throws -> [String: Any] {
    let documents = try requireDocuments()
    var found: [[String: Any]] = []
    try coordinatedRead(documents) { dir in
      let urls = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: Self.entryKeys, options: [.skipsHiddenFiles])
      found = urls.map(Self.describe)
    }
    return ["path": documents.path, "entries": found]
  }

  /// Reads one file out of the container and reports whether it had to be fetched first.
  ///
  /// `statusBefore` is the half that matters: bytes coming back for an item the device was not
  /// holding is the requirement. The after-sample lags — it still reads `notDownloaded` on a read
  /// that has just handed over every byte, and only turns `current` some time later — so it is
  /// reported as an observation, not used as the proof.
  private func read(name: String) throws -> [String: Any] {
    let file = try requireDocuments().appendingPathComponent(name)
    let before = Self.downloadStatus(of: file)
    if before != URLUbiquitousItemDownloadingStatus.current.rawValue {
      try? FileManager.default.startDownloadingUbiquitousItem(at: file)
    }
    var bytes = 0
    var head = ""
    // A coordinated read waits for the file provider to materialise the contents, so the read
    // inside the block sees real bytes even when the status above said they were not here.
    try coordinatedRead(file) { url in
      let data = try Data(contentsOf: url)
      bytes = data.count
      head = String(decoding: data.prefix(120), as: UTF8.self)
    }
    return [
      "name": name,
      "bytes": bytes,
      "head": head,
      "statusBefore": before,
      "statusAfter": Self.downloadStatus(of: URL(fileURLWithPath: file.path)),
    ]
  }

  private func coordinatedRead(_ url: URL, _ body: (URL) throws -> Void) throws {
    var coordinationError: NSError?
    var thrown: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      resolved in
      do { try body(resolved) } catch { thrown = error }
    }
    if let coordinationError = coordinationError { throw coordinationError }
    if let thrown = thrown { throw thrown }
  }

  private static func describe(_ url: URL) -> [String: Any] {
    let values = try? url.resourceValues(forKeys: Set(entryKeys))
    return [
      "name": url.lastPathComponent,
      "isDirectory": values?.isDirectory ?? false,
      "bytes": values?.fileSize ?? 0,
      "ubiquitous": values?.isUbiquitousItem ?? false,
      "status": downloadStatus(of: url),
    ]
  }

  /// `notDownloaded` / `downloaded` / `current`, or `unknown` for a file the system does not
  /// treat as an iCloud item at all.
  private static func downloadStatus(of url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    return values?.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown"
  }
}

private var associationKey: UInt8 = 0

private struct Failure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
