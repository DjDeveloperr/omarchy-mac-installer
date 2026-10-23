#if os(macOS)
  import Darwin
  import Foundation

  /// Records in this app's own folder under Application Support that Omarchy
  /// has started from it, so later launches start a VM at once.
  public struct TrialStartRecord: Sendable {
    public static let fileName = "Try started"
    public let file: URL

    public init(file: URL) {
      self.file = file
    }

    public static func under(applicationSupport: URL, workspace: String) -> Self {
      Self(
        file:
          applicationSupport
          .appendingPathComponent(workspace, isDirectory: true)
          .appendingPathComponent(fileName, isDirectory: false))
    }

    public var exists: Bool {
      var information = stat()
      return lstat(file.path, &information) == 0 && information.st_mode & S_IFMT == S_IFREG
    }

    public func record() throws {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: file, options: .atomic)
    }
  }
#endif
