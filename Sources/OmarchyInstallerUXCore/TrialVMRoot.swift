#if os(macOS)
  import Darwin
  import Foundation
  import TryOmarchyKitClient

  /// Why a folder chosen in Try Omarchy isn't there.
  public enum TrialMissingFolder: Equatable, Sendable {
    /// It is on a drive under /Volumes that isn't connected.
    case disconnectedDrive
    case removed
  }

  /// The folder that holds the VM, as Try Omarchy resolves it: the default
  /// folder, or one the person moved it to in Try Omarchy.
  public struct TrialVMRoot: Equatable, Sendable {
    public let url: URL
    /// The default folder, the only one Delete Virtual Machine moves.
    public let isDefault: Bool
    /// On the volume of the default folder, whose space the install plan
    /// shares with macOS.
    public let sharesMacOSVolume: Bool
    /// A chosen folder that isn't there. The default folder is never missing:
    /// the first start makes it.
    public let missing: TrialMissingFolder?

    public init(
      url: URL, isDefault: Bool, sharesMacOSVolume: Bool, missing: TrialMissingFolder? = nil
    ) {
      self.url = url
      self.isDefault = isDefault
      self.sharesMacOSVolume = sharesMacOSVolume
      self.missing = missing
    }

    /// Compares the folder with the default one, and their volumes through
    /// the nearest folder of each that exists.
    public static func resolved(_ url: URL, defaultRoot: URL?) -> Self {
      let isDefault =
        defaultRoot.map { url.standardizedFileURL.path == $0.standardizedFileURL.path } ?? false
      let missing = isDefault ? nil : Self.missing(url)
      guard let defaultRoot, missing == nil else {
        return Self(url: url, isDefault: isDefault, sharesMacOSVolume: false, missing: missing)
      }
      let device = Self.device(of: url)
      return Self(
        url: url, isDefault: isDefault,
        sharesMacOSVolume: isDefault || (device != nil && device == Self.device(of: defaultRoot)))
    }

    static func missing(_ url: URL, volumes: URL = URL(fileURLWithPath: "/Volumes"))
      -> TrialMissingFolder?
    {
      let folder = url.standardizedFileURL
      var information = stat()
      if lstat(folder.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR {
        return nil
      }
      let parts = folder.pathComponents
      let base = volumes.standardizedFileURL.pathComponents
      guard parts.count > base.count, Array(parts.prefix(base.count)) == base else {
        return .removed
      }
      let drive = volumes.appendingPathComponent(parts[base.count], isDirectory: true)
      return lstat(drive.path, &information) == 0 ? .removed : .disconnectedDrive
    }

    static func device(of url: URL) -> dev_t? {
      var candidate = url.standardizedFileURL
      var information = stat()
      while stat(candidate.path, &information) != 0 {
        guard candidate.path != "/" else { return nil }
        candidate.deleteLastPathComponent()
      }
      return information.st_dev
    }
  }

  /// The free space the header names for macOS's disk and the Try page names
  /// for the VM's: what macOS can make available on the volume, read from
  /// the nearest folder that exists. One reading, so the same disk shows the
  /// same number on both.
  public enum VolumeFreeSpace {
    public static func bytes(at url: URL) -> Int64? { TryOmarchyStorage.freeBytes(at: url) }

    /// The volume macOS and the default VM folder live on.
    public static func macOS() -> UInt64? {
      bytes(at: FileManager.default.homeDirectoryForCurrentUser).map { UInt64(max(0, $0)) }
    }
  }

  extension TrialSpace {
    /// What a start needs in the VM's folder, and what is free on the volume
    /// that holds it or will hold it.
    public static func of(
      _ root: TrialVMRoot?,
      freeBytes: (URL) -> Int64? = { VolumeFreeSpace.bytes(at: $0) }
    ) -> TrialSpace {
      guard let root else {
        return TrialSpace(
          requiredBytes: TryOmarchyStorage.requiredFreeBytesForNewVM, freeBytes: nil, hasVM: false)
      }
      if let missing = root.missing {
        return TrialSpace(
          requiredBytes: TryOmarchyStorage.requiredFreeBytesForExistingVM, freeBytes: nil,
          hasVM: false, missingFolder: missing)
      }
      return TrialSpace(
        requiredBytes: TryOmarchyStorage.requiredFreeBytes(at: root.url),
        freeBytes: freeBytes(root.url), hasVM: TryOmarchyStorage.hasVM(at: root.url))
    }
  }
#endif
