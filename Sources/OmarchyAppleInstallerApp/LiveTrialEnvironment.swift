import AVFoundation
import AppKit
import ApplicationServices
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import TryOmarchyKitClient

/// Try on this Mac: the kit in Contents/Helpers, this app's own permissions,
/// and the default VM folder it shares with Try Omarchy.
@MainActor
final class LiveTrialEnvironment: TrialEnvironment {
  private let kit = TryOmarchyKit.embedded()
  private lazy var client = VMRunClient(kit: kit)

  var isAvailable: Bool { (try? kit.helperURL()) != nil }

  func space() -> TrialSpace {
    guard let root = TryOmarchyStorage.defaultRoot() else {
      return TrialSpace(
        requiredBytes: TryOmarchyStorage.requiredFreeBytesForNewVM, freeBytes: nil, hasVM: false)
    }
    return TrialSpace(
      requiredBytes: TryOmarchyStorage.requiredFreeBytes(at: root),
      freeBytes: TryOmarchyStorage.freeBytes(at: root),
      hasVM: TryOmarchyStorage.hasVM(at: root))
  }

  func vmBytes() async -> Int64 {
    guard let root = TryOmarchyStorage.defaultRoot() else { return 0 }
    return await Task.detached(priority: .utility) {
      TryOmarchyStorage.allocatedBytes(at: root)
    }.value
  }

  func permissions() -> TrialPermissions {
    TrialPermissions(
      accessibility: AXIsProcessTrusted() ? .allowed : .notAsked,
      microphone: Self.state(AVCaptureDevice.authorizationStatus(for: .audio)),
      camera: Self.state(AVCaptureDevice.authorizationStatus(for: .video)))
  }

  /// macOS shows its own prompt once, then only System Settings can grant it.
  func requestAccessibility() {
    // The value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as mutable.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if let settings = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(settings)
    }
  }

  func requestMicrophone() async { await Self.request(.audio, settings: "Privacy_Microphone") }

  func requestCamera() async { await Self.request(.video, settings: "Privacy_Camera") }

  func start(onEvent: @escaping @MainActor (VMRunEvent) -> Void) throws {
    if let failure = VMRunClient.preflight() { throw failure }
    // The main queue keeps the events in the order the client delivers them.
    try client.start(VMRunConfiguration(productName: InstallerProductIdentity.appName)) { event in
      DispatchQueue.main.async { onEvent(event) }
    }
  }

  func shutDown() { client.shutDown() }

  func deleteVM() throws {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first,
      TrialVMFolder.root(under: support).standardizedFileURL
        == TryOmarchyStorage.defaultRoot()?.standardizedFileURL
    else { throw TrialVMFolder.Refusal.notTheDefaultFolder }
    try TrialVMFolder.trash(under: support)
  }

  private static func state(_ status: AVAuthorizationStatus) -> TrialPermissionState {
    switch status {
    case .authorized: .allowed
    case .notDetermined: .notAsked
    default: .refused
    }
  }

  private static func request(_ media: AVMediaType, settings pane: String) async {
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .notDetermined:
      _ = await AVCaptureDevice.requestAccess(for: media)
    case .authorized:
      break
    default:
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
      }
    }
  }
}
