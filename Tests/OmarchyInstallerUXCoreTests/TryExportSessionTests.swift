#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  @MainActor
  final class TryExportSessionTests: XCTestCase {
    static let newer = TryOmarchyExportDisplay(
      id: "6022f2ec-746c-4636-b786-2240103a7efb",
      publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
      entries: 862,
      expandedBytes: 28_680_598,
      bundleBytes: 29_365_414
    )
    static let older = TryOmarchyExportDisplay(
      id: "c4e6a8b0-2d4f-4a6c-9e8f-0a1b2c3d4e03",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      entries: 1,
      expandedBytes: 10,
      bundleBytes: 200
    )

    func welcomed(_ environment: MockInstallerEnvironment) async -> InstallerSession {
      let session = InstallerSession(environment: environment)
      await session.inspect()
      guard case .welcome = session.phase else {
        XCTFail("expected the welcome page, got \(session.phase)")
        return session
      }
      return session
    }

    func testFindsExportsWithoutChoosingOne() async {
      let environment = MockInstallerEnvironment()
      environment.tryExportAnswers = [.found([Self.newer, Self.older], unusable: 1)]
      let session = await welcomed(environment)
      XCTAssertEqual(session.tryExports, .notChecked)

      await session.refreshTryExports()
      XCTAssertEqual(session.tryExports.exports, [Self.newer, Self.older])
      XCTAssertNil(session.chosenTryExportID)
      XCTAssertEqual(session.tryExportCheck, .idle)
      XCTAssertEqual(environment.checkedTryExports, [])
    }

    func testChoosingAnExportChecksItAndNoneClearsIt() async {
      let environment = MockInstallerEnvironment()
      environment.tryExportAnswers = [.found([Self.newer, Self.older], unusable: 0)]
      environment.tryExportChecks = [Self.older.id: .failed("tampered")]
      let session = await welcomed(environment)
      await session.refreshTryExports()

      await session.chooseTryExport(Self.newer.id)
      XCTAssertEqual(session.chosenTryExportID, Self.newer.id)
      XCTAssertEqual(session.tryExportCheck, .verified)

      await session.chooseTryExport(Self.older.id)
      XCTAssertEqual(session.tryExportCheck, .failed("tampered"))

      await session.chooseTryExport(nil)
      XCTAssertNil(session.chosenTryExportID)
      XCTAssertEqual(session.tryExportCheck, .idle)
      XCTAssertEqual(environment.checkedTryExports, [Self.newer.id, Self.older.id])
    }

    func testIgnoresAnExportItDidNotFind() async {
      let environment = MockInstallerEnvironment()
      environment.tryExportAnswers = [.found([Self.newer], unusable: 0)]
      let session = await welcomed(environment)
      await session.refreshTryExports()

      await session.chooseTryExport(Self.older.id)
      XCTAssertNil(session.chosenTryExportID)
      XCTAssertEqual(environment.checkedTryExports, [])
    }

    func testOnlyTheLatestChoicesCheckIsKept() async {
      let environment = MockInstallerEnvironment()
      let slow = OperationGate()
      environment.tryExportAnswers = [.found([Self.newer, Self.older], unusable: 0)]
      environment.tryExportChecks = [Self.newer.id: .failed("stale answer")]
      environment.tryExportCheckGates = [slow]
      let session = await welcomed(environment)
      await session.refreshTryExports()

      let first = Task { await session.chooseTryExport(Self.newer.id) }
      await slow.waitUntilEntered()
      XCTAssertEqual(session.tryExportCheck, .checking)
      await session.chooseTryExport(Self.older.id)
      XCTAssertEqual(session.tryExportCheck, .verified)

      await slow.release()
      await first.value
      XCTAssertEqual(session.chosenTryExportID, Self.older.id)
      XCTAssertEqual(session.tryExportCheck, .verified)
    }

    func testLookingAgainDuringACheckKeepsItsAnswer() async {
      let environment = MockInstallerEnvironment()
      let slow = OperationGate()
      environment.tryExportAnswers = [.found([Self.newer], unusable: 0)]
      environment.tryExportCheckGates = [slow]
      let session = await welcomed(environment)
      await session.refreshTryExports()

      let check = Task { await session.chooseTryExport(Self.newer.id) }
      await slow.waitUntilEntered()
      await session.refreshTryExports()
      await slow.release()
      await check.value
      XCTAssertEqual(session.tryExportCheck, .verified)
    }

    func testAChosenExportThatDisappearsIsDropped() async {
      let environment = MockInstallerEnvironment()
      environment.tryExportAnswers = [.found([Self.newer], unusable: 0), .none]
      let session = await welcomed(environment)
      await session.refreshTryExports()
      await session.chooseTryExport(Self.newer.id)

      await session.refreshTryExports()
      XCTAssertNil(session.chosenTryExportID)
      XCTAssertEqual(session.tryExportCheck, .idle)
    }

    func testExportsAreChosenOnlyOnTheWelcomePage() async {
      let environment = MockInstallerEnvironment()
      environment.tryExportAnswers = [.found([Self.newer], unusable: 0)]
      let gate = OperationGate()
      environment.inspectGate = gate
      let session = InstallerSession(environment: environment)
      let inspection = Task { await session.inspect() }
      await gate.waitUntilEntered()
      await session.refreshTryExports()
      XCTAssertFalse(session.canChooseTryExport)
      await session.chooseTryExport(Self.newer.id)
      XCTAssertNil(session.chosenTryExportID)
      await gate.release()
      await inspection.value

      XCTAssertTrue(session.canChooseTryExport)
      await session.continueToPlan()
      XCTAssertFalse(session.canChooseTryExport)
      await session.chooseTryExport(Self.newer.id)
      XCTAssertNil(session.chosenTryExportID)
      XCTAssertEqual(environment.checkedTryExports, [])
    }

    func testWordingNamesTheExportAndSkippedFolders() {
      XCTAssertEqual(Self.newer.summary, "862 items · 29 MB")
      XCTAssertEqual(Self.older.summary, "1 item · 200 bytes")
      XCTAssertNil(PlainLanguage.tryExportUnusable(0))
      XCTAssertNotNil(PlainLanguage.tryExportUnusable(2))
      for problem: TryOmarchyExportProblem in [
        .digestMismatch, .changedDuringVerification, .unsafeOwnership, .unreadable,
      ] {
        XCTAssertFalse(PlainLanguage.tryExportFailure(problem).contains("passphrase"))
      }
    }
  }
#endif
