import Darwin
import Foundation

public enum ProcessBindingError: Error, Equatable, CustomStringConvertible {
  case ambiguousTargets
  case processGone
  case inspectionFailed
  case pathMismatch
  case uidMismatch
  case identityMismatch
  case sourceRootUnknown
  case sourceRootMismatch

  public var description: String {
    switch self {
    case .ambiguousTargets: return "ambiguousTargets: select one process explicitly with --pid"
    case .processGone: return "processGone: the selected process is no longer available"
    case .inspectionFailed:
      return "inspectionFailed: cannot establish the selected process identity"
    case .pathMismatch: return "pathMismatch: the selected executable does not match"
    case .uidMismatch: return "uidMismatch: the selected process owner does not match"
    case .identityMismatch: return "identityMismatch: the selected process or source was replaced"
    case .sourceRootUnknown: return "sourceRootUnknown: cannot establish one open database root"
    case .sourceRootMismatch:
      return "sourceRootMismatch: the selected process is using another database root"
    }
  }
}

/// Immutable identity established from a live process, never from a name or mtime guess.
/// Construction and revalidation are read-only and do not attach a debugger.
public struct ProcessTargetBinding: Sendable {
  public let processID: pid_t
  public let executablePath: URL
  public let uid: uid_t
  public let databaseRoot: URL
  private let identity: Identity
  private let rootDevice: dev_t
  private let rootInode: ino_t

  private struct Identity: Equatable, Sendable {
    let path: String
    let uid: uid_t
    let realUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
  }

  public init(processID: pid_t, executablePath: URL, uid: uid_t, databaseRoot: URL) throws {
    guard processID > 0 else { throw ProcessBindingError.processGone }
    let expectedPath = executablePath.standardizedFileURL.resolvingSymlinksInPath()
    let root = databaseRoot.standardizedFileURL.resolvingSymlinksInPath()
    let identity = try Self.inspect(processID)
    guard identity.path == expectedPath.path else { throw ProcessBindingError.pathMismatch }
    guard identity.uid == uid, identity.realUID == uid else {
      throw ProcessBindingError.uidMismatch
    }
    let metadata = try Self.rootMetadata(root)
    self.processID = processID
    self.executablePath = expectedPath
    self.uid = uid
    self.databaseRoot = root
    self.identity = identity
    self.rootDevice = metadata.st_dev
    self.rootInode = metadata.st_ino
    try assertStillBound()
  }

  public func assertStillBound() throws {
    guard try Self.inspect(processID) == identity else {
      throw ProcessBindingError.identityMismatch
    }
    let metadata = try Self.rootMetadata(databaseRoot)
    guard metadata.st_dev == rootDevice, metadata.st_ino == rootInode else {
      throw ProcessBindingError.identityMismatch
    }
    let roots = try Self.openDatabaseRoots(processID)
    guard roots.count == 1 else { throw ProcessBindingError.sourceRootUnknown }
    guard roots.contains(databaseRoot.path) else { throw ProcessBindingError.sourceRootMismatch }
    // Recheck observed identity after file-handle enumeration. This is not an atomic OS attach.
    guard try Self.inspect(processID) == identity else {
      throw ProcessBindingError.identityMismatch
    }
  }

  private static func inspect(_ pid: pid_t) throws -> Identity {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
      if kill(pid, 0) != 0, errno == ESRCH { throw ProcessBindingError.processGone }
      throw ProcessBindingError.inspectionFailed
    }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
      throw ProcessBindingError.inspectionFailed
    }
    return Identity(
      path: URL(
        fileURLWithPath: String(
          decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      ).resolvingSymlinksInPath().path,
      uid: info.pbi_uid, realUID: info.pbi_ruid,
      startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec
    )
  }

  private static func rootMetadata(_ root: URL) throws -> stat {
    var metadata = stat()
    guard root.lastPathComponent == "db_storage",
      lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR
    else { throw ProcessBindingError.sourceRootUnknown }
    return metadata
  }

  private static func openDatabaseRoots(_ pid: pid_t) throws -> Set<String> {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-n", "-P", "-a", "-p", String(pid), "-F0n"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw ProcessBindingError.sourceRootUnknown }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw ProcessBindingError.sourceRootUnknown
    }
    var roots = Set<String>()
    for field in data.split(separator: 0) {
      // lsof terminates field sets with LF even in NUL mode.
      let record = field.drop(while: { $0 == 10 })
      guard record.first == 110, let path = String(data: Data(record.dropFirst()), encoding: .utf8),
        path.hasPrefix("/"),
        path.hasSuffix(".db") || path.hasSuffix(".db-wal") || path.hasSuffix(".db-shm")
      else { continue }
      var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
      while parent.path != "/" {
        if parent.lastPathComponent == "db_storage" {
          roots.insert(parent.resolvingSymlinksInPath().path)
          break
        }
        parent.deleteLastPathComponent()
      }
    }
    return roots
  }
}
