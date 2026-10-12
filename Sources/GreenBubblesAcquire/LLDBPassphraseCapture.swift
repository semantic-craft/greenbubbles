// Derived from wcdb-key-tool (https://github.com/TANGandXUE/wcdb-key-tool), MIT license.

import Darwin
import Foundation

public enum CaptureError: Error, Equatable, CustomStringConvertible {
  case verifierRequired
  case lldbUnavailable
  case lldbLaunchFailed
  case attachFailed(String)
  case noWeChatProcess
  case targetExited
  case timedOut
  case exitedWithoutCapture

  public var description: String {
    switch self {
    case .verifierRequired:
      return "A database candidate verifier is required before capture"
    case .lldbUnavailable:
      return "lldb is not available; install the Xcode Command Line Tools"
    case .lldbLaunchFailed:
      return "lldb could not be launched"
    case .attachFailed(let detail):
      return "lldb could not attach to WeChat: \(detail)"
    case .noWeChatProcess:
      return "WeChat is not running; start it and log in before capturing"
    case .targetExited:
      return "the WeChat process exited before a passphrase was captured"
    case .timedOut:
      return
        "No passphrase was captured before the timeout; log out of WeChat and log back in while the capture is armed"
    case .exitedWithoutCapture:
      return "lldb exited before a passphrase was captured"
    }
  }
}

/// Attaches lldb to a running WeChat process and captures the 32-byte
/// SQLCipher passphrase passed to the system `CCKeyDerivationPBKDF` function
/// when the owner logs out and back in.
///
/// The lldb script is written to a stdin pipe that stays open for the whole
/// capture window (lldb must not see EOF while it waits for the breakpoint).
/// stdout and stderr are accumulated incrementally and re-parsed after every
/// chunk; each candidate is verified while the target is stopped; rejected candidates
/// resume capture within the same deadline.
/// Only the child process spawned here is ever terminated — never `pkill`.
///
/// Attachment failures and target exits stop this attempt. No replacement
/// process is discovered or attached automatically.
public struct LLDBPassphraseCapture: Sendable {
  public static let defaultTimeoutSeconds = 300

  private let lldbPath: String

  public init(lldbPath: String = "/usr/bin/lldb") {
    self.lldbPath = lldbPath
  }

