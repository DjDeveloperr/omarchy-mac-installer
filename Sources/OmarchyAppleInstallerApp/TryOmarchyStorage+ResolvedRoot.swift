import Darwin
import Foundation
import TryOmarchyKitClient

/// Stands in for the client's resolver until the vendored client has it.
extension TryOmarchyStorage {
  private static let preferenceKey = "storageLocationPreferences"
  private static let unsafeRoots: Set<String> = [
    "/", "/Users", "/private", "/private/tmp", "/tmp", "/Volumes",
  ]

  /// The folder Try Omarchy chose for the VM: `storage-location.json`, else
  /// Try Omarchy's own preferences, else the default. A choice that can't be
  /// used is nil, never the default.
  static func resolvedRoot(fileManager: FileManager = .default) -> URL? {
    guard
      let folder = defaultRoot(fileManager: fileManager)?
        .deletingLastPathComponent().deletingLastPathComponent()
    else { return nil }
    let choice: Choice
    switch storedChoice(in: folder) {
    case .unusable: return nil
    case .chosen(let stored): choice = stored
    case .absent:
      let legacy = UserDefaults(suiteName: "dev.tryomarchy.native")?.data(forKey: preferenceKey)
      guard let legacy else { return defaultRoot(fileManager: fileManager) }
      guard let decoded = try? JSONDecoder().decode(Choice.self, from: legacy) else { return nil }
      choice = decoded
    }
    guard choice.schemaVersion == 1 else { return nil }
    guard let path = choice.containerPath else { return defaultRoot(fileManager: fileManager) }
    return validated(path)
  }

  private struct Choice: Decodable {
    let schemaVersion: Int
    let containerPath: String?
  }

  private enum Stored {
    case absent
    case unusable
    case chosen(Choice)
  }

  private static func storedChoice(in folder: URL) -> Stored {
    let file = folder.appendingPathComponent("storage-location.json")
    var information = stat()
    guard lstat(file.path, &information) == 0 else { return errno == ENOENT ? .absent : .unusable }
    guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid(),
      information.st_mode & 0o777 == 0o600, information.st_size <= 65_536,
      let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (object["schemaVersion"] as? NSNumber)?.intValue == 1,
      let settings = object["settings"] as? [String: Any]
    else { return .unusable }
    guard let value = settings[preferenceKey] else { return .absent }
    if value is NSNull { return .chosen(Choice(schemaVersion: 1, containerPath: nil)) }
    guard let encoded = try? JSONSerialization.data(withJSONObject: value),
      let choice = try? JSONDecoder().decode(Choice.self, from: encoded)
    else { return .unusable }
    return .chosen(choice)
  }

  private static func validated(_ path: String) -> URL? {
    guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.utf8.contains(0)
    else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var information = stat()
    guard lstat(url.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
      information.st_uid == getuid(),
      !unsafeRoots.contains(url.resolvingSymlinksInPath().path)
    else { return nil }
    return url
  }
}
