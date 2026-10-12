import Foundation
import Testing

@testable import GreenBubblesAcquire

struct CaptureCandidateTests {
  @Test(arguments: [true, false])
  func rejectedCandidateDoesNotEndCapture(eventuallyValid: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let debugger = directory.appendingPathComponent("fake-lldb")
    // Exercise the real process/pipe/parser loop. The fake debugger remains stopped
    // until the caller resumes it after rejecting the first synthetic candidate.
    let dumpA = "0x1000: " + Array(repeating: "0x11", count: 32).joined(separator: " ")
    let dumpB = "0x2000: " + Array(repeating: "0x22", count: 32).joined(separator: " ")
    let nextOutput = eventuallyValid ? "printf '%s\\n' '\(dumpB)'" : ":"
    let script = """
      #!/bin/sh
      while IFS= read -r line; do
        [ "$line" = "process continue" ] && break
      done
      printf '%s\\n' '\(dumpA)'
      while IFS= read -r line; do
        if [ "$line" = "process continue" ]; then
          \(nextOutput)
        elif [ "$line" = "quit" ]; then
          exit 0
        fi
      done
      """
    try script.write(to: debugger, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: debugger.path)
    var capture = LLDBPassphraseCapture(lldbPath: debugger.path)
    capture.candidateValidator = { secret in
      secret.withUnsafeBytes { Array($0) == Array(repeating: UInt8(0x22), count: 32) }
    }
    if !eventuallyValid {
      #expect(throws: CaptureError.timedOut) {
        try capture.runSingleCapture(
          processID: 4242, architecture: .arm64,
          deadline: Date().addingTimeInterval(0.5))
      }
      return
    }
    let secret = try capture.runSingleCapture(
      processID: 4242, architecture: .arm64,
      deadline: Date().addingTimeInterval(3))
    #expect(secret.withUnsafeBytes { Array($0) == Array(repeating: UInt8(0x22), count: 32) })
  }
}
