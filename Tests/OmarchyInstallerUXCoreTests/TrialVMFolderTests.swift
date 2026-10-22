#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class TrialVMFolderTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var lock: URL { root.appendingPathComponent("shell/lock") }

    override func setUpWithError() throws {
      base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      root = TrialVMFolder.root(under: base)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("shell"), withIntermediateDirectories: true)
      try Data().write(to: root.appendingPathComponent("shell/disk.img"))
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: base)
    }

    private func refuses(_ refusal: TrialVMFolder.Refusal, under base: URL? = nil) {
      XCTAssertThrowsError(
        try TrialVMFolder.trash(under: base ?? self.base) { _ in XCTFail("Moved") }
      ) { XCTAssertEqual($0 as? TrialVMFolder.Refusal, refusal) }
    }

    private func moveAside(_ url: URL) throws -> URL {
      let elsewhere = base.appendingPathComponent(UUID().uuidString)
      try FileManager.default.moveItem(at: url, to: elsewhere)
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
      return elsewhere
    }

    func testTheDefaultFolderMovesToTheTrashWhole() throws {
      try Data().write(to: lock)
      var recycled: [String] = []
      try TrialVMFolder.trash(under: base) { recycled.append($0.path) }
      XCTAssertEqual(recycled, [base.path + "/Try Omarchy/VM/v1"])
    }

    /// The launcher creates the lock when it starts, so a missing lock is
    /// created and taken, and a launcher starting now waits for it.
    func testAMissingLockIsCreatedAndTaken() throws {
      var recycled = 0
      try TrialVMFolder.trash(under: base) { _ in recycled += 1 }
      XCTAssertEqual(recycled, 1)
      let attributes = try FileManager.default.attributesOfItem(atPath: lock.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOnlyAPlainBaseIsAccepted() {
      refuses(.notTheDefaultFolder, under: URL(fileURLWithPath: base.path + "/x/.."))
      refuses(.notTheDefaultFolder, under: URL(string: "https://example.com/")!)
    }

    func testALinkedFolderOnTheWayIsRefused() throws {
      _ = try moveAside(base.appendingPathComponent("Try Omarchy/VM"))
      refuses(.unsafeFolder)
    }

    func testALinkedVMFolderIsRefused() throws {
      _ = try moveAside(root)
      refuses(.unsafeFolder)
    }

    func testALinkedShellFolderIsRefused() throws {
      _ = try moveAside(root.appendingPathComponent("shell"))
      refuses(.unsafeFolder)
    }

    func testALinkedLockIsRefused() throws {
      let target = base.appendingPathComponent("target")
      try Data().write(to: target)
      try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
      refuses(.unsafeFolder)
    }

    func testAVMFolderThatIsAFileIsRefused() throws {
      try FileManager.default.removeItem(at: root)
      try Data().write(to: root)
      refuses(.unsafeFolder)
    }

    /// The launcher holds `shell/lock` with lockf while the VM runs.
    func testAVMOpenElsewhereIsRefused() throws {
      try Data().write(to: lock)
      let holder = Process()
      let output = Pipe()
      let input = Pipe()
      holder.executableURL = URL(fileURLWithPath: "/bin/bash")
      holder.arguments = [
        "-c", "exec 9>>\"$1\"; /usr/bin/lockf -s -t 0 9 || exit 1; echo ready; read answer", "_",
        lock.path,
      ]
      holder.standardOutput = output
      holder.standardInput = input
      try holder.run()
      defer {
        try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        holder.waitUntilExit()
      }
      let line = output.fileHandleForReading.availableData
      XCTAssertEqual(String(decoding: line, as: UTF8.self), "ready\n")
      refuses(.open)
    }
  }
#endif
