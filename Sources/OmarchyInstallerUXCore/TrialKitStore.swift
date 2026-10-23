#if os(macOS)
  import Darwin
  import Foundation

  /// The kits this installer fetched, in its own folder under Application
  /// Support. Each kit unpacks into a folder of its own, and the `current`
  /// link names the one in use; switching kits replaces the link in one
  /// rename. `incoming` holds a download until it is checked, and
  /// `last-check.json` when the releases were last asked.
  public struct TrialKitStore: Sendable {
    public static let folderName = "Try kits"
    public static let pointerName = "current"
    static let incomingName = "incoming"
    static let checkName = "last-check.json"
    static let kitPrefix = "kit-"

    public let directory: URL

    public init(directory: URL) {
      self.directory = directory
    }

    /// `<Application Support>/<workspace>/Try kits`, beside the installer's
    /// own state.
    public static func under(applicationSupport: URL, workspace: String) -> Self {
      Self(
        directory:
          applicationSupport
          .appendingPathComponent(workspace, isDirectory: true)
          .appendingPathComponent(folderName, isDirectory: true))
    }

    private var pointer: URL { directory.appendingPathComponent(Self.pointerName) }
    var incoming: URL { directory.appendingPathComponent(Self.incomingName, isDirectory: true) }
    private var checkRecord: URL { directory.appendingPathComponent(Self.checkName) }

    public func current() -> TrialKitLayout? {
      guard let name = currentName() else { return nil }
      return TrialKitLayout(root: directory.appendingPathComponent(name, isDirectory: true))
    }

    func currentName() -> String? {
      guard isPlainFolder(directory),
        let name = try? FileManager.default.destinationOfSymbolicLink(atPath: pointer.path),
        Self.isKitName(name), isPlainFolder(directory.appendingPathComponent(name))
      else { return nil }
      return name
    }

    static func isKitName(_ name: String) -> Bool {
      name.hasPrefix(kitPrefix) && name.count <= 128
        && name.utf8.allSatisfy {
          $0.isASCIILetterOrDigit || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
        }
        && !name.contains("..")
    }

    func freshIncoming() throws -> URL {
      try createFolder()
      try? FileManager.default.removeItem(at: incoming)
      try FileManager.default.createDirectory(
        at: incoming, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return incoming
    }

    func adopt(_ unpacked: URL, version: String) throws -> TrialKitLayout {
      let suffix = UUID().uuidString.prefix(8).lowercased()
      let name = "\(Self.kitPrefix)\(version)-\(suffix)"
      guard Self.isKitName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
      let destination = directory.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.moveItem(at: unpacked, to: destination)
      let next = directory.appendingPathComponent(Self.pointerName + ".next")
      try? FileManager.default.removeItem(at: next)
      guard symlink(name, next.path) == 0, rename(next.path, pointer.path) == 0 else {
        try? FileManager.default.removeItem(at: next)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return TrialKitLayout(root: destination)
    }

    /// Removes every fetched kit but the named ones, and any download left
    /// in `incoming`.
    func removeKits(keeping kept: Set<String>) {
      guard isPlainFolder(directory),
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else { return }
      for name in names where name.hasPrefix(Self.kitPrefix) && !kept.contains(name) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
      }
      try? FileManager.default.removeItem(at: incoming)
    }

    public func lastCheck() -> Date? {
      var information = stat()
      guard lstat(checkRecord.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
        information.st_size <= 1_024, let data = try? Data(contentsOf: checkRecord),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let text = object["checkedAt"] as? String
      else { return nil }
      return ISO8601DateFormatter().date(from: text)
    }

    func recordCheck(at date: Date) throws {
      try createFolder()
      let data = try JSONSerialization.data(
        withJSONObject: ["format": 1, "checkedAt": ISO8601DateFormatter().string(from: date)],
        options: [.sortedKeys])
      try data.write(to: checkRecord, options: .atomic)
    }

    /// The folder and the workspace above it, private to this user, and
    /// never a link.
    func createFolder() throws {
      let workspace = directory.deletingLastPathComponent()
      for folder in [workspace, directory] {
        if !FileManager.default.fileExists(atPath: folder.path) {
          try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: folder == workspace,
            attributes: [.posixPermissions: 0o700])
        }
        guard isPlainFolder(folder) else { throw CocoaError(.fileWriteNoPermission) }
      }
    }

    private func isPlainFolder(_ url: URL) -> Bool {
      var information = stat()
      return lstat(url.path, &information) == 0 && information.st_mode & S_IFMT == S_IFDIR
    }
  }

  extension UInt8 {
    fileprivate var isASCIILetterOrDigit: Bool {
      (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
    }
  }
#endif
