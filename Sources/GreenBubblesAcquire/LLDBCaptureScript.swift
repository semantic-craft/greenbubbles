// Derived from wcdb-key-tool (https://github.com/TANGandXUE/wcdb-key-tool), MIT license.

import Foundation

public enum LLDBTargetArchitecture: String, Sendable {
  case arm64
  // swift-format-ignore: AlwaysUseLowerCamelCase
  case x86_64

  public static var current: LLDBTargetArchitecture {
    #if arch(arm64)
      return .arm64
    #else
      return .x86_64
    #endif
  }

  /// Register holding `CCKeyDerivationPBKDF`'s `password` argument.
  public var passwordRegister: String {
    switch self {
    case .arm64: return "x1"
    case .x86_64: return "rsi"
    }
  }

  /// SQLCipher 4 PBKDF2 parameters. x86_64's seventh argument is on the stack.
  public var sqlCipherCondition: String {
    switch self {
    case .arm64:
      return "$x0 == 2 && $x2 == 32 && $x4 == 16 && $x5 == 5 && $x6 == 256000"
    case .x86_64:
      return
        "$rdi == 2 && $rdx == 32 && $r8 == 16 && $r9 == 5 && *(unsigned int *)($rsp + 8) == 256000"
    }
  }

  /// Register holding `CCKeyDerivationPBKDF`'s `passwordLen` argument.
  public var lengthRegister: String {
    switch self {
    case .arm64: return "x2"
    case .x86_64: return "rdx"
    }
  }
}

/// Generates the lldb command script whose ordering was validated live against
/// the pinned WeChat build: attach, break on the system `CCKeyDerivationPBKDF`
/// symbol for SQLCipher 4 parameters, then read a candidate and remain stopped.
/// The capture loop verifies it before deciding to resume or detach.
public enum LLDBCaptureScript {
  public static func script(
    processID: pid_t,
    architecture: LLDBTargetArchitecture = .current
  ) -> String {
    """
    settings set target.preload-symbols false
    process attach -p \(processID)
    breakpoint set -n CCKeyDerivationPBKDF -c '\(architecture.sqlCipherCondition)'
    breakpoint command add 1
    memory read --size 1 --count 32 --format x $\(architecture.passwordRegister)
    DONE
    process continue

    """
  }
}
