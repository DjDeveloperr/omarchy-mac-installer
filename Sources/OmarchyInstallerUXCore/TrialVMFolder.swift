#if os(macOS)
  import Darwin
  import Foundation

  /// Deletes the VM in the default folder, and nothing else. The folder moves
  /// to the Trash whole, so Finder's Put Back restores it.
  public enum TrialVMFolder {
    public enum Refusal: Error, Equatable, LocalizedError {
      case notTheDefaultFolder
      case unsafeFolder
      case open

      public var errorDescription: String? {
        switch self {
        case .notTheDefaultFolder: "Only the VM in the default folder can be deleted here."
        case .unsafeFolder: "The VM’s folder isn’t a plain folder, so it was left in place."
        case .open:
          "Omarchy is open in Try Omarchy or another copy of this app. Shut it down there first."
        }
      }
    }

    /// `root` must sit inside `base`, every folder between them must be a real
    /// directory of this user, not a link, and the launcher's lock on
    /// `shell/lock` must be free; it is held until the folder is in the Trash.
    public static func trash(
      defaultRoot root: URL, under base: URL,
      recycle: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
      }
    ) throws {
      let root = root.standardizedFileURL
      let base = base.standardizedFileURL
      guard root.path.hasPrefix(base.path + "/") else { throw Refusal.notTheDefaultFolder }
      var folder = root
      while folder.path != base.path {
        var information = stat()
        guard lstat(folder.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
          information.st_uid == getuid()
        else { throw Refusal.unsafeFolder }
        folder.deleteLastPathComponent()
      }
      let lock = try takeLock(root.appendingPathComponent("shell/lock", isDirectory: false))
      defer { if lock >= 0 { close(lock) } }
      try recycle(root)
    }

    /// The launcher holds this lock while the VM runs. A VM that never ran has
    /// no lock file, and then nothing can be running it.
    private static func takeLock(_ url: URL) throws -> Int32 {
      let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else {
        if errno == ENOENT { return -1 }
        throw Refusal.unsafeFolder
      }
      var information = stat()
      var lock = flock()
      lock.l_type = Int16(F_WRLCK)
      lock.l_whence = Int16(SEEK_SET)
      guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
        information.st_uid == getuid()
      else {
        close(descriptor)
        throw Refusal.unsafeFolder
      }
      guard fcntl(descriptor, F_SETLK, &lock) == 0 else {
        close(descriptor)
        throw Refusal.open
      }
      return descriptor
    }
  }
#endif
