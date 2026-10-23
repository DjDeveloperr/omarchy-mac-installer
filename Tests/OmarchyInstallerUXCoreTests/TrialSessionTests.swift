#if os(macOS)
  import Foundation
  import TryOmarchyKitClient
  import XCTest
  @testable import OmarchyInstallerUXCore

  @MainActor
  private final class FakeTrialEnvironment: TrialEnvironment {
    var isAvailable = true
    var currentSpace = TrialSpace(
      requiredBytes: 15_000_000_000, freeBytes: 40_000_000_000, hasVM: false)
    var permissionState = TrialPermissions(
      accessibility: .notAsked, microphone: .notAsked, camera: .refused)
    var startError: Error?
    var deleteError: Error?
    var shutdowns = 0
    var deletions = 0
    var onEvent: (@MainActor (VMRunEvent) -> Void)?
    var network: TrialBridgedNetwork = .notRegistered
    var networkChanges: [String] = []
    var registerError: Error?

    func space() -> TrialSpace { currentSpace }
    func vmBytes() async -> Int64 { 9_400_000_000 }
    func permissions() -> TrialPermissions { permissionState }
    func requestAccessibility() { permissionState.accessibility = .allowed }
    func requestMicrophone() async { permissionState.microphone = .allowed }
    func requestCamera() async {}
    func start(onEvent: @escaping @MainActor (VMRunEvent) -> Void) throws {
      if let startError { throw startError }
      self.onEvent = onEvent
    }
    func shutDown() { shutdowns += 1 }
    func deleteVM() throws {
      if let deleteError { throw deleteError }
      deletions += 1
      currentSpace = TrialSpace(
        requiredBytes: 15_000_000_000, freeBytes: currentSpace.freeBytes, hasVM: false)
    }

    func bridgedNetwork() -> TrialBridgedNetwork { network }
    func registerBridgedNetwork() throws {
      networkChanges.append("register")
      if let registerError { throw registerError }
      network = .needsApproval
    }
    func openBridgedNetworkApproval() { networkChanges.append("open login items") }
    func unregisterBridgedNetwork() async throws {
      networkChanges.append("unregister")
      network = .notRegistered
    }

    func makeVM() {
      currentSpace = TrialSpace(
        requiredBytes: 1_073_741_824, freeBytes: currentSpace.freeBytes, hasVM: true)
    }
  }

  private let tooLittleSpace = FailureDisplay(
    headline: "Free up at least 30 GB to install Omarchy",
    plainDetail: "Omarchy needs 60 GB.", remedy: "Remove files, then choose Check again.")

  @MainActor
  final class TrialSessionTests: XCTestCase {
    private func ready(_ environment: FakeTrialEnvironment) -> TrialSession {
      let trial = TrialSession(environment: environment)
      trial.present()
      return trial
    }

    func testTheTryScreenShowsSpaceAndOptionalPermissions() async {
      let environment = FakeTrialEnvironment()
      let trial = ready(environment)
      XCTAssertEqual(trial.entryTitle, "Try in a VM")
      guard case .ready(let space, let permissions) = trial.phase else {
        return XCTFail("Expected the Try screen")
      }
      XCTAssertTrue(space.isEnough)
      XCTAssertEqual(permissions.camera, .refused)
      XCTAssertTrue(trial.canStart)
      XCTAssertEqual(trial.startTitle, "Download and start")
      trial.requestAccessibility()
      await trial.requestMicrophone()
      guard case .ready(_, let updated) = trial.phase else {
        return XCTFail("Expected the Try screen")
      }
      XCTAssertEqual(updated.accessibility, .allowed)
      XCTAssertEqual(updated.microphone, .allowed)
      trial.follow(.supported)
      XCTAssertTrue(trial.canGoBack)
      trial.dismiss()
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testTooLittleSpaceKeepsStartDisabled() {
      let environment = FakeTrialEnvironment()
      environment.currentSpace = TrialSpace(
        requiredBytes: 15_000_000_000, freeBytes: 10_000_000_000, hasVM: false)
      let trial = ready(environment)
      XCTAssertFalse(trial.canStart)
      trial.start()
      XCTAssertNil(environment.onEvent)
      XCTAssertEqual(
        PlainLanguage.trialSpaceShortfall(environment.currentSpace),
        "Free up 5 GB more to try Omarchy.")
    }

    func testAnExistingVMStartsWithoutADownload() {
      let environment = FakeTrialEnvironment()
      environment.currentSpace = TrialSpace(
        requiredBytes: 1_073_741_824, freeBytes: 5_000_000_000, hasVM: true)
      XCTAssertEqual(ready(environment).startTitle, "Start")
    }

    func testWithoutAKitThereIsNoTrial() {
      let environment = FakeTrialEnvironment()
      environment.isAvailable = false
      let trial = ready(environment)
      XCTAssertFalse(trial.isAvailable)
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testRunsShutsDownAndContinues() throws {
      let environment = FakeTrialEnvironment()
      let trial = ready(environment)
      trial.start()
      let send = try XCTUnwrap(environment.onEvent)
      send(.progress(.downloading, percent: 42))
      XCTAssertEqual(trial.phase, .starting(TrialProgress(phase: .downloading, percent: 42)))
      XCTAssertTrue(trial.isActive)
      send(.ready)
      XCTAssertEqual(trial.phase, .running(environment.permissionState))

      var continued = 0
      trial.shutDown { continued += 1 }
      trial.shutDown { continued += 1 }
      XCTAssertEqual(trial.phase, .stopping)
      XCTAssertEqual(environment.shutdowns, 1)
      send(.stopping)
      send(.exited(status: 0))
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(continued, 2)
      XCTAssertFalse(trial.isActive)

      var immediately = false
      trial.shutDown { immediately = true }
      XCTAssertTrue(immediately)
    }

    func testAnErrorNamesItsCause() throws {
      let environment = FakeTrialEnvironment()
      let trial = ready(environment)
      trial.start()
      let send = try XCTUnwrap(environment.onEvent)
      send(
        .error(VMRunError(code: .vmAlreadyOpen, message: "run-qemu-gpu: this VM is already open")))
      send(.exited(status: 1))
      guard case .failed(let failure) = trial.phase else { return XCTFail("Expected a failure") }
      XCTAssertEqual(failure.code, .vmAlreadyOpen)
      XCTAssertEqual(failure.headline, "Omarchy is open in Try Omarchy")
      XCTAssertEqual(
        failure.detail,
        "Or in another copy of \(PlainLanguage.windowTitle). Shut it down there, then try again here."
      )
      XCTAssertEqual(failure.technicalDetail, "run-qemu-gpu: this VM is already open")
      trial.dismiss()
      guard case .ready = trial.phase else { return XCTFail("Back leads to the Try page") }
    }

    func testAnUnexpectedExitIsAFailure() throws {
      let environment = FakeTrialEnvironment()
      let trial = ready(environment)
      trial.start()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      send(.exited(status: 143))
      guard case .failed(let failure) = trial.phase else { return XCTFail("Expected a failure") }
      XCTAssertEqual(failure.code, .qemuExited)
    }

    func testAMacThatCannotRunTheVMFailsBeforeAnythingStarts() {
      let environment = FakeTrialEnvironment()
      environment.startError = VMRunError(code: .macOSTooOld, message: "needs macOS 15")
      let trial = ready(environment)
      trial.start()
      guard case .failed(let failure) = trial.phase else { return XCTFail("Expected a failure") }
      XCTAssertEqual(failure.code, .macOSTooOld)
    }

    // MARK: The first page

    func testASupportedMacOffersInstallOrTry() {
      let environment = FakeTrialEnvironment()
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      trial.follow(.checking)
      trial.follow(.supported)
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertNil(trial.installLine)
      XCTAssertEqual(trial.installMenuAction, .install)
      XCTAssertEqual(trial.entryTitle, "Try in a VM")
      XCTAssertEqual(PlainLanguage.trialInstall, "Install on this Mac")
      trial.present()
      XCTAssertTrue(trial.canGoBack)
      trial.dismiss()
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testAnUnsupportedMacOpensTheTryPageAtOnce() {
      let environment = FakeTrialEnvironment()
      let trial = TrialSession(environment: environment)
      trial.follow(.checking)
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(trial.installMenuAction, .unavailable)
      trial.follow(.unsupported(tooLittleSpace))
      guard case .ready = trial.phase else { return XCTFail("Expected the Try page") }
      XCTAssertFalse(trial.canGoBack)
      trial.dismiss()
      guard case .ready = trial.phase else { return XCTFail("There is no page to go back to") }
      XCTAssertEqual(trial.installLine, "Free up at least 30 GB to install Omarchy")
      XCTAssertEqual(
        trial.installMenuAction,
        .explain(
          TrialInstallReason(
            headline: "Free up at least 30 GB to install Omarchy",
            detail: "Omarchy needs 60 GB. Remove files, then choose Check again.",
            canCheckAgain: true)))

      // Check Again finds room: the choice page takes over.
      trial.follow(.checking)
      guard case .ready = trial.phase else { return XCTFail("Expected the Try page") }
      trial.follow(.supported)
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testAnUnsupportedModelSaysSoInOneLine() {
      let failure = PlainLanguage.unsupportedModel(deviceIdentifier: "apple,j999")
      XCTAssertEqual(
        PlainLanguage.trialInstallLine(.unsupported(failure)),
        "Omarchy can’t be installed on this Mac model yet.")
    }

    func testAMacWithOmarchyInstalledOpensTheTryPage() {
      let environment = FakeTrialEnvironment()
      let trial = TrialSession(environment: environment)
      trial.follow(.installed)
      guard case .ready = trial.phase else { return XCTFail("Expected the Try page") }
      XCTAssertFalse(trial.canGoBack)
      XCTAssertFalse(trial.canInstall)
      XCTAssertEqual(trial.installLine, "Omarchy is already installed on this Mac.")
      guard case .explain(let reason) = trial.installMenuAction else {
        return XCTFail("Install explains why it can't")
      }
      XCTAssertEqual(reason.headline, "Omarchy is already installed")
      XCTAssertFalse(reason.canCheckAgain)
    }

    func testTheInstallersOwnPageTakesTheFloor() {
      let environment = FakeTrialEnvironment()
      let trial = TrialSession(environment: environment)
      trial.follow(.installed)
      trial.follow(.installerPage)
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(trial.installMenuAction, .unavailable)
    }

    func testCheckAgainOnAMacWithAVMKeepsTheTryPage() {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.follow(.unsupported(tooLittleSpace))
      guard case .ready = trial.phase else { return XCTFail("Expected the Try page") }
      trial.follow(.checking)
      trial.follow(.supported)
      guard case .ready = trial.phase else { return XCTFail("A VM keeps the Try page") }
      XCTAssertFalse(trial.canGoBack)
      XCTAssertTrue(trial.canInstall)
    }

    /// Omarchy starts before the inspection finds an install waiting for its
    /// Recovery step; the steps take the page once Omarchy shuts down.
    func testRecoveryStepsWaitForOmarchyToShutDown() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      trial.follow(.finishingInstall)
      XCTAssertEqual(trial.phase, .running(environment.permissionState))
      XCTAssertTrue(trial.finishInstallAfterShutDown)
      XCTAssertNil(trial.installLine)
      XCTAssertEqual(trial.installMenuAction, .unavailable)
      trial.shutDown()
      send(.exited(status: 0))
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertFalse(trial.finishInstallAfterShutDown)
    }

    /// A failure while the Recovery steps wait must not strand the person on
    /// the Try page: Back leads to the steps.
    func testAFailureWhileRecoveryWaitsLeadsBackToTheSteps() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      trial.follow(.finishingInstall)
      send(.error(VMRunError(code: .qemuExited, message: "QEMU stopped")))
      send(.exited(status: 1))
      guard case .failed(let failure) = trial.phase else { return XCTFail("Expected a failure") }
      XCTAssertEqual(failure.code, .qemuExited)
      trial.dismiss()
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testTheInstallersPageWaitsForOmarchyToShutDown() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      trial.follow(.installerPage)
      XCTAssertEqual(trial.phase, .running(environment.permissionState))
      XCTAssertFalse(trial.finishInstallAfterShutDown)
      trial.shutDown()
      send(.exited(status: 0))
      XCTAssertEqual(trial.phase, .hidden)
    }

    func testTheInstallerPhaseDecidesWhereTrySits() {
      let host = HostDisplay(chipAndSpace: "", supported: true)
      XCTAssertEqual(
        TrialInstallStatus(.inspecting, isBusy: true, pendingRecovery: false), .checking)
      XCTAssertEqual(
        TrialInstallStatus(.welcome(host), isBusy: false, pendingRecovery: false), .supported)
      XCTAssertEqual(
        TrialInstallStatus(.unsupported(tooLittleSpace), isBusy: false, pendingRecovery: false),
        .unsupported(tooLittleSpace))
      XCTAssertEqual(
        TrialInstallStatus(
          .existingInstallRefused(host: host), isBusy: true, pendingRecovery: false),
        .checking)
      XCTAssertEqual(
        TrialInstallStatus(
          .existingInstallRefused(host: host), isBusy: false, pendingRecovery: false),
        .installed)
      // An install waiting for its Recovery step keeps the installer's steps.
      XCTAssertEqual(
        TrialInstallStatus(
          .existingInstallRefused(host: host), isBusy: false, pendingRecovery: true),
        .finishingInstall)
      XCTAssertEqual(
        TrialInstallStatus(.failed(tooLittleSpace), isBusy: false, pendingRecovery: false),
        .installerPage)
    }

    #if DEBUG
      func testSimulatedMacsLandOnTheirPages() async {
        let expectations: [(InstallerSimulationScenario, (TrialInstallStatus) -> Bool)] = [
          (.success, { $0 == .supported }),
          (.existingInstall, { $0 == .installed }),
          (
            .unsupported,
            {
              if case .unsupported = $0 { return true }
              return false
            }
          ),
        ]
        for (scenario, expected) in expectations {
          let session = InstallerSession(
            environment: InstallerSimulationEnvironment(scenario: scenario, delay: .zero))
          await session.inspect()
          XCTAssertTrue(expected(session.trialInstallStatus), "\(scenario)")
        }
      }
    #endif

    // MARK: The remembered choice

    func testAVMOpensTryAndStartsAtOnce() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      XCTAssertTrue(trial.hasVM)
      trial.openAtLaunch()
      XCTAssertTrue(trial.isActive)
      let send = try XCTUnwrap(environment.onEvent)
      environment.onEvent = nil
      trial.openAtLaunch()
      XCTAssertNil(environment.onEvent)

      // The inspection finishes in the background without moving the page.
      trial.follow(.checking)
      trial.follow(.supported)
      send(.ready)
      XCTAssertEqual(trial.phase, .running(environment.permissionState))
      XCTAssertTrue(trial.canInstall)
      XCTAssertFalse(trial.canDeleteVM)

      send(.exited(status: 0))
      guard case .ready = trial.phase else { return XCTFail("A VM keeps the Try page") }
      XCTAssertFalse(trial.canGoBack)
      XCTAssertEqual(trial.startTitle, "Start")
    }

    func testAnAutoStartThatFailsBeforeTheInspectionKeepsTheVM() async {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      environment.startError = VMRunError(code: .launchFailed, message: "kit missing")
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      guard case .failed(let failure) = trial.phase else { return XCTFail("Expected a failure") }
      XCTAssertEqual(failure.code, .launchFailed)
      await trial.settled()
      XCTAssertEqual(trial.vmBytes, 9_400_000_000, "The plan review still sees the VM")
      XCTAssertTrue(trial.canDeleteVM)

      trial.follow(.checking)
      trial.follow(.supported)
      guard case .failed = trial.phase else { return XCTFail("The failure stays on the page") }
      trial.dismiss()
      guard case .ready = trial.phase else { return XCTFail("Back leads to the Try page") }
      XCTAssertFalse(trial.canGoBack)
      XCTAssertEqual(trial.startTitle, "Start")
    }

    func testInstallContinuesWhenOmarchyStopsWithAFailure() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.follow(.supported)
      trial.openAtLaunch()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      var installs = 0
      trial.leaveForInstall { installs += 1 }
      send(.error(VMRunError(code: .qemuExited, message: "QEMU stopped")))
      send(.exited(status: 1))
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(installs, 1)
    }

    func testInstallOnThisMacShutsOmarchyDownFirst() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.openAtLaunch()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)

      var installs = 0
      trial.leaveForInstall { installs += 1 }
      XCTAssertEqual(trial.phase, .running(environment.permissionState))
      XCTAssertEqual(installs, 0, "Nothing happens before the Mac is known to be supported")

      trial.follow(.supported)
      trial.leaveForInstall { installs += 1 }
      XCTAssertEqual(trial.phase, .stopping)
      XCTAssertEqual(environment.shutdowns, 1)
      XCTAssertEqual(installs, 0)
      send(.exited(status: 0))
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(installs, 1)

      // From the Try page, Install leaves at once.
      trial.present()
      trial.leaveForInstall { installs += 1 }
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertEqual(installs, 2)
    }

    // MARK: The running page

    func testTheRunningPageListsWhatIsStillNotAllowed() throws {
      let environment = FakeTrialEnvironment()
      let trial = ready(environment)
      trial.start()
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      guard case .running(let before) = trial.phase else { return XCTFail("Expected running") }
      XCTAssertFalse(before.allAllowed)
      XCTAssertEqual(before.accessibility, .notAsked)
      trial.requestAccessibility()
      guard case .running(let after) = trial.phase else { return XCTFail("Expected running") }
      XCTAssertEqual(after.accessibility, .allowed)
      XCTAssertEqual(
        PlainLanguage.trialPermissionsNextStart,
        "A permission you allow now takes effect the next time Omarchy starts.")
    }

    // MARK: Delete Virtual Machine

    func testDeletingTheVMReturnsToTheFirstLaunch() async throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.follow(.supported)
      trial.openAtLaunch()
      XCTAssertFalse(trial.canDeleteVM)
      let send = try XCTUnwrap(environment.onEvent)
      send(.ready)
      trial.shutDown()
      send(.exited(status: 0))
      XCTAssertTrue(trial.canDeleteVM)

      let message = await trial.deletionMessage()
      XCTAssertEqual(
        message,
        "Omarchy’s virtual machine, with everything saved in it, moves to the Trash. Emptying the Trash frees up to 9 GB. The next start downloads Omarchy again."
      )
      try trial.deleteVM()
      XCTAssertEqual(environment.deletions, 1)
      XCTAssertEqual(trial.phase, .hidden)
      XCTAssertFalse(trial.hasVM)
      XCTAssertFalse(trial.canDeleteVM)
      XCTAssertEqual(trial.vmBytes, 0)
    }

    func testDeletingOnAnUnsupportedMacKeepsTheTryPage() throws {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      let trial = TrialSession(environment: environment)
      trial.follow(.unsupported(tooLittleSpace))
      try trial.deleteVM()
      guard case .ready(let space, _) = trial.phase else { return XCTFail("Expected Try") }
      XCTAssertFalse(space.hasVM)
      XCTAssertEqual(trial.startTitle, "Download and start")
    }

    func testAFailedDeletionKeepsTheVM() {
      let environment = FakeTrialEnvironment()
      environment.makeVM()
      environment.deleteError = TrialVMFolder.Refusal.open
      let trial = TrialSession(environment: environment)
      trial.follow(.supported)
      XCTAssertThrowsError(try trial.deleteVM())
      XCTAssertTrue(trial.hasVM)
      XCTAssertEqual(
        TrialVMFolder.Refusal.open.localizedDescription,
        "Omarchy is open in Try Omarchy or another copy of this app. Shut it down there first.")
    }

    private func runningWithSharedNetworking(_ environment: FakeTrialEnvironment) throws -> (
      TrialSession, @MainActor (VMRunEvent) -> Void
    ) {
      let trial = ready(environment)
      trial.start()
      let send = try XCTUnwrap(environment.onEvent)
      XCTAssertNil(trial.bridgedNetworkLine)
      send(.notice(VMRunNotice(code: .bridgedNetworkUnavailable, message: "not registered")))
      send(.progress(.checking, percent: nil))
      send(.ready)
      return (trial, send)
    }

    func testASharedNetworkingNoticeOffersToSetUpBridgedNetworking() async throws {
      let environment = FakeTrialEnvironment()
      let (trial, send) = try runningWithSharedNetworking(environment)
      XCTAssertEqual(trial.phase, .running(environment.permissionState))
      XCTAssertEqual(
        trial.bridgedNetworkLine, PlainLanguage.trialBridgedNetworkLine(.notRegistered))
      XCTAssertEqual(trial.bridgedNetworkActionTitle, "Set Up Bridged Networking")
      XCTAssertFalse(trial.canChangeBridgedNetwork)

      await trial.setUpBridgedNetwork()
      XCTAssertEqual(environment.networkChanges, ["register", "open login items"])
      XCTAssertEqual(trial.bridgedNetwork, .needsApproval)
      XCTAssertEqual(trial.bridgedNetworkActionTitle, "Open Login Items")
      XCTAssertEqual(environment.shutdowns, 0)
      await trial.setUpBridgedNetwork()
      XCTAssertEqual(
        environment.networkChanges, ["register", "open login items", "open login items"])

      send(.exited(status: 0))
      XCTAssertNil(trial.bridgedNetworkLine)
      trial.present()
      trial.start()
      XCTAssertNotNil(environment.onEvent)
      XCTAssertFalse(trial.bridgedNetworkUnavailable)
    }

    func testAFailedRegistrationSaysWhy() async throws {
      let environment = FakeTrialEnvironment()
      environment.registerError = VMRunError(
        code: .launchFailed, message: "Operation not permitted")
      let (trial, _) = try runningWithSharedNetworking(environment)
      await trial.setUpBridgedNetwork()
      XCTAssertEqual(
        trial.bridgedNetworkLine,
        "Bridged networking couldn’t be changed: Operation not permitted")
      XCTAssertEqual(trial.bridgedNetwork, .notRegistered)
    }

    func testRepairAndRemoveShutOmarchyDownFirst() async throws {
      let environment = FakeTrialEnvironment()
      environment.network = .enabled
      let (trial, send) = try runningWithSharedNetworking(environment)
      XCTAssertEqual(trial.bridgedNetworkActionTitle, "Repair")
      XCTAssertTrue(trial.canChangeBridgedNetwork)
      let repair = Task { await trial.repairBridgedNetwork() }
      await Task.yield()
      XCTAssertEqual(trial.phase, .stopping)
      XCTAssertEqual(environment.shutdowns, 1)
      XCTAssertEqual(environment.networkChanges, [])
      send(.exited(status: 0))
      await repair.value
      XCTAssertEqual(environment.networkChanges, ["unregister", "register", "open login items"])

      environment.network = .enabled
      trial.refresh()
      await trial.removeBridgedNetwork()
      XCTAssertEqual(environment.networkChanges.last, "unregister")
      XCTAssertEqual(trial.bridgedNetwork, .notRegistered)
      XCTAssertFalse(trial.canChangeBridgedNetwork)
    }

    func testEveryCodeAndPhaseHasWords() {
      for code in VMRunErrorCode.allCases {
        let words = PlainLanguage.trialFailure(code)
        XCTAssertFalse(words.headline.isEmpty)
        XCTAssertFalse(words.detail.isEmpty)
      }
      for phase in VMRunPhase.allCases {
        XCTAssertFalse(PlainLanguage.trialProgressTitle(phase).isEmpty)
      }
      XCTAssertNil(PlainLanguage.trialDiskNotice(bytes: 0))
      XCTAssertEqual(
        PlainLanguage.trialDiskNotice(bytes: 9_400_000_000),
        "Omarchy’s virtual machine uses up to 9 GB of macOS’s space, already counted above. Installing keeps it, in Application Support › Try Omarchy."
      )
    }
  }
#endif
