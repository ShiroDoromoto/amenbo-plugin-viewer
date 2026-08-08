import Flutter
import UIKit
import UniformTypeIdentifiers

/// The iOS half of the iCloud Drive folder path.
///
/// Three things have to hold at once, and no package does all three, so the joins are written
/// here: pick a folder once with `UIDocumentPicker`, keep the permission across restarts with a
/// security-scoped bookmark, and read files whose contents are not on the device with
/// `NSFileCoordinator`.
///
/// **This path is iCloud Drive only.** Other providers do not vend folders to the picker.
///
/// Everything that touches the file system runs off the main thread: a coordinated read of a file
/// that is not downloaded yet blocks until the file provider has materialised it, which is a
/// network round trip, and the platform channel's reply goes back on the main thread afterwards.
final class ICloudFolderBridge: NSObject {
  static let channelName = "work.amenbo.viewer/icloud_folder"

  /// Where the bookmark lives between launches. `UserDefaults` is enough for the probe; the real
  /// app will want the keychain, which survives an app being deleted and reinstalled.
  private static let bookmarkKey = "work.amenbo.viewer.icloud_folder_bookmark"

  private let defaults = UserDefaults.standard
  private let work = DispatchQueue(label: "work.amenbo.viewer.icloud_folder", qos: .userInitiated)

  /// The picker's delegate is not retained by the picker, so it is held here for the length of
  /// the presentation, along with the result callback it has to reach.
  private var pickerDelegate: PickerDelegate?

  /// Looked up when the picker is about to be shown rather than held: registration happens while
  /// the engine is coming up, which is before there is a window to present from.
  private var presenter: UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
      .first
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let bridge = ICloudFolderBridge()
    channel.setMethodCallHandler { [bridge] call, result in
      bridge.handle(call, result: result)
    }
    // The registrar drops its reference once registration returns; the closure above is what
    // keeps the bridge alive.
    objc_setAssociatedObject(channel, &associationKey, bridge, .OBJC_ASSOCIATION_RETAIN)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pick":
      pick(result: result)
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
    case "forget":
      defaults.removeObject(forKey: Self.bookmarkKey)
      result(nil)
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
          result(FlutterError(code: "icloud_folder", message: message, details: nil))
        }
      }
    }
  }

  // MARK: - 1. Pick the folder, once

  private func pick(result: @escaping FlutterResult) {
    guard let presenter = presenter else {
      result(FlutterError(code: "no_presenter", message: "no view controller to present from", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.allowsMultipleSelection = false
    let delegate = PickerDelegate { [weak self] url in
      self?.pickerDelegate = nil
      guard let self = self, let url = url else {
        result(nil)
        return
      }
      do {
        try self.remember(url)
        // Reported through the same call the next launch makes, so a folder just picked and a
        // folder resolved from the bookmark are described by one code path and cannot disagree.
        result(try self.status())
      } catch {
        result(FlutterError(
          code: "bookmark_failed", message: (error as NSError).localizedDescription, details: nil))
      }
    }
    pickerDelegate = delegate
    picker.delegate = delegate
    presenter.present(picker, animated: true)
  }

  // MARK: - 2. Keep it across restarts

  /// Turns the picked folder into a bookmark and stores it.
  ///
  /// The access has to be open while the bookmark is made — the URL the picker hands over is
  /// security-scoped, and a bookmark taken outside the scope resolves to nothing later.
  private func remember(_ url: URL) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    // `.withSecurityScope` is a macOS option; on iOS a bookmark of a picked URL is
    // security-scoped by construction.
    let data = try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    defaults.set(data, forKey: Self.bookmarkKey)
  }

  /// Resolves the stored bookmark, refreshing it when the system says it went stale.
  ///
  /// Callers get the URL with its security scope already open and are responsible for closing it,
  /// which is what `withFolder` does for them.
  private func resolve() throws -> (url: URL, wasStale: Bool) {
    guard let data = defaults.data(forKey: Self.bookmarkKey) else {
      throw Failure("no folder has been picked yet")
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      if let fresh = try? url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        defaults.set(fresh, forKey: Self.bookmarkKey)
      }
    }
    return (url, stale)
  }

  private func withFolder<T>(_ body: (URL, Bool) throws -> T) throws -> T {
    let (url, wasStale) = try resolve()
    guard url.startAccessingSecurityScopedResource() else {
      throw Failure("the bookmark resolved but the permission is gone")
    }
    defer { url.stopAccessingSecurityScopedResource() }
    return try body(url, wasStale)
  }

  private func status() throws -> [String: Any] {
    guard defaults.data(forKey: Self.bookmarkKey) != nil else {
      return ["saved": false]
    }
    return try withFolder { url, wasStale in
      [
        "saved": true,
        "path": url.path,
        "name": url.lastPathComponent,
        "wasStale": wasStale,
        "reachable": (try? url.checkResourceIsReachable()) ?? false,
      ]
    }
  }

  // MARK: - 3. Read what is not on the device

  private static let entryKeys: [URLResourceKey] = [
    .fileSizeKey, .isDirectoryKey, .isUbiquitousItemKey,
    .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey,
  ]

  private func list() throws -> [String: Any] {
    try withFolder { url, wasStale in
      var found: [[String: Any]] = []
      try coordinatedRead(url) { dir in
        let urls = try FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: Self.entryKeys, options: [.skipsHiddenFiles])
        found = urls.map(Self.describe)
      }
      return ["path": url.path, "wasStale": wasStale, "entries": found]
    }
  }

  /// Reads one file out of the folder and reports whether it had to be fetched first.
  ///
  /// [statusBefore] is the half that matters: bytes coming back for an item the device was not
  /// holding is the requirement. The after-sample lags — it still reads `notDownloaded` on a read
  /// that has just handed over every byte, and only turns `current` some time later — so it is
  /// reported as an observation, not used as the proof.
  private func read(name: String) throws -> [String: Any] {
    try withFolder { folder, _ in
      let file = folder.appendingPathComponent(name)
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

/// `UIDocumentPickerDelegate` in the shape the one call site needs: one URL or nothing, once.
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
  private let onFinish: (URL?) -> Void

  init(onFinish: @escaping (URL?) -> Void) {
    self.onFinish = onFinish
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    onFinish(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    onFinish(nil)
  }
}

private struct Failure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
