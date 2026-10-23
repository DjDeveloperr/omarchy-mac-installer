#if os(macOS)
  import Foundation
  import TryOmarchyKitClient

  /// Where a kit's parts sit inside the folder it unpacks into: the embedded
  /// kit's `Contents/Helpers`, or a fetched kit's own folder. Every question
  /// about the kit's layout goes through here.
  public struct TrialKitLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
      self.root = root
    }

    public static func embedded(in bundle: Bundle = .main) -> Self {
      Self(root: bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
    }

    public var kit: TryOmarchyKit {
      TryOmarchyKit(
        bundleURL: root.appendingPathComponent(TryOmarchyKit.bundleName, isDirectory: true))
    }

    public var manifestURL: URL { kit.manifestURL }

    public var launcherURL: URL {
      kit.bundleURL.appendingPathComponent(
        "Contents/MacOS/\(TryOmarchyKit.helperName)", isDirectory: false)
    }

    public var hasLauncher: Bool { (try? kit.helperURL()) != nil }

    public func manifest() throws -> TryOmarchyKitManifest { try kit.manifest() }
  }
#endif
