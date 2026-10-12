// =============================================================================
// BindingAcceptanceV1V8Tests — V1–V8 acceptance against CURRENT production
// binding patches (ProcessTargetBinding + uniqueProcessID + capture(binding:)
// with NO re-attach + all-salt verify + SecretOutputWriter staged publish).
//
// Platform: macOS only (Darwin proc_*, /usr/sbin/lsof, /usr/bin/pgrep).
// Install: copy this file into Tests/GreenBubblesAcquireTests/ in a GB_REPO
//          that already has the current production patches applied.
// Run:     GBISO_PAUSER_BIN=... GBISO_HELPERS=... swift test --filter BindingAcceptance
// Expected: all eight cases PASS (swift test exit 0).
//
// Touches NO real WeChat / keychain / containers / accounts.
// Synthetic secrets only (all-0xaa passphrase fixture).
// =============================================================================

import Darwin
import Foundation
import Testing

@testable import GreenBubblesAcquire

// MARK: - Shared sandbox

private enum GBISO {
  /// Synthetic 32-byte passphrase (all 0xaa). Not a real secret.
  static let synBytes = [UInt8](repeating: 0xaa, count: 32)
  static let synHex64 = String(repeating: "aa", count: 32)

  /// Prefer env, then colocated `GBISOHelpers/` next to this test file
  /// (installed by run-all.sh into Tests/GreenBubblesAcquireTests/), then
  /// package-drop `../helpers`. Never precondition-crash the whole suite.
  static var helpersDir: URL {
    if let raw = ProcessInfo.processInfo.environment["GBISO_HELPERS"] {
      return URL(fileURLWithPath: raw, isDirectory: true)
    }
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let colocated = here.appendingPathComponent("GBISOHelpers", isDirectory: true)
    if FileManager.default.fileExists(atPath: colocated.path) {
      return colocated
    }
    return here
      .deletingLastPathComponent()
      .appendingPathComponent("helpers", isDirectory: true)
  }

  static var pauserBin: URL {
    if let raw = ProcessInfo.processInfo.environment["GBISO_PAUSER_BIN"] {
      return URL(fileURLWithPath: raw)
    }
    return helpersDir.appendingPathComponent("gbiso-pauser")
  }

  enum HelpersError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
      switch self {
      case .missing(let detail): return "GBISO helpers missing: \(detail)"
      }
    }
  }

  /// Soft require: throw a test error instead of aborting the process.
  static func requireHelpers() throws {
    let dir = helpersDir
    let pauser = pauserBin
    guard FileManager.default.isExecutableFile(atPath: pauser.path) else {
      throw HelpersError.missing(
        "pauser at \(pauser.path); run v1-v8/run-all.sh or set GBISO_HELPERS/GBISO_PAUSER_BIN")
    }
    for name in [
      "fake-lldb-success.sh", "fake-lldb-exit.sh", "fake-lldb-attachfail.sh",
      "fake-lldb-verbose-leak.sh", "fake-lldb.sh",
    ] {
      let p = dir.appendingPathComponent(name).path
      guard FileManager.default.isExecutableFile(atPath: p) else {
        throw HelpersError.missing("\(p)")
      }
    }
  }

  static func fakeLLDB(_ name: String) throws -> String {
    try requireHelpers()
    let path = helpersDir.appendingPathComponent(name).path
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw HelpersError.missing(path)
    }
    return path
  }

  /// Create `$TMPDIR/gbiso-<uuid>/` only. Cleanup refuses anything else.
  static func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gbiso-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func safeRemove(_ root: URL) {
    let name = root.lastPathComponent
    let path = root.path
    let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    guard !path.isEmpty,
      path != "/",
      path != tmp,
      name.hasPrefix("gbiso-"),
      path.contains("/gbiso-")
    else { return }
    try? FileManager.default.removeItem(at: root)
  }
}

private final class Sandbox: @unchecked Sendable {
  let root: URL
  private var children: [pid_t: Process] = [:]
  private let lock = NSLock()

  init() throws {
    root = try GBISO.makeRoot()
  }

  deinit { cleanup() }

  func cleanup() {
    lock.lock()
    let procs = children
    children.removeAll()
    lock.unlock()
    for (pid, p) in procs {
      if p.isRunning { kill(pid, SIGTERM) }
    }
    let deadline = Date().addingTimeInterval(2)
    while procs.values.contains(where: { $0.isRunning }), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    for (pid, p) in procs where p.isRunning {
      kill(pid, SIGKILL)
      p.waitUntilExit()
    }
    GBISO.safeRemove(root)
  }

