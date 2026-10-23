#if os(macOS)
  import Darwin
  import Foundation

  /// A downloaded `TryOmarchyKit.zip`, read before anything in it is
  /// unpacked: its central directory must list only plain files, folders and
  /// links, under relative names, with nothing stored beneath a link. The
  /// unpacked folder is checked again before it is used.
  public enum TrialKitArchive {
    public static let maximumEntries = 20_000
    public static let maximumUnpackedBytes: UInt64 = 4 << 30
    public static let maximumNameBytes = 1_024
    static let maximumDirectoryBytes: UInt64 = 32 << 20

    public enum Kind: Equatable, Sendable {
      case file
      case directory
      case link
    }

    public struct Entry: Equatable, Sendable {
      public let name: String
      public let kind: Kind
      public let unpackedBytes: UInt64
    }

    public enum Refusal: Error, Equatable, Sendable {
      case unreadable
      case unsupported
      case tooLarge
      case unsafeEntry(String)
      case extractionFailed
    }

    /// The archive's entries, or a refusal for anything unsafe or unknown.
    public static func entries(of archive: URL) throws -> [Entry] {
      guard let handle = try? FileHandle(forReadingFrom: archive) else { throw Refusal.unreadable }
      defer { try? handle.close() }
      guard let size = try? handle.seekToEnd(), size >= 22 else { throw Refusal.unreadable }
      let tailSize = min(size, 65_557)
      try handle.seek(toOffset: size - tailSize)
      guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count == Int(tailSize) else {
        throw Refusal.unreadable
      }
      let tailBytes = [UInt8](tail)
      guard let end = endOfCentralDirectory(in: tailBytes) else { throw Refusal.unreadable }
      let record = Reader(bytes: tailBytes, offset: end)
      let disk = record.u16(4)
      let directoryDisk = record.u16(6)
      let entriesOnDisk = record.u16(8)
      let entryCount = record.u16(10)
      let directorySize = UInt64(record.u32(12))
      let directoryOffset = UInt64(record.u32(16))
      if end >= 20, Reader(bytes: tailBytes, offset: end - 20).u32(0) == 0x0706_4b50 {
        throw Refusal.unsupported
      }
      guard disk == 0, directoryDisk == 0, entriesOnDisk == entryCount, entryCount != 0xFFFF,
        directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF
      else { throw Refusal.unsupported }
      guard Int(entryCount) <= maximumEntries, directorySize <= maximumDirectoryBytes else {
        throw Refusal.tooLarge
      }
      guard directoryOffset + directorySize <= size - tailSize + UInt64(end) else {
        throw Refusal.unreadable
      }
      try handle.seek(toOffset: directoryOffset)
      guard let directory = try handle.read(upToCount: Int(directorySize)),
        directory.count == Int(directorySize)
      else { throw Refusal.unreadable }
      return try parse(directory: [UInt8](directory), count: Int(entryCount))
    }

    static func parse(directory: [UInt8], count: Int) throws -> [Entry] {
      var entries: [Entry] = []
      var offset = 0
      var total: UInt64 = 0
      for _ in 0..<count {
        guard offset + 46 <= directory.count else { throw Refusal.unreadable }
        let header = Reader(bytes: directory, offset: offset)
        guard header.u32(0) == 0x0201_4b50 else { throw Refusal.unreadable }
        let host = header.u16(4) >> 8
        let flags = header.u16(8)
        let method = header.u16(10)
        let unpacked = header.u32(24)
        let nameLength = Int(header.u16(28))
        let extraLength = Int(header.u16(30))
        let commentLength = Int(header.u16(32))
        let external = header.u32(38)
        let nameStart = offset + 46
        let next = nameStart + nameLength + extraLength + commentLength
        guard next <= directory.count else { throw Refusal.unreadable }
        guard nameLength > 0, nameLength <= maximumNameBytes,
          let name = String(
            validating: directory[nameStart..<nameStart + nameLength], as: UTF8.self)
        else { throw Refusal.unsafeEntry("an entry has no readable name") }
        guard flags & 0x1 == 0, method == 0 || method == 8, unpacked != 0xFFFF_FFFF else {
          throw Refusal.unsafeEntry(name)
        }
        let kind = try kind(of: name, host: host, external: external)
        total += UInt64(unpacked)
        guard total <= maximumUnpackedBytes else { throw Refusal.tooLarge }
        entries.append(Entry(name: name, kind: kind, unpackedBytes: UInt64(unpacked)))
        offset = next
      }
      try checkNames(entries)
      return entries
    }

    private static func kind(of name: String, host: UInt16, external: UInt32) throws -> Kind {
      let isFolderName = name.hasSuffix("/")
      guard host == 3 else { return isFolderName ? .directory : .file }
      let mode = mode_t(external >> 16)
      guard mode & mode_t(S_ISUID | S_ISGID | S_ISVTX) == 0, mode & 0o022 == 0 else {
        throw Refusal.unsafeEntry(name)
      }
      switch mode & S_IFMT {
      case S_IFDIR: return .directory
      case S_IFLNK where !isFolderName: return .link
      case S_IFREG where !isFolderName: return .file
      case 0: return isFolderName ? .directory : .file
      default: throw Refusal.unsafeEntry(name)
      }
    }

    /// Names are relative, with no empty, `.` or `..` parts and no
    /// backslashes, and none repeats or sits beneath a link, compared the way
    /// APFS compares names.
    static func checkNames(_ entries: [Entry]) throws {
      var seen: Set<String> = []
      var links: Set<String> = []
      for entry in entries {
        var name = Substring(entry.name)
        if entry.kind == .directory, name.hasSuffix("/") { name = name.dropLast() }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
          parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Refusal.unsafeEntry(entry.name) }
        let key = folded(String(name))
        guard seen.insert(key).inserted else { throw Refusal.unsafeEntry(entry.name) }
        if entry.kind == .link { links.insert(key) }
      }
      for entry in entries {
        let parts = folded(entry.name).split(separator: "/")
        for depth in parts.indices.dropLast() {
          if links.contains(parts[...depth].joined(separator: "/")) {
            throw Refusal.unsafeEntry(entry.name)
          }
        }
      }
    }

    private static func folded(_ name: String) -> String {
      name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Unpacks a checked archive into `destination`, which must not exist,
    /// without the quarantine attribute, then checks what was unpacked. On a
    /// refusal nothing unpacked is left.
    public static func unpack(_ archive: URL, into destination: URL) throws {
      _ = try entries(of: archive)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw Refusal.extractionFailed
      }
      do {
        try runDitto(archive, into: destination)
        try checkUnpacked(destination)
      } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
      }
    }

    private static func runDitto(_ archive: URL, into destination: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-x", "-k", "--noqtn", "--noacl", archive.path, destination.path]
      process.environment = [:]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        throw Refusal.extractionFailed
      }
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw Refusal.extractionFailed
      }
    }

    /// The unpacked folder holds only plain files with one link each,
    /// folders, and links that point within their own folder, and nothing in
    /// it carries the quarantine attribute.
    public static func checkUnpacked(_ root: URL) throws {
      var total: UInt64 = 0
      var information = stat()
      guard lstat(root.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
        throw Refusal.extractionFailed
      }
      var pending = [root.path]
      while let folder = pending.popLast() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
          throw Refusal.extractionFailed
        }
        for name in names {
          let path = folder + "/" + name
          let shown = String(path.dropFirst(root.path.count + 1))
          guard lstat(path, &information) == 0 else { throw Refusal.extractionFailed }
          guard information.st_mode & mode_t(S_ISUID | S_ISGID) == 0 else {
            throw Refusal.unsafeEntry(shown)
          }
          switch information.st_mode & S_IFMT {
          case S_IFDIR:
            pending.append(path)
          case S_IFREG:
            guard information.st_nlink == 1 else { throw Refusal.unsafeEntry(shown) }
            total += UInt64(information.st_size)
            guard total <= maximumUnpackedBytes else { throw Refusal.tooLarge }
          case S_IFLNK:
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              isContained(target)
            else { throw Refusal.unsafeEntry(shown) }
          default:
            throw Refusal.unsafeEntry(shown)
          }
          if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw Refusal.extractionFailed
          }
        }
      }
    }

    /// A link target that stays in the link's own folder or below it.
    static func isContained(_ target: String) -> Bool {
      let parts = target.split(separator: "/", omittingEmptySubsequences: false)
      return !target.isEmpty && !target.hasPrefix("/") && !target.contains("\0")
        && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
      var index = bytes.count - 22
      while index >= 0 {
        let reader = Reader(bytes: bytes, offset: index)
        if reader.u32(0) == 0x0605_4b50, index + 22 + Int(reader.u16(20)) == bytes.count {
          return index
        }
        index -= 1
      }
      return nil
    }

    private struct Reader {
      let bytes: [UInt8]
      let offset: Int

      func u16(_ at: Int) -> UInt16 {
        UInt16(bytes[offset + at]) | UInt16(bytes[offset + at + 1]) << 8
      }

      func u32(_ at: Int) -> UInt32 {
        UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
      }
    }
  }
#endif
