#if os(macOS)
  import Foundation
  import TryOmarchyKitClient
  import XCTest
  @testable import OmarchyInstallerUXCore

  @MainActor
  private final class FakeTrialEnvironment: TrialEnvironment {
    var isAvailable = true
    var installed = false
    var opened = 0
    var currentSpace = TrialSpace(
      requiredBytes: 15_000_000_000, freeBytes: 40_000_000_000, hasVM: false)
    var permissionState = TrialPermissions(
      accessibility: .notAsked, microphone: .notAsked, camera: .refused)
    var startError: Error?
    var shutdowns = 0
    var onEvent: (@MainActor (VMRunEvent) -> Void)?

    func fullAppInstalled() -> Bool { installed }
    func openFullApp() -> Bool {
      opened += 1
      return true
    }
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
  }

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

    func testTheFullAppOpensInsteadOnceInstalled() {
      let environment = FakeTrialEnvironment()
      environment.installed = true
      let trial = TrialSession(environment: environment)
      XCTAssertEqual(trial.entryTitle, "Open in Try Omarchy")
      trial.present()
      XCTAssertEqual(environment.opened, 1)
      XCTAssertEqual(trial.phase, .hidden)
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
      XCTAssertEqual(trial.phase, .running)

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
      XCTAssertEqual(failure.technicalDetail, "run-qemu-gpu: this VM is already open")
      trial.dismiss()
      XCTAssertEqual(trial.phase, .hidden)
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
        "Omarchy’s VM uses 9 GB of macOS’s space, already counted above. Installing keeps it, in Application Support › Try Omarchy."
      )
    }
  }
#endif