  public var lldbAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: lldbPath)
  }

  /// Called with human-readable capture events (startup, rejection, failure
  /// hints) and, when verbose is set, notices that debugger output arrived.
  public var outputHandler: (@Sendable (String) -> Void)?

  /// Reports debugger output activity without relaying its potentially sensitive text.
  public var verbose = false

  /// Required database verifier. False resumes capture; errors abort without saving.
  public var candidateValidator: (@Sendable (PassphraseSecret) throws -> Bool)?

  private func emit(_ message: String) {
    outputHandler?(message)
  }

  /// Capture only the bound process. Exit or identity changes require a new invocation.
  public func capture(
    binding: ProcessTargetBinding,
    architecture: LLDBTargetArchitecture = .current,
    timeoutSeconds: Int = LLDBPassphraseCapture.defaultTimeoutSeconds
  ) throws -> PassphraseSecret {
    guard lldbAvailable else { throw CaptureError.lldbUnavailable }
    try binding.assertStillBound()
    emit("starting debugger for the explicitly bound process")
    let secret = try runSingleCapture(
      processID: binding.processID,
      architecture: architecture,
      deadline: Date().addingTimeInterval(TimeInterval(timeoutSeconds)),
      binding: binding
    )
    try binding.assertStillBound()
    return secret
  }

  func runSingleCapture(
    processID: pid_t,
    architecture: LLDBTargetArchitecture,
    deadline: Date,
    binding: ProcessTargetBinding? = nil
  ) throws -> PassphraseSecret {
    guard let candidateValidator else { throw CaptureError.verifierRequired }
    let script = LLDBCaptureScript.script(processID: processID, architecture: architecture)

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "dumb"
    process.environment = environment
    process.executableURL = URL(fileURLWithPath: lldbPath)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output

    let accumulator = OutputAccumulator()
    let verboseRelay = verbose ? VerboseLineRelay(emit: { [self] in emit($0) }) : nil
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty {
        accumulator.append(data)
        verboseRelay?.append(data)
      }
    }

    try binding?.assertStillBound()
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      throw CaptureError.lldbLaunchFailed
    }
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      verboseRelay?.flush()
      // Ask LLDB to detach before terminating only our child. No global kill.
      if process.isRunning {
        input.fileHandleForWriting.write(Data("process detach\nquit\n".utf8))
      }
      if process.isRunning {
        let graceDeadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < graceDeadline {
          Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
      }
      try? input.fileHandleForWriting.close()
    }

    // Keep stdin open after writing the script: lldb must not read EOF while
    // it waits for the breakpoint to hit.
    try binding?.assertStillBound()
    input.fileHandleForWriting.write(Data(script.utf8))

    while Date() < deadline {
      if !process.isRunning {
        // Allow the pipe reader to drain the debugger's final chunk.
        Thread.sleep(forTimeInterval: 0.1)
      }
      let current = accumulator.current()
      if let captured = LLDBOutputParser.parsePassphrase(from: current) {
        let candidate = try Self.makeSecret(consuming: captured)
        if try candidateValidator(candidate) {
          return candidate
        }
        emit("candidate rejected by database verification; continuing capture")
        accumulator.clear()
        guard process.isRunning else { throw CaptureError.exitedWithoutCapture }
        input.fileHandleForWriting.write(Data("process continue\n".utf8))
        continue
      }
      if LLDBOutputParser.detectAttachFailure(in: current) != nil {
        throw CaptureError.attachFailed("the debugger rejected the attachment")
      }
      if LLDBOutputParser.detectTargetExit(in: current) {
        throw CaptureError.targetExited
      }
      if !process.isRunning { throw CaptureError.exitedWithoutCapture }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw CaptureError.timedOut
  }

  private static func makeSecret(consuming bytes: [UInt8]) throws -> PassphraseSecret {
    var bytes = bytes
    defer { PassphraseSecret.zeroize(&bytes) }
    return try PassphraseSecret(bytes: bytes)
  }

  private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = String()

    func append(_ data: Data) {
      lock.lock()
      buffer.append(String(decoding: data, as: UTF8.self))
      lock.unlock()
    }

    func clear() {
      lock.lock()
      buffer = ""
      lock.unlock()
    }

    func current() -> String {
      lock.lock()
      defer { lock.unlock() }
      return buffer
    }
  }

  /// Line-buffered verbose relay. Chunks from the pipe can split lines
  /// anywhere, so redaction must wait for complete lines: a `memory read`
  /// hexdump line carries the captured passphrase and is never emitted.
  private final class VerboseLineRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let emitLine: (String) -> Void

    init(emit: @escaping (String) -> Void) {
      self.emitLine = emit
    }

    func append(_ data: Data) {
      lock.lock()
      pending.append(String(decoding: data, as: UTF8.self))
      var lines: [String] = []
      while let newline = pending.firstIndex(of: "\n") {
        lines.append(String(pending[pending.startIndex..<newline]))
        pending.removeSubrange(pending.startIndex...newline)
      }
      lock.unlock()
      for line in lines {
        emitLine("lldb| \(redact(line))")
      }
    }

    func flush() {
      lock.lock()
      let rest = pending
      pending = ""
      lock.unlock()
      guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
      emitLine("lldb| \(redact(rest))")
    }

    private func redact(_ line: String) -> String {
      // Debugger diagnostics can contain arbitrary memory, not only recognized hexdumps.
      // Keep verbose progress useful without relaying untrusted debugger text.
      return "<debugger output suppressed>"
    }
  }
}
