#if os(macOS)
  import Foundation
  import Observation
  import TryOmarchyKitClient

  /// What the trial needs from this Mac and the embedded Try Omarchy kit.
  @MainActor
  public protocol TrialEnvironment: AnyObject {
    /// Whether this build embeds the kit. Without it there is no trial.
    var isAvailable: Bool { get }
    /// Once the full app is installed it owns the VM, and the installer opens
    /// it instead of running a trial.
    func fullAppInstalled() -> Bool
    func openFullApp() -> Bool
    func space() -> TrialSpace
    /// The space the trial VM's folder takes on disk, or zero without one.
    func vmBytes() async -> Int64
    func permissions() -> TrialPermissions
    func requestAccessibility()
    func requestMicrophone() async
    func requestCamera() async
    func start(onEvent: @escaping @MainActor (VMRunEvent) -> Void) throws
    func shutDown()
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
    /// The installer's own page.
    case hidden
    /// The Try screen: permissions and space, before anything starts.
    case ready(TrialSpace, TrialPermissions)
    case starting(TrialProgress)
    case running
    case stopping
    case failed(TrialFailure)
  }

  /// The trial as one state machine beside the installer's session. Omarchy
  /// runs in its own window; this tracks it and shuts it down.
  @MainActor
  @Observable
  public final class TrialSession {
    public private(set) var phase: TrialPhase = .hidden
    /// The space the trial VM takes, for the plan review.
    public private(set) var vmBytes: Int64 = 0
    private let environment: any TrialEnvironment
    private var lastError: VMRunError?
    private var shutdownRequested = false
    private var afterExit: [() -> Void] = []

    public init(environment: any TrialEnvironment) {
      self.environment = environment
    }

    public var isAvailable: Bool { environment.isAvailable }

    /// The button on the installer's first page: Try it in a window, or
    /// Open in Try Omarchy once the full app is installed.
    public var entryTitle: String {
      environment.fullAppInstalled() ? PlainLanguage.trialOpenFullApp : PlainLanguage.trialEntry
    }

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

    public func present() {
      guard environment.isAvailable, phase == .hidden else { return }
      if environment.fullAppInstalled() {
        _ = environment.openFullApp()
        return
      }
      phase = .ready(environment.space(), environment.permissions())
    }

    /// Back to the installer's page, from anywhere Omarchy is not running.
    public func dismiss() {
      guard !isActive else { return }
      phase = .hidden
    }

    /// Re-reads permissions and space, as when the installer becomes active
    /// again after System Settings.
    public func refresh() {
      if case .ready = phase {
        phase = .ready(environment.space(), environment.permissions())
      }
    }

    public func refreshVMBytes() async {
      vmBytes = await environment.vmBytes()
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

    func receive(_ event: VMRunEvent) {
      switch event {
      case .progress(let step, let percent):
        if case .starting = phase {
          phase = .starting(TrialProgress(phase: step, percent: percent))
        }
      case .ready:
        if !shutdownRequested { phase = .running }
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
          phase = .hidden
        }
        lastError = nil
        shutdownRequested = false
        let completions = afterExit
        afterExit = []
        for completion in completions { completion() }
        Task { await refreshVMBytes() }
      }
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
