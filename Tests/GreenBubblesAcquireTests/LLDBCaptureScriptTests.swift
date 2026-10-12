import Foundation
import Testing

@testable import GreenBubblesAcquire

struct LLDBCaptureScriptTests {
  private let provenOrdering = [
    "settings set target.preload-symbols false",
    "process attach -p 4242",
    "breakpoint set -n CCKeyDerivationPBKDF",
    "breakpoint command add 1",
    "memory read --size 1 --count 32 --format x",
    "DONE",
    "process continue",
  ]

  @Test func arm64ScriptUsesArgumentRegistersInProvenOrder() {
    let script = LLDBCaptureScript.script(processID: 4242, architecture: .arm64)
    #expect(
      script.contains(
        "breakpoint set -n CCKeyDerivationPBKDF -c '$x0 == 2 && $x2 == 32 && $x4 == 16 && $x5 == 5 && $x6 == 256000'"
      ))
    #expect(script.contains("memory read --size 1 --count 32 --format x $x1"))
    #expect(script.hasSuffix("process continue\n"))
    #expect(!script.contains("detach"))
    #expect(!script.contains("quit"))
    assertProvenOrdering(in: script)
  }

  @Test func x86_64ScriptUsesArgumentRegistersInProvenOrder() {
    let script = LLDBCaptureScript.script(processID: 4242, architecture: .x86_64)
    #expect(
      script.contains(
        "breakpoint set -n CCKeyDerivationPBKDF -c '$rdi == 2 && $rdx == 32 && $r8 == 16 && $r9 == 5 && *(unsigned int *)($rsp + 8) == 256000'"
      ))
    #expect(script.contains("memory read --size 1 --count 32 --format x $rsi"))
    #expect(!script.contains("detach"))
    #expect(!script.contains("quit"))
    assertProvenOrdering(in: script)
  }

  @Test func registersMatchArchitecture() {
    #expect(LLDBTargetArchitecture.arm64.passwordRegister == "x1")
    #expect(LLDBTargetArchitecture.arm64.lengthRegister == "x2")
    #expect(LLDBTargetArchitecture.x86_64.passwordRegister == "rsi")
    #expect(LLDBTargetArchitecture.x86_64.lengthRegister == "rdx")
  }

  private func assertProvenOrdering(in script: String) {
    var lastIndex = script.startIndex
    for command in provenOrdering {
      guard let range = script.range(of: command) else {
        Issue.record("generated script is missing: \(command)")
        return
      }
      #expect(range.lowerBound >= lastIndex)
      lastIndex = range.lowerBound
    }
  }
}