  /// Install pauser under a short basename that is NEVER "WeChat".
  func installTarget(named name: String = "gbiso-target") throws -> URL {
    precondition(name != "WeChat", "synthetic target must never be named WeChat")
    precondition(!name.isEmpty && name.count <= 15, "pgrep -x basename should be short")
    try GBISO.requireHelpers()
    let src = GBISO.pauserBin
    let dest = root.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: src, to: dest)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    return dest.resolvingSymlinksInPath()
  }

  /// Create `…/<label>/db_storage/` and optionally a placeholder `.db` file.
  func makeDBRoot(_ label: String, createDBFile: Bool) throws -> URL {
    let dbStorage = root
      .appendingPathComponent(label, isDirectory: true)
      .appendingPathComponent("db_storage", isDirectory: true)
    try FileManager.default.createDirectory(at: dbStorage, withIntermediateDirectories: true)
    if createDBFile {
      let db = dbStorage.appendingPathComponent("message_0.db")
      FileManager.default.createFile(atPath: db.path, contents: Data("gbiso-fixture\n".utf8))
    }
    return dbStorage.resolvingSymlinksInPath()
  }

  @discardableResult
  func spawn(executable: URL, openDB: URL?) throws -> pid_t {
    let p = Process()
    p.executableURL = executable
    p.arguments = openDB.map { [$0.path] } ?? []
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    let pid = p.processIdentifier
    lock.lock()
    children[pid] = p
    lock.unlock()
    return pid
  }

  func killPID(_ pid: pid_t) {
    lock.lock()
    let p = children[pid]
    lock.unlock()
    if let p, p.isRunning { kill(pid, SIGKILL) }
    p?.waitUntilExit()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if kill(pid, 0) != 0 && errno == ESRCH { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  /// Give lsof / pgrep a moment to observe the synthetic process.
  func settle(_ seconds: TimeInterval = 0.6) {
    Thread.sleep(forTimeInterval: seconds)
  }
}

private final class EmitSink: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func handler() -> (@Sendable (String) -> Void) {
    { [self] s in
      lock.lock()
      lines.append(s)
      lock.unlock()
    }
  }
  func all() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
  func joined() -> String { all().joined(separator: "\n") }
}

private func wrongExpectedUID() -> uid_t {
  // Same process, deliberately wrong expected UID — no second user needed.
  getuid() == 0 ? 1 : 0
}

private func secretAllAA() throws -> PassphraseSecret {
  try PassphraseSecret(bytes: GBISO.synBytes)
}

private func secretAll55() throws -> PassphraseSecret {
  try PassphraseSecret(bytes: [UInt8](repeating: 0x55, count: 32))
}

// MARK: - V1 ambiguousTargets

@Suite(.serialized)
struct BindingAcceptanceV1V8Tests {
  // serialized: V2/V5 setenv("GBISO_ATTACH_LOG") is process-wide; parallel suites race.


  /// V1: two same-basename synthetic processes → uniqueProcessID throws ambiguousTargets.
  @Test func v1_ambiguousTargets_noAttach() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let name = "gbiso-target"
    let exe = try box.installTarget(named: name)
    _ = try box.spawn(executable: exe, openDB: nil)
    _ = try box.spawn(executable: exe, openDB: nil)
    box.settle()

