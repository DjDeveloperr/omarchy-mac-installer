#if os(macOS)
  import Foundation
  import TryOmarchyKitClient

  extension PlainLanguage {
    // MARK: Try — Omarchy in a VM

    public static let trialEntry = "Try in a VM"
    public static let trialHeadline = "Try Omarchy in a VM"
    public static let trialSubheadline =
      "Omarchy runs in a virtual machine, in a window beside macOS, without changing your disk. When it first starts, it asks for your account, keyboard and time zone."
    public static let trialReadySubheadline =
      "Omarchy is set up and ready. It opens in a window beside macOS, with everything saved in its virtual machine."
    public static let trialChosenFolderSubheadline =
      "Omarchy is set up in the folder chosen in Try Omarchy. It opens in a window beside macOS, with everything saved in its virtual machine."
    public static let trialPermissionsNote =
      "Each permission is optional. Omarchy starts without them."
    public static let trialAccessibility = "Use ⌘ as the Super key"
    public static let trialMicrophone = "Microphone"
    public static let trialCamera = "Camera"
    public static let trialAllow = "Allow"
    public static let trialFinishInstall =
      "Omarchy’s installation on this Mac isn’t finished. Shut Omarchy down to see the steps to finish it in Recovery."
    public static let trialAllowed = "Allowed"
    public static let trialOpenSettings = "Open Settings"
    public static let trialDownloadAndStart = "Download and start"
    public static let trialStart = "Start"
    public static let trialBack = "Back"
    public static let trialTryAgain = "Try Again"
    public static let trialRunningHeadline = "Omarchy is running"
    public static let trialRunningDetail =
      "Omarchy is in its own window. Shut it down here, or from Omarchy's own menu."
    public static let trialShutDown = "Shut Down"
    public static let trialStoppingHeadline = "Shutting down Omarchy…"
    public static let trialStoppingDetail =
      "Omarchy is closing its apps. If it hasn’t stopped within a minute, it’s stopped for you."
    public static let trialInstall = "Install on this Mac"
    public static let trialChoiceDetail =
      "Or try it first in a virtual machine, in a window beside macOS, without changing your disk."
    public static let trialPermissionsNextStart =
      "A permission you allow now takes effect the next time Omarchy starts."
    public static let trialInstalledLine = "Omarchy is already installed on this Mac."
    public static let trialInstalledDetail =
      "To install it again, first remove it: choose Installation → Remove Omarchy… in the menu bar."

    // MARK: Try — the Installation menu

    public static let trialInstallMenuItem = "Install on this Mac…"
    public static let trialCheckAgainMenuItem = checkAgain
    public static let trialDeleteMenuItem = "Delete Virtual Machine…"
    public static let trialDeleteTitle = "Delete the virtual machine?"
    public static let trialDeleteAction = "Move to Trash"
    public static let trialDeleteFailed = "The virtual machine couldn’t be deleted"
    public static let trialDeleteMovedLine =
      "This virtual machine is in a folder chosen in Try Omarchy. Manage it from Try Omarchy or the Finder."
    public static let trialRepairBridgedNetworkMenuItem = "Repair Bridged Networking"
    public static let trialRemoveBridgedNetworkMenuItem = "Remove Bridged Networking"

    // MARK: Try — bridged networking

    public static func trialBridgedNetworkLine(_ state: TrialBridgedNetwork) -> String {
      switch state {
      case .notRegistered:
        "Omarchy is using shared networking, because bridged networking isn’t set up. Set it up, and the next start uses it."
      case .needsApproval:
        "Omarchy is using shared networking. Bridged networking waits for you to allow it in System Settings, under Login Items."
      case .enabled:
        "Omarchy is using shared networking, because bridged networking didn’t answer. Repairing it shuts Omarchy down."
      }
    }

    public static func trialBridgedNetworkAction(_ state: TrialBridgedNetwork) -> String {
      switch state {
      case .notRegistered: "Set Up Bridged Networking"
      case .needsApproval: "Open Login Items"
      case .enabled: "Repair"
      }
    }

    public static let trialBridgedNetworkFetchedKitLine =
      "Omarchy is using shared networking. Bridged networking works only with the virtual machine this app came with, until the next update of this app."

    public static func trialBridgedNetworkChangeTitle(removing: Bool) -> String {
      removing ? "Remove bridged networking?" : "Repair bridged networking?"
    }

    public static func trialBridgedNetworkChangeAction(removing: Bool) -> String {
      removing ? "Remove" : "Repair"
    }

    public static func trialBridgedNetworkChangeMessage(removing: Bool, shutsDown: Bool) -> String {
      let change =
        removing
        ? "Omarchy uses shared networking from its next start."
        : "Bridged networking is set up again, and the next start uses it."
      return shutsDown ? "Omarchy shuts down first. \(change)" : change
    }

    public static func trialBridgedNetworkFailed(_ reason: String) -> String {
      "Bridged networking couldn’t be changed: \(reason)"
    }

    public static func trialDeleteMessage(bytes: Int64) -> String {
      let frees =
        bytes >= 100_000_000
        ? " Emptying the Trash frees up to \(gigabytes(bytes))." : ""
      return
        "Omarchy’s virtual machine, with everything saved in it, moves to the Trash.\(frees) The next start downloads Omarchy again."
    }

    /// The line under the Mac's name while Try is the only mode.
    public static func trialInstallLine(_ status: TrialInstallStatus) -> String? {
      switch status {
      case .unsupported(let failure):
        if failure.isBlockedModel { return "Omarchy can’t be installed on this Mac model yet." }
        if failure.headline == notReadyHeadline {
          return "Omarchy can’t be installed on this Mac right now."
        }
        return failure.headline
      case .installed:
        return trialInstalledLine
      case .checking, .supported, .finishingInstall, .installerPage:
        return nil
      }
    }

    public static func trialSpace(_ space: TrialSpace) -> String {
      switch space.missingFolder {
      case .disconnectedDrive:
        return
          "Omarchy’s virtual machine is on a drive that isn’t connected. Connect it, then start again."
      case .removed:
        return
          "Omarchy’s virtual machine isn’t in the folder chosen in Try Omarchy. Put the folder back, or choose another in Try Omarchy."
      case nil:
        break
      }
      let required = gigabytes(space.requiredBytes)
      guard let free = space.freeBytes else {
        return "Omarchy needs \(required) of free space."
      }
      return space.hasVM
        ? "\(gigabytes(free)) is free on the disk that holds Omarchy’s virtual machine."
        : "Omarchy needs \(required) of free space for its download and disk. \(gigabytes(free)) is free."
    }

    public static func trialSpaceShortfall(_ space: TrialSpace) -> String {
      "Free up \(gigabytes(space.requiredBytes - (space.freeBytes ?? 0))) more to try Omarchy."
    }

    /// The plan review's note on the VM, which the native install leaves in
    /// place.
    public static func trialDiskNotice(bytes: Int64, root: TrialVMRoot?) -> String? {
      guard bytes >= 100_000_000 else { return nil }
      guard root?.sharesMacOSVolume != false else {
        return
          "Omarchy’s virtual machine is on another disk, in the folder chosen in Try Omarchy. Installing keeps it."
      }
      let place =
        root?.isDefault == false
        ? "in the folder chosen in Try Omarchy" : "in Application Support › Try Omarchy"
      return
        "Omarchy’s virtual machine uses up to \(gigabytes(bytes)) of macOS’s space, already counted above. Installing keeps it, \(place)."
    }

    public static func trialProgressTitle(_ phase: VMRunPhase) -> String {
      switch phase {
      case .waitingForDownload: "Waiting for another download"
      case .downloading: "Downloading Omarchy"
      case .reconnecting: "Reconnecting"
      case .paused: "Waiting for Wi-Fi or Ethernet"
      case .verifyingDownload: "Verifying the download"
      case .checking: "Checking the virtual machine"
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
        ("Omarchy’s folder isn’t on an APFS disk", "The virtual machine needs APFS for its disk.")
      case .macOSTooOld:
        ("This Mac needs a newer macOS", "Omarchy’s virtual machine needs macOS 15 or newer.")
      case .hypervisorUnavailable:
        (
          "This Mac can’t run Omarchy in a virtual machine",
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
          "This virtual machine was made by a newer version",
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
