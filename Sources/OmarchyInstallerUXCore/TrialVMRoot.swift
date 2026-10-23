#if os(macOS)
  import Darwin
  import Foundation
  import TryOmarchyKitClient

  /// The folder that holds the VM, as Try Omarchy resolves it: the default
  /// folder, or one the person moved it to in Try Omarchy.
  public struct TrialVMRoot: Equatable, Sendable {
    public let url: URL
    /// The default folder, the only one Delete Virtual Machine moves.
    public let isDefault: Bool
    /// On the volume of the default folder, whose space the install plan
    /// shares with macOS.
    public let sharesMacOSVolume: Bool

    public init(url: URL, isDefault: Bool, sharesMacOSVolume: Bool) {
      self.url = url
      self.isDefault = isDefault
      self.sharesMacOSVolume = sharesMacOSVolume
    }

    /// Compares the folder with the default one, and their volumes through
    /// the nearest folder of each that exists.
    public static func resolved(_ url: URL, defaultRoot: URL?) -> Self {
      guard let defaultRoot else {
        return Self(url: url, isDefault: false, sharesMacOSVolume: false)
      }
      let isDefault = url.standardizedFileURL.path == defaultRoot.standardizedFileURL.path
      let device = Self.device(of: url)
      return Self(
        url: url, isDefault: isDefault,
        sharesMacOSVolume: isDefault || (device != nil && device == Self.device(of: defaultRoot)))
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

  extension TrialSpace {
    /// What a start needs in the VM's folder, and what is free on the volume
    /// that holds it or will hold it.
    public static func of(
      _ root: TrialVMRoot?,
      freeBytes: (URL) -> Int64? = { TryOmarchyStorage.freeBytes(at: $0) }
    ) -> TrialSpace {
      guard let root else {
        return TrialSpace(
          requiredBytes: TryOmarchyStorage.requiredFreeBytesForNewVM, freeBytes: nil, hasVM: false)
      }
      return TrialSpace(
        requiredBytes: TryOmarchyStorage.requiredFreeBytes(at: root.url),
        freeBytes: freeBytes(root.url), hasVM: TryOmarchyStorage.hasVM(at: root.url))
    }
  }
#endif