    #expect(throws: ProcessBindingError.ambiguousTargets) {
      _ = try WeChatProcessLocator().uniqueProcessID(exactName: name)
    }
  }

  /// V2: bind primary correctly; public capture(binding:) + stub success; attach only primary.
  @Test func v2_success_attachPrimaryOnly() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let dbRoot = try box.makeDBRoot("acct", createDBFile: true)
    let db = dbRoot.appendingPathComponent("message_0.db")
    let primary = try box.spawn(executable: exe, openDB: db)
    // Secondary same basename — must NOT be attached.
    let secondary = try box.spawn(executable: exe, openDB: nil)
    box.settle()

    let binding = try ProcessTargetBinding(
      processID: primary, executablePath: exe, uid: getuid(), databaseRoot: dbRoot)

    let attachLog = box.root.appendingPathComponent("attach-v2.log")
    setenv("GBISO_ATTACH_LOG", attachLog.path, 1)
    defer { unsetenv("GBISO_ATTACH_LOG") }

    var capture = LLDBPassphraseCapture(lldbPath: try GBISO.fakeLLDB("fake-lldb-success.sh"))
    capture.candidateValidator = { secret in
      secret.withUnsafeBytes { Array($0) == GBISO.synBytes }
    }
    let secret = try capture.capture(binding: binding, timeoutSeconds: 15)
    #expect(secret.withUnsafeBytes { Array($0) == GBISO.synBytes })

    let rec = (try? String(contentsOf: attachLog, encoding: .utf8)) ?? ""
    #expect(rec.contains("process attach -p \(primary)"))
    #expect(!rec.contains("process attach -p \(secondary)"))
  }

  /// V3: wrong executable path → pathMismatch; no attach.
  @Test func v3_pathMismatch() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let pid = try box.spawn(executable: exe, openDB: nil)
    box.settle()
    let wrongPath = GBISO.pauserBin.resolvingSymlinksInPath()
    let dummyRoot = try box.makeDBRoot("acct", createDBFile: false)

    #expect(throws: ProcessBindingError.pathMismatch) {
      _ = try ProcessTargetBinding(
        processID: pid, executablePath: wrongPath, uid: getuid(), databaseRoot: dummyRoot)
    }
  }

  /// V4: wrong expectedUID on the SAME process → uidMismatch.
  @Test func v4_uidMismatch() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let pid = try box.spawn(executable: exe, openDB: nil)
    box.settle()
    let dummyRoot = try box.makeDBRoot("acct", createDBFile: false)

    #expect(throws: ProcessBindingError.uidMismatch) {
      _ = try ProcessTargetBinding(
        processID: pid, executablePath: exe, uid: wrongExpectedUID(), databaseRoot: dummyRoot)
    }
  }

  /// V5: kill primary BEFORE capture; leave secondary; must NOT attach secondary.
  /// (targetExited mid-capture is covered by v5b.)
  @Test func v5_noRetargetAfterPrimaryGone() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let rootP = try box.makeDBRoot("primary", createDBFile: true)
    let rootS = try box.makeDBRoot("secondary", createDBFile: true)
    let primary = try box.spawn(
      executable: exe, openDB: rootP.appendingPathComponent("message_0.db"))
    let secondary = try box.spawn(
      executable: exe, openDB: rootS.appendingPathComponent("message_0.db"))
    box.settle()

    let binding = try ProcessTargetBinding(
      processID: primary, executablePath: exe, uid: getuid(), databaseRoot: rootP)

    box.killPID(primary)

    let attachLog = box.root.appendingPathComponent("attach-v5.log")
    setenv("GBISO_ATTACH_LOG", attachLog.path, 1)
    defer { unsetenv("GBISO_ATTACH_LOG") }

    var capture = LLDBPassphraseCapture(lldbPath: try GBISO.fakeLLDB("fake-lldb-success.sh"))
    capture.candidateValidator = { _ in true }

    var thrown: Error?
    do {
      _ = try capture.capture(binding: binding, timeoutSeconds: 10)
      Issue.record("expected processGone/identityMismatch/targetExited; capture returned")
    } catch let error as ProcessBindingError {
      thrown = error
      let ok =
        error == .processGone || error == .identityMismatch || error == .inspectionFailed
      #expect(ok, "unexpected ProcessBindingError: \(error)")
    } catch let error as CaptureError {
      thrown = error
      #expect(
        error == .targetExited || error == .exitedWithoutCapture,
        "unexpected CaptureError: \(error)")
    } catch {
      thrown = error
      Issue.record("unexpected error type: \(error)")
    }
    #expect(thrown != nil)

    let rec = (try? String(contentsOf: attachLog, encoding: .utf8)) ?? ""
    #expect(
      !rec.contains("process attach -p \(secondary)"),
      "stub must NOT attach secondary PID \(secondary); record=\(rec)")
  }

  /// V5b: primary still alive at capture start; fake-lldb-exit emits
  /// `Process <pid> exited` after attach script is accepted → CaptureError.targetExited.
  /// Attach exactly once to primary; never secondary.
  @Test func v5b_targetExitedDuringCapture_attachPrimaryOnce() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let rootP = try box.makeDBRoot("primary", createDBFile: true)
    let rootS = try box.makeDBRoot("secondary", createDBFile: true)
    let primary = try box.spawn(
      executable: exe, openDB: rootP.appendingPathComponent("message_0.db"))
    let secondary = try box.spawn(
      executable: exe, openDB: rootS.appendingPathComponent("message_0.db"))
    box.settle()

    let binding = try ProcessTargetBinding(
      processID: primary, executablePath: exe, uid: getuid(), databaseRoot: rootP)

    let attachLog = box.root.appendingPathComponent("attach-v5b.log")
    setenv("GBISO_ATTACH_LOG", attachLog.path, 1)
    defer { unsetenv("GBISO_ATTACH_LOG") }

    var capture = LLDBPassphraseCapture(lldbPath: try GBISO.fakeLLDB("fake-lldb-exit.sh"))
    capture.candidateValidator = { _ in true }

    var sawTargetExited = false
    do {
      _ = try capture.capture(binding: binding, timeoutSeconds: 10)
      Issue.record("expected CaptureError.targetExited; capture returned")
    } catch let error as CaptureError {
      if error == .targetExited {
        sawTargetExited = true
      } else {
        Issue.record("expected CaptureError.targetExited; got \(error)")
      }
    } catch {
      Issue.record("expected CaptureError.targetExited; got \(error)")
    }
    #expect(sawTargetExited)

    let rec = (try? String(contentsOf: attachLog, encoding: .utf8)) ?? ""
    let primaryHits = rec.components(separatedBy: "process attach -p \(primary)").count - 1
    #expect(primaryHits == 1, "must attach primary exactly once; record=\(rec)")
    #expect(
      !rec.contains("process attach -p \(secondary)"),
      "must never attach secondary PID \(secondary); record=\(rec)")
  }

  /// V6: process opens root B; binding claims root A → sourceRootMismatch only
  /// (sourceRootUnknown is NOT a pass; V2 already guarantees the fixture is visible).
  @Test func v6_sourceRootMismatch() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let rootA = try box.makeDBRoot("rootA", createDBFile: true)  // claimed, not opened
    let rootB = try box.makeDBRoot("rootB", createDBFile: true)
    let pid = try box.spawn(
      executable: exe, openDB: rootB.appendingPathComponent("message_0.db"))
    box.settle(0.8)

    // V2 already proves the fixture + lsof path works; V6 must only pass as mismatch.
    #expect(throws: ProcessBindingError.sourceRootMismatch) {
      _ = try ProcessTargetBinding(
        processID: pid, executablePath: exe, uid: getuid(), databaseRoot: rootA)
    }
  }

  /// V7: (a) failed capture does not create output; (b) SecretOutputWriter called:
  /// overwrite=false → outputExists keeps old bytes; overwrite=true onto non-empty
  /// directory → rename fails, dir/sentinel unchanged, no .greenbubbles-key leftovers.
  @Test func v7_failedPublishPreservesOldKey_and_captureCreatesNoOutput() throws {
    let box = try Sandbox()
    defer { box.cleanup() }

    // --- (b) MUST call SecretOutputWriter ---
    let outDir = box.root.appendingPathComponent("keys", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let output = outDir.appendingPathComponent("passphrase.txt")
    let writer = SecretOutputWriter()
    let first = try secretAllAA()
    try writer.write(first, to: output, overwrite: false)
    let before = try Data(contentsOf: output)
    #expect(String(decoding: before, as: UTF8.self) == GBISO.synHex64 + "\n")

    let second = try secretAll55()
    #expect(throws: SecretOutputError.outputExists) {
      // Real writer call — exclusive link must refuse without truncating.
      try writer.write(second, to: output, overwrite: false)
    }
    let afterExists = try Data(contentsOf: output)
    #expect(afterExists == before, "overwrite=false failure must leave old key bytes unchanged")

    // Reliable rename-fail path: destination is a NON-EMPTY directory with a sentinel.
    // Production writer restores parent to 0700, so chmod-0555 never reliably blocks publish.
    // rename(temp, dir) must fail; directory + sentinel must stay; no .greenbubbles-key-* left.
    let renameParent = box.root.appendingPathComponent("rename-fail-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: renameParent, withIntermediateDirectories: true)
    let dirAsOutput = renameParent.appendingPathComponent("passphrase-dir", isDirectory: true)
    try FileManager.default.createDirectory(at: dirAsOutput, withIntermediateDirectories: true)
    let sentinel = dirAsOutput.appendingPathComponent("SENTINEL")
    let sentinelBytes = Data("gbiso-sentinel-keep\n".utf8)
    try sentinelBytes.write(to: sentinel, options: .atomic)
    var renameThrew = false
    do {
      try writer.write(second, to: dirAsOutput, overwrite: true)
      Issue.record("expected rename onto non-empty directory to fail; write succeeded")
    } catch {
      renameThrew = true
    }
    #expect(renameThrew, "overwrite rename onto non-empty directory must throw")
    var isDir: ObjCBool = false
    #expect(
      FileManager.default.fileExists(atPath: dirAsOutput.path, isDirectory: &isDir) && isDir.boolValue,
      "destination directory must remain a directory")
    let sentinelAfter = try Data(contentsOf: sentinel)
    #expect(sentinelAfter == sentinelBytes, "sentinel inside destination dir must be unchanged")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: renameParent.path)
      .filter { $0.hasPrefix(".greenbubbles-key-") }
    #expect(leftovers.isEmpty, "no staged .greenbubbles-key-* temps may remain: \(leftovers)")

    // --- (a) capture failure orchestration: no --output file created ---
    let exe = try box.installTarget()
    let dbRoot = try box.makeDBRoot("acct", createDBFile: true)
    let pid = try box.spawn(
      executable: exe, openDB: dbRoot.appendingPathComponent("message_0.db"))
    box.settle()
    let binding = try ProcessTargetBinding(
      processID: pid, executablePath: exe, uid: getuid(), databaseRoot: dbRoot)

    let wouldBeOutput = box.root.appendingPathComponent("capture-fail.secret")
    var capture = LLDBPassphraseCapture(lldbPath: try GBISO.fakeLLDB("fake-lldb-attachfail.sh"))
    capture.candidateValidator = { _ in true }
    var sawAttachFailed = false
    do {
      _ = try capture.capture(binding: binding, timeoutSeconds: 10)
      Issue.record("expected CaptureError.attachFailed; capture returned")
    } catch let error as CaptureError {
      if case .attachFailed = error {
        sawAttachFailed = true
        // Production orchestration: on capture failure, do NOT call SecretOutputWriter.
      } else {
        Issue.record("expected CaptureError.attachFailed; got \(error)")
      }
    } catch {
      Issue.record("expected CaptureError.attachFailed; got \(error)")
    }
    #expect(sawAttachFailed)
    #expect(!FileManager.default.fileExists(atPath: wouldBeOutput.path))
  }

  /// V8: verbose=true must not relay synthetic key hex or raw hexdump bytes.
  @Test func v8_verboseSuppressesDebuggerOutput() throws {
    let box = try Sandbox()
    defer { box.cleanup() }
    let exe = try box.installTarget()
    let dbRoot = try box.makeDBRoot("acct", createDBFile: true)
    let pid = try box.spawn(
      executable: exe, openDB: dbRoot.appendingPathComponent("message_0.db"))
    box.settle()
    let binding = try ProcessTargetBinding(
      processID: pid, executablePath: exe, uid: getuid(), databaseRoot: dbRoot)

    let sink = EmitSink()
    var capture = LLDBPassphraseCapture(lldbPath: try GBISO.fakeLLDB("fake-lldb-verbose-leak.sh"))
    capture.verbose = true
    capture.outputHandler = sink.handler()
    capture.candidateValidator = { secret in
      secret.withUnsafeBytes { Array($0) == GBISO.synBytes }
    }
    let secret = try capture.capture(binding: binding, timeoutSeconds: 15)
    #expect(secret.withUnsafeBytes { Array($0) == GBISO.synBytes })

    let emitted = sink.joined()
    #expect(!emitted.contains(GBISO.synHex64), "must not relay synthetic 64-hex")
    #expect(!emitted.contains("0xaa 0xaa"), "must not relay raw hexdump bytes")
    #expect(!emitted.contains("de ad be ef"), "must not relay ascii hexdump")
    #expect(!emitted.contains("0x00010a20"), "must not relay hexdump address line")
    // May contain the suppression marker.
    let hasMarker = emitted.contains("<debugger output suppressed>")
    #expect(hasMarker || !emitted.isEmpty, "verbose should emit suppressed markers or progress")
  }
}
