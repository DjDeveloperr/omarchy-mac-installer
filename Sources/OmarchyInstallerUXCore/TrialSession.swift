#if os(macOS)
  import Foundation
  import Observation
  import TryOmarchyKitClient

  /// What Try needs from this Mac and the embedded Try Omarchy kit.
  @MainActor
  public protocol TrialEnvironment: AnyObject {
    /// Whether this build embeds the kit. Without it there is no Try.
    var isAvailable: Bool { get }
    func space() -> TrialSpace
    /// The space the VM's folder takes on disk, or zero without one.
    func vmBytes() async -> Int64
    func permissions() -> TrialPermissions
    func requestAccessibility()
    func requestMicrophone() async
    func requestCamera() async
    func start(onEvent: @escaping @MainActor (VMRunEvent) -> Void) throws
    func shutDown()
    /// Moves the VM in the default folder to the Trash.
    func deleteVM() throws
  }

  public struct TrialSpace: Equatable, Sendable {
    public let requiredBytes: Int64
    public let freeBytes: Int64?
    /// A VM already exists, so starting downloads nothing.
    public let hasVM: Bool

    public init(requiredBytes: Int64, freeBytes: Int64?, hasVM: Bool) {
      self.requiredBytes = requiredBytes
      self.freeBytes = freeBytes
      self.hasVM = hasVM
    }

    public var isEnough: Bool { (freeBytes ?? 0) >= requiredBytes }
  }

  public enum TrialPermissionState: Equatable, Sendable {
    case allowed
    case notAsked
    /// Refused or restricted; only System Settings can change it now.
    case refused
  }

  public struct TrialPermissions: Equatable, Sendable {
    public var accessibility: TrialPermissionState
    public var microphone: TrialPermissionState
    public var camera: TrialPermissionState

    public init(
      accessibility: TrialPermissionState, microphone: TrialPermissionState,
      camera: TrialPermissionState
    ) {
      self.accessibility = accessibility
      self.microphone = microphone
      self.camera = camera
    }

    public var allAllowed: Bool {
      accessibility == .allowed && microphone == .allowed && camera == .allowed
    }
  }

  public struct TrialProgress: Equatable, Sendable {
    public let phase: VMRunPhase
    public let percent: Int?

    public init(phase: VMRunPhase, percent: Int?) {
      self.phase = phase
      self.percent = percent
    }

    public var title: String { PlainLanguage.trialProgressTitle(phase) }
    public var fraction: Double? { percent.map { Double($0) / 100 } }
  }

  public struct TrialFailure: Equatable, Sendable {
    public let code: VMRunErrorCode
    public let headline: String
    public let detail: String
    public let technicalDetail: String?
  }

  public enum TrialPhase: Equatable, Sendable {
    /// The installer's own page: the choice, the plan, the install.
    case hidden
    /// The Try page: permissions and space, before anything starts.
    case ready(TrialSpace, TrialPermissions)
    case starting(TrialProgress)
    /// Omarchy runs in its own window. A permission granted now applies at
    /// the next start.
    case running(TrialPermissions)
    case stopping
    case failed(TrialFailure)
  }

  /// What the installer found it can do on this Mac, which decides where Try
  /// sits: one of two modes, or the only one.
  public enum TrialInstallStatus: Equatable, Sendable {
    case checking
    /// Install is on offer, so the first page is the choice.
    case supported
    /// Omarchy can't be installed on this Mac, and Try is the only mode.
    case unsupported(FailureDisplay)
    /// Omarchy is installed natively, and Try is the only mode.
    case installed
    /// An install waits for its Recovery step, whose steps take the page.
    case finishingInstall
    /// The installer's own page has the floor: the plan, the install or a
    /// failure.
    case installerPage

    public init(_ phase: InstallerSessionPhase, isBusy: Bool, pendingRecovery: Bool) {
      switch phase {
      case .inspecting:
        self = .checking
      case .welcome:
        self = .supported
      case .unsupported(let failure):
        self = .unsupported(failure)
      case .existingInstallRefused:
        // The inspection is still looking for an unfinished Recovery step.
        if isBusy {
          self = .checking
        } else {
          self = pendingRecovery ? .finishingInstall : .installed
        }
      default:
        self = .installerPage
      }
    }
  }

  extension InstallerSession {
    public var trialInstallStatus: TrialInstallStatus {
      TrialInstallStatus(
        phase, isBusy: isBusy, pendingRecovery: recoveryAccount?.target != nil)
    }
  }

  /// Why Install on this Mac can't go ahead, for the menu item.
  public struct TrialInstallReason: Equatable, Sendable {
    public let headline: String
    public let detail: String
    public let canCheckAgain: Bool
  }

  public enum TrialInstallMenuAction: Equatable, Sendable {
    case unavailable
    case install
    case explain(TrialInstallReason)
  }

  /// Try as one state machine beside the installer's session. Omarchy runs in
  /// its own window; this tracks it, shuts it down and deletes its VM.
  @MainActor
  @Observable
  public final class TrialSession {
    public private(set) var phase: TrialPhase = .hidden
    public private(set) var installStatus: TrialInstallStatus = .checking
    /// A VM exists in the default folder: the remembered choice.
    public private(set) var hasVM = false
    /// The space the VM takes, for the plan review.
    public private(set) var vmBytes: Int64 = 0
    private let environment: any TrialEnvironment
    private var lastError: VMRunError?
    private var shutdownRequested = false
    private var afterExit: [() -> Void] = []
    private var launched = false
    private var vmBytesRefresh: Task<Void, Never>?
    /// Try opened on its own because the Mac can't install, so it steps
    /// aside if a new check finds that it can.
    private var openedAsOnlyMode = false

    public init(environment: any TrialEnvironment) {
      self.environment = environment
      hasVM = environment.isAvailable && environment.space().hasVM
    }

    public var isAvailable: Bool { environment.isAvailable }

    public var entryTitle: String { PlainLanguage.trialEntry }

    /// Omarchy is starting, running or shutting down.
    public var isActive: Bool {
      switch phase {
      case .starting, .running, .stopping: true
      case .hidden, .ready, .failed: false
      }
    }

    public var canStart: Bool {
      guard case .ready(let space, _) = phase else { return false }
      return space.isEnough
    }

    public var startTitle: String {
      guard case .ready(let space, _) = phase, space.hasVM else {
        return PlainLanguage.trialDownloadAndStart
      }
      return PlainLanguage.trialStart
    }

    /// The Try page goes back to the choice page only while there is one: on
    /// a Mac Omarchy can be installed on, before a VM exists.
    public var canGoBack: Bool {
      guard case .ready = phase else { return true }
      return installStatus == .supported && !hasVM
    }

    /// Install on this Mac, beside Shut Down on the running page.
    public var canInstall: Bool { installStatus == .supported }

    public var canDeleteVM: Bool { environment.isAvailable && hasVM && !isActive }

    /// The line under the Mac's name while Try is the only mode.
    public var installLine: String? { PlainLanguage.trialInstallLine(installStatus) }

    /// Omarchy started before the inspection found an install waiting for its
    /// Recovery step. The steps appear once Omarchy shuts down.
    public var finishInstallAfterShutDown: Bool {
      installStatus == .finishingInstall && isActive
    }

    public var installMenuAction: TrialInstallMenuAction {
      switch installStatus {
      case .checking, .finishingInstall, .installerPage: .unavailable
      case .supported: .install
      case .unsupported(let failure):
        .explain(
          TrialInstallReason(
            headline: failure.headline,
            detail: [failure.plainDetail, failure.remedy].compactMap { $0 }.joined(
              separator: " "),
            canCheckAgain: true))
      case .installed:
        .explain(
          TrialInstallReason(
            headline: PlainLanguage.existingInstallHeadline,
            detail: PlainLanguage.trialInstalledDetail, canCheckAgain: false))
      }
    }

    /// The remembered choice: with a VM in the default folder, the app opens
    /// into Try and starts Omarchy at once, while the installer inspects the
    /// Mac in the background. Runs once per launch.
    public func openAtLaunch() {
      guard !launched else { return }
      launched = true
      guard environment.isAvailable, phase == .hidden else { return }
      let space = environment.space()
      noteVM(space.hasVM)
      guard space.hasVM else { return }
      phase = .ready(space, environment.permissions())
      start()
    }

    /// Follows the installer's inspection. On a Mac that can't install, and
    /// on one with Omarchy installed, the Try page opens at once.
    public func follow(_ status: TrialInstallStatus) {
      installStatus = status
      guard environment.isAvailable, !isActive else { return }
      switch status {
      case .unsupported, .installed:
        if phase == .hidden {
          present()
          openedAsOnlyMode = true
        }
      case .supported:
        if openedAsOnlyMode, !hasVM, case .ready = phase {
          openedAsOnlyMode = false
          phase = .hidden
        }
      case .finishingInstall, .installerPage:
        if phase != .hidden {
          openedAsOnlyMode = false
          phase = .hidden
        }
      case .checking:
        break
      }
    }

    public func present() {
      guard environment.isAvailable, phase == .hidden else { return }
      openedAsOnlyMode = false
      phase = readyPhase()
    }

    /// Back: from a failure to the Try page, or to the installer's page when
    /// it needs the floor, and from the Try page to the choice page when there
    /// is one.
    public func dismiss() {
      switch phase {
      case .failed:
        phase = installerNeedsPage ? .hidden : readyPhase()
      case .ready where canGoBack:
        phase = .hidden
      default:
        break
      }
    }

    /// Re-reads permissions and space, as when the app becomes active again
    /// after System Settings.
    public func refresh() {
      switch phase {
      case .ready:
        phase = readyPhase()
      case .running:
        phase = .running(environment.permissions())
      default:
        if !isActive { noteVM(environment.isAvailable && environment.space().hasVM) }
      }
    }

    public func refreshVMBytes() async {
      vmBytes = await environment.vmBytes()
    }

    /// Waits for the last refresh of the VM's size, for tests.
    func settled() async {
      await vmBytesRefresh?.value
    }

    private func noteVM(_ exists: Bool) {
      hasVM = exists
      guard exists else { return }
      vmBytesRefresh = Task { await refreshVMBytes() }
    }

    public func requestAccessibility() {
      environment.requestAccessibility()
      refresh()
    }

    public func requestMicrophone() async {
      await environment.requestMicrophone()
      refresh()
    }

    public func requestCamera() async {
      await environment.requestCamera()
      refresh()
    }

    public func start() {
      guard canStart else { return }
      lastError = nil
      shutdownRequested = false
      phase = .starting(TrialProgress(phase: .checking, percent: nil))
      do {
        try environment.start { [weak self] event in self?.receive(event) }
      } catch {
        phase = .failed(Self.failure(for: error))
      }
    }

    /// Shuts Omarchy down; `then` runs once it has stopped, or at once when
    /// nothing is running.
    public func shutDown(then completion: (() -> Void)? = nil) {
      guard isActive else {
        completion?()
        return
      }
      if let completion { afterExit.append(completion) }
      guard !shutdownRequested else { return }
      shutdownRequested = true
      phase = .stopping
      environment.shutDown()
    }

    /// Install on this Mac: shuts Omarchy down if it runs, leaves Try, then
    /// continues into the installer's plan.
    public func leaveForInstall(then install: @escaping () -> Void) {
      guard canInstall else { return }
      shutDown { [weak self] in
        guard let self else { return }
        openedAsOnlyMode = false
        phase = .hidden
        install()
      }
    }

    /// The confirmation's words, naming the space the VM takes.
    public func deletionMessage() async -> String {
      await refreshVMBytes()
      return PlainLanguage.trialDeleteMessage(bytes: vmBytes)
    }

    /// Moves the VM to the Trash and returns to the first launch: the choice
    /// page, or the Try page on a Mac that can't install.
    public func deleteVM() throws {
      guard canDeleteVM else { return }
      try environment.deleteVM()
      hasVM = false
      vmBytes = 0
      openedAsOnlyMode = false
      phase = .hidden
      follow(installStatus)
    }

    func receive(_ event: VMRunEvent) {
      switch event {
      case .progress(let step, let percent):
        if case .starting = phase {
          phase = .starting(TrialProgress(phase: step, percent: percent))
        }
      case .notice:
        break
      case .ready:
        if !shutdownRequested { phase = .running(environment.permissions()) }
      case .stopping:
        phase = .stopping
      case .error(let error):
        lastError = error
      case .exited(let status):
        if let lastError {
          phase = .failed(Self.failure(for: lastError))
        } else if status != 0 && !shutdownRequested {
          phase = .failed(
            Self.failure(
              for: VMRunError(code: .qemuExited, message: "Omarchy stopped (status \(status)).")))
        } else {
          phase = restingPhase()
        }
        lastError = nil
        shutdownRequested = false
        let completions = afterExit
        afterExit = []
        for completion in completions { completion() }
        vmBytesRefresh = Task { await refreshVMBytes() }
      }
    }

    private func readyPhase() -> TrialPhase {
      let space = environment.space()
      noteVM(space.hasVM)
      return .ready(space, environment.permissions())
    }

    /// Where Try rests once Omarchy has shut down: the Try page while Try is
    /// the only mode or a VM is the remembered choice, else the choice page.
    private func restingPhase() -> TrialPhase {
      let ready = readyPhase()
      switch installStatus {
      case .unsupported, .installed: return ready
      case .finishingInstall, .installerPage: return .hidden
      case .supported, .checking: return hasVM ? ready : .hidden
      }
    }

    /// The Recovery steps of an unfinished install, or the installer's plan,
    /// take the page whenever Omarchy isn't running.
    private var installerNeedsPage: Bool {
      installStatus == .finishingInstall || installStatus == .installerPage
    }

    static func failure(for error: Error) -> TrialFailure {
      let runError =
        error as? VMRunError ?? VMRunError(code: .launchFailed, message: error.localizedDescription)
      let words = PlainLanguage.trialFailure(runError.code)
      return TrialFailure(
        code: runError.code, headline: words.headline, detail: words.detail,
        technicalDetail: runError.message)
    }
  }
#endif
