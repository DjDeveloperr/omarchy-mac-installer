#if os(macOS)
  import Foundation
  import TryOmarchyKitClient

  extension PlainLanguage {
    // MARK: Try — Omarchy in a VM

    public static let trialEntry = "Try in a VM"
    public static let trialHeadline = "Try Omarchy in a VM"
    public static let trialSubheadline =
      "Omarchy runs in a virtual machine, in a window beside macOS, without changing your disk. When it first starts, it asks for your account, keyboard and time zone."
    public static let trialPermissionsNote =
      "Each permission is optional. Omarchy starts without them."
    public static let trialAccessibility = "Use ⌘ as the Super key"
    public static let trialMicrophone = "Microphone"
    public static let trialCamera = "Camera"
    public static let trialAllow = "Allow"
    public static let trialAllowed = "Allowed"
    public static let trialOpenSettings = "Open Settings"
    public static let trialDownloadAndStart = "Download and start"
    public static let trialStart = "Start"
    public static let trialBack = "Back"
    public static let trialRunningHeadline = "Omarchy is running"
    public static let trialRunningDetail =
      "Omarchy is in its own window. Shut it down here, or from Omarchy's own menu."
    public static let trialShutDown = "Shut Down"
    public static let trialStoppingHeadline = "Shutting down Omarchy…"
    public static let trialStoppingDetail =
      "Omarchy is closing its apps. If it hasn’t stopped within a minute, it’s stopped for you."
    public static let trialInstall = "Install on this Mac"

    public static func trialSpace(_ space: TrialSpace) -> String {
      let required = gigabytes(space.requiredBytes)
      guard let free = space.freeBytes else {
        return "Omarchy needs \(required) of free space."
      }
      return space.hasVM
        ? "Your Omarchy VM is ready to start. \(gigabytes(free)) is free."
        : "Omarchy needs \(required) of free space for its download and disk. \(gigabytes(free)) is free."
    }

    public static func trialSpaceShortfall(_ space: TrialSpace) -> String {
      "Free up \(gigabytes(space.requiredBytes - (space.freeBytes ?? 0))) more to try Omarchy."
    }

    /// The plan review's note on the VM, which the native install leaves in
    /// place.
    public static func trialDiskNotice(bytes: Int64) -> String? {
      guard bytes >= 100_000_000 else { return nil }
      return
        "Omarchy’s VM uses \(gigabytes(bytes)) of macOS’s space, already counted above. Installing keeps it, in Application Support › Try Omarchy."
    }

    public static func trialProgressTitle(_ phase: VMRunPhase) -> String {
      switch phase {
      case .waitingForDownload: "Waiting for another download"
      case .downloading: "Downloading Omarchy"
      case .reconnecting: "Reconnecting"
      case .paused: "Waiting for Wi-Fi or Ethernet"
      case .verifyingDownload: "Verifying the download"
      case .checking: "Checking the VM"
      case .verifying: "Verifying the Omarchy image"
      case .preparing: "Unpacking Omarchy"
      case .finishing: "Compacting the disk"
      case .starting: "Starting Omarchy"
      }
    }

    public static func trialFailure(_ code: VMRunErrorCode) -> (headline: String, detail: String) {
      switch code {
      case .vmAlreadyOpen:
        (
          "Omarchy is open in Try Omarchy",
          "Or in another copy of \(windowTitle). Shut it down there, then try again here."
        )
      case .volumeNotAPFS:
        ("Omarchy’s folder isn’t on an APFS disk", "The VM needs APFS for its disk.")
      case .macOSTooOld:
        ("This Mac needs a newer macOS", "Omarchy in a VM needs macOS 15 or newer.")
      case .hypervisorUnavailable:
        (
          "This Mac can’t run Omarchy in a VM",
          "It does not offer the virtualization Omarchy needs."
        )
      case .notEnoughSpace:
        ("Not enough free space", "Free up space on this Mac, then try again.")
      case .downloadFailed:
        (
          "Omarchy couldn’t be downloaded",
          "Check the connection and try again. The download continues where it stopped."
        )
      case .imageDigestMismatch:
        ("The download was damaged", "Try again to download it once more.")
      case .storageUnavailable, .storageDisconnected:
        ("Omarchy’s folder isn’t available", "Reconnect its drive, then try again.")
      case .storageLayoutUnknown:
        (
          "This VM was made by a newer version",
          "Update \(windowTitle) to start it."
        )
      case .hostSleepUnavailable, .hostWakeFailed:
        ("Omarchy stopped after this Mac slept", "Start it again to continue.")
      case .qemuExited, .bridgedNetworkUnavailable, .invalidConfiguration, .launchFailed:
        ("Omarchy stopped unexpectedly", "Try starting it again.")
      }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
      String(format: "%.0f GB", max(0, Double(bytes)) / 1_000_000_000)
    }
  }
#endif
