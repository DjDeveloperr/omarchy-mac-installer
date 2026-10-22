#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class TrialVMFolderTests: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
      base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      root = base.appendingPathComponent("Try Omarchy/VM/v1", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("shell"), withIntermediateDirectories: true)
      try Data().write(to: root.appendingPathComponent("shell/disk.img"))
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: base)
    }

    func testTheDefaultFolderMovesToTheTrashWhole() throws {
      try Data().write(to: root.appendingPathComponent("shell/lock"))
      var recycled: [URL] = []
      try TrialVMFolder.trash(defaultRoot: root, under: base) { recycled.append($0) }
      XCTAssertEqual(recycled.map(\.path), [root.standardizedFileURL.path])
    }

    func testAVMThatNeverRanHasNoLockToTake() throws {
      var recycled = 0
      try TrialVMFolder.trash(defaultRoot: root, under: base) { _ in recycled += 1 }
      XCTAssertEqual(recycled, 1)
    }

    func testNothingOutsideTheBaseIsTouched() {
      XCTAssertThrowsError(
        try TrialVMFolder.trash(defaultRoot: base, under: root) { _ in XCTFail("Moved") }
      ) { XCTAssertEqual($0 as? TrialVMFolder.Refusal, .notTheDefaultFolder) }
    }

    func testALinkedFolderIsRefused() throws {
      let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
      try FileManager.default.moveItem(
        at: base.appendingPathComponent("Try Omarchy/VM"), to: elsewhere)
      try FileManager.default.createSymbolicLink(
        at: base.appendingPathComponent("Try Omarchy/VM"), withDestinationURL: elsewhere)
      XCTAssertThrowsError(
        try TrialVMFolder.trash(defaultRoot: root, under: base) { _ in XCTFail("Moved") }
      ) { XCTAssertEqual($0 as? TrialVMFolder.Refusal, .unsafeFolder) }
    }

    /// The launcher holds `shell/lock` with lockf while the VM runs.
    func testAVMOpenElsewhereIsRefused() throws {
      let lock = root.appendingPathComponent("shell/lock")
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
      XCTAssertThrowsError(
        try TrialVMFolder.trash(defaultRoot: root, under: base) { _ in XCTFail("Moved") }
      ) { XCTAssertEqual($0 as? TrialVMFolder.Refusal, .open) }
    }
  }
#endif
