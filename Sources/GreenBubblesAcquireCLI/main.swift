// Derived from wcdb-key-tool (https://github.com/TANGandXUE/wcdb-key-tool), MIT license.

import Darwin
import Foundation
import GreenBubblesAcquire
import GreenBubblesCore

enum CLIError: Error, CustomStringConvertible {
  case invalidOption(String)
  case missingValue(String)
  case missingRequiredOption(String)
  case invalidInteger(option: String, value: String)
  case noDatabaseRootDiscovered
  case verificationFailed(String)

  var description: String {
    switch self {
    case .invalidOption(let option):
      return "Unknown option: \(option)"
    case .missingValue(let option):
      return "Missing value for \(option)"
    case .missingRequiredOption(let option):
      return "Missing required option: \(option)"
    case .invalidInteger(let option, let value):
      return "Expected a positive integer for \(option), got: \(value)"
    case .noDatabaseRootDiscovered:
      return "No unique WeChat database root was discovered; pass --db-root to select one"
    case .verificationFailed(let reason):
      return "Passphrase verification failed: \(reason)"
    }
  }
}

struct Arguments {
  enum Command: String {
    case preflight
    case capture
    case verify
    case help
  }

  var command: Command = .help
  var processID: pid_t?
  var executablePath: URL?
  var uid: uid_t?
  var output: URL?
  var timeoutSeconds = LLDBPassphraseCapture.defaultTimeoutSeconds
  var dbRoot: URL?
  var overwrite = false
  var passphraseStdin = false
  var includePaths = false
  var json = false
  var verbose = false

  init(_ rawArguments: [String]) throws {
    var arguments = rawArguments
    if let first = arguments.first, !first.hasPrefix("-") {
      command = Command(rawValue: first) ?? .help
      if Command(rawValue: first) == nil {
        throw CLIError.invalidOption(first)
      }
      arguments.removeFirst()
    }

    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      switch option {
      case "--pid", "--uid":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(option) }
        let value = arguments[index]
        if option == "--pid" {
          guard let number = pid_t(value), number > 0 else {
            throw CLIError.invalidInteger(option: option, value: value)
          }
          processID = number
        } else {
          guard let number = uid_t(value) else {
            throw CLIError.invalidInteger(option: option, value: value)
          }
          uid = number
        }
      case "--executable-path":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(option) }
        executablePath = URL(fileURLWithPath: arguments[index])
      case "--output":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(option) }
        output = URL(fileURLWithPath: arguments[index])
      case "--owner-authorized":
        // Accepted for backward compatibility; owner consent is implicit in
        // running this deliberately gated helper. Ignored.
        break
      case "--timeout-seconds":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(option) }
        let value = arguments[index]
        guard let number = Int(value), number > 0 else {
          throw CLIError.invalidInteger(option: option, value: value)
        }
        timeoutSeconds = number
      case "--db-root":
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(option) }
        dbRoot = URL(fileURLWithPath: arguments[index])
      case "--overwrite":
        overwrite = true
      case "--passphrase-stdin":
        passphraseStdin = true
      case "--include-paths":
        includePaths = true
      case "--json":
        json = true
      case "--verbose":
        verbose = true
      case "-h", "--help":
        command = .help
      default:
        throw CLIError.invalidOption(option)
      }
      index += 1
    }
  }
}

private let protectedClientRemediation =
  "Preserve the official WeChat application. Use an existing verified key, "
  + "or a separately validated acquisition environment; do not re-sign the primary app."

private let usage = """
  Usage: greenbubbles-acquire <command> [options]

  Commands:
    preflight              Check capture readiness; exits non-zero when blocked
    capture                Attach lldb to WeChat and capture the database passphrase
    verify                 Re-validate a stored passphrase read from standard input
    help                   Show this help

  Options:
    --pid <n>             Explicit capture/preflight process (required)
    --executable-path <p> Expected executable path (required for capture/preflight)
    --uid <n>             Expected process owner (defaults to invoking user)
    --output <path>        Capture destination (required, mode 0600)
    --timeout-seconds <n>  Capture window in seconds (default: 300)
    --db-root <path>       Explicit db_storage root (required for capture/preflight)
    --overwrite            Replace an existing passphrase output file
    --passphrase-stdin     Read the 32-byte passphrase from standard input
    --include-paths        Include sensitive filesystem paths in local output
    --json                 Emit machine-readable JSON instead of human-readable text
    --verbose              Report debugger output activity without relaying raw text
    -h, --help             Show this help

  Capture requires an explicit process, executable, owner, and open database root.
  It never reselects a target after exit. Unknown hardening or source identity blocks
  capture. Preserve the official WeChat app; a separate acquisition environment
  still needs independent isolation and compatibility validation. Never re-sign
  the primary app. No isolated WeChat acquisition procedure is accepted yet.
  """

private struct PreflightReport: Encodable {
  let formatVersion: Int
  let ready: Bool
  let blockers: [String]
  let remediation: String?
  let lldbAvailable: Bool
  let runningAsRoot: Bool
  let wechatProcessRunning: Bool
  let processHardeningStatus: ProcessHardeningStatus?
  let clientInstalled: Bool
  let clientReSigned: Bool
  let clientMarketingVersion: String?
  let clientBuildVersion: String?
  let databaseRoot: PathReference?
  let databaseRootAutoDiscovered: Bool
  let databaseCount: Int?
  let distinctSaltCount: Int?
}

private struct VerificationReport: Encodable {
  let formatVersion: Int
  let databaseCount: Int
  let distinctSaltCount: Int
  let verifiedSaltCount: Int
  let allVerified: Bool
}

private struct PreflightCheck {
  let ok: Bool
  let label: String
  let hint: String?
}

private struct PreflightResult {
  let report: PreflightReport
  let checks: [PreflightCheck]
}

private func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  encoder.dateEncodingStrategy = .iso8601
  let data = try encoder.encode(value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

private func printError(_ message: String) {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
}

private func printNote(_ message: String) {
  FileHandle.standardError.write(Data("note: \(message)\n".utf8))
}

private let stdoutIsTerminal = isatty(FileHandle.standardOutput.fileDescriptor) != 0

private func statusMark(_ ok: Bool) -> String {
  if stdoutIsTerminal {
    return ok ? "\u{1B}[32m✓\u{1B}[0m" : "\u{1B}[31m✗\u{1B}[0m"
  }
  return ok ? "✓" : "✗"
}

// Human-readable rendering: one line per check, then a plain verdict.
private func printPreflight(_ result: PreflightResult) {
  for check in result.checks {
    print("\(statusMark(check.ok)) \(check.label)")
    if !check.ok, let hint = check.hint {
      print("    \(hint)")
    }
  }
  print("")
  let failed = result.checks.filter { !$0.ok }.count
  if result.report.ready {
    print("Ready to capture.")
    print("Next: capture using the same explicit target options and a separate --output path")
  } else {
    print("Not ready — \(failed) \(failed == 1 ? "problem" : "problems") to fix (see above).")
  }
}

// Under sudo the effective home is /var/root, but the WeChat data lives in the
// invoking user's home; SUDO_USER tells us who that is.
private func invokingUserHomeDirectory() -> URL {
  if geteuid() == 0, let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
    let entry = getpwnam(sudoUser), let directory = entry.pointee.pw_dir
  {
    return URL(fileURLWithPath: String(cString: directory)).standardizedFileURL
  }
  return FileManager.default.homeDirectoryForCurrentUser
}

private func resolveDatabaseRoot(_ option: URL?) throws -> URL {
  if let option {
    return option.standardizedFileURL
  }
  let roots = WeChatAccountDiscovery(homeDirectory: invokingUserHomeDirectory())
    .databaseRoots()
  if roots.count == 1 { return roots[0] }
  if roots.isEmpty { throw CLIError.noDatabaseRootDiscovered }
  // An offline verification must not guess between accounts by modification time.
  throw CLIError.noDatabaseRootDiscovered
}

private func resolveTarget(_ arguments: Arguments) throws -> ProcessTargetBinding {
  guard let processID = arguments.processID else { throw CLIError.missingRequiredOption("--pid") }
  guard let executablePath = arguments.executablePath else {
    throw CLIError.missingRequiredOption("--executable-path")
  }
  guard let root = arguments.dbRoot else { throw CLIError.missingRequiredOption("--db-root") }
  let invokingUID: uid_t
  if geteuid() == 0, let value = ProcessInfo.processInfo.environment["SUDO_UID"],
    let sudoUID = uid_t(value)
  {
    invokingUID = sudoUID
  } else {
    invokingUID = getuid()
  }
  return try ProcessTargetBinding(
    processID: processID, executablePath: executablePath,
    uid: arguments.uid ?? invokingUID, databaseRoot: root)
}

private func runPreflight(binding: ProcessTargetBinding, includePaths: Bool) -> PreflightResult {
  var checks: [PreflightCheck] = []
  var remediation: String?

  let lldbAvailable = LLDBPassphraseCapture().lldbAvailable
  checks.append(
    PreflightCheck(
      ok: lldbAvailable,
      label: lldbAvailable ? "lldb is available" : "lldb is not available",
      hint: lldbAvailable ? nil : "install the Xcode Command Line Tools: xcode-select --install"
    ))

  let runningAsRoot = geteuid() == 0
  checks.append(
    PreflightCheck(
      ok: runningAsRoot,
      label: runningAsRoot ? "running as root" : "not running as root",
      hint: runningAsRoot ? nil : "capture needs to attach to WeChat; re-run with sudo"
    ))

  // Inspect the selected application, not another default installation.
  var clientInstalled = false
  var clientReSigned = false
  var clientMarketingVersion: String?
  var clientBuildVersion: String?
  let buildInspector = WeChatClientBuildInspector(homeDirectory: invokingUserHomeDirectory())
  let application = binding.executablePath.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  if FileManager.default.isExecutableFile(atPath: binding.executablePath.path) {
    clientInstalled = true
    if let build = try? buildInspector.inspect(application: application) {
      clientMarketingVersion = build.marketingVersion
      clientBuildVersion = build.buildVersion
      clientReSigned = !build.hardenedRuntime
    }
  }
  checks.append(
    PreflightCheck(
      ok: clientInstalled,
      label: clientInstalled ? "WeChat is installed" : "no WeChat installation was found",
      hint: clientInstalled ? nil : "install WeChat for macOS first"
    ))

  var wechatProcessRunning = false
  var processHardeningStatus: ProcessHardeningStatus? = nil
  var processLabel = "WeChat is not running"
  var processHint: String? = "start WeChat and log in before capturing"
  do {
    wechatProcessRunning = true
    let status = RuntimeHardeningProbe.status(forProcessID: binding.processID)
    processHardeningStatus = status
    let version = [clientMarketingVersion, clientBuildVersion.map { "build \($0)" }]
      .compactMap { $0 }.joined(separator: ", ")
    let suffix = version.isEmpty ? "" : " (\(version))"
    switch status {
    case .hardened:
      processLabel = "WeChat is running\(suffix), but Hardened Runtime is still active"
      processHint = protectedClientRemediation
      remediation = protectedClientRemediation
    case .notHardened:
      processLabel = "WeChat is running\(suffix), Hardened Runtime removed"
      processHint = nil
    case .unknown:
      processLabel = "WeChat is running\(suffix), hardening status unknown (blocked)"
      processHint = "Cannot confirm capture readiness; preserve the client"
    }
  }
  checks.append(
    PreflightCheck(
      ok: wechatProcessRunning && processHardeningStatus == .notHardened,
      label: processLabel,
      hint: processHint
    ))

  var databaseRootReference: PathReference? = nil
  var databaseCount: Int? = nil
  var distinctSaltCount: Int? = nil
  var databaseLabel = "no WeChat database root was discovered"
  var databaseHint: String? = "log into WeChat once so it creates its databases"
  var databasesOK = false
  do {
    try binding.assertStillBound()
    let root = binding.databaseRoot
    databaseRootReference = PathPrivacy(includePaths: includePaths).reference(for: root)
    let inventory = try DatabaseSaltInventory(root: root)
    databaseCount = inventory.entries.count
    distinctSaltCount = inventory.distinctSalts.count
    let origin = "bound to the selected process"
    if inventory.entries.isEmpty {
      databaseLabel = "database root found (\(origin)) but it contains no databases"
    } else {
      databasesOK = true
      databaseLabel =
        "database root \(origin) — \(inventory.entries.count) databases, "
        + "\(inventory.distinctSalts.count) distinct salts"
      databaseHint = nil
    }
  } catch {
    databaseLabel = String(describing: error)
    databaseHint = nil
  }
  checks.append(PreflightCheck(ok: databasesOK, label: databaseLabel, hint: databaseHint))

  let blockers = checks.filter { !$0.ok }.map { check in
    check.hint.map { "\(check.label) (\($0))" } ?? check.label
  }
  let report = PreflightReport(
    formatVersion: 1,
    ready: blockers.isEmpty,
    blockers: blockers,
    remediation: remediation,
    lldbAvailable: lldbAvailable,
    runningAsRoot: runningAsRoot,
    wechatProcessRunning: wechatProcessRunning,
    processHardeningStatus: processHardeningStatus,
    clientInstalled: clientInstalled,
    clientReSigned: clientReSigned,
    clientMarketingVersion: clientMarketingVersion,
    clientBuildVersion: clientBuildVersion,
    databaseRoot: databaseRootReference,
    databaseRootAutoDiscovered: false,
    databaseCount: databaseCount,
    distinctSaltCount: distinctSaltCount
  )
  return PreflightResult(report: report, checks: checks)
}

private func verifyPassphrase(
  _ passphrase: PassphraseSecret,
  inventory: DatabaseSaltInventory
) throws -> Int {
  var verifiedSaltCount = 0
  for sample in inventory.saltVerificationSamples {
    var encryptionKey = try SQLCipherKeyVerifier.deriveEncryptionKey(
      passphrase: passphrase,
      salt: sample.salt
    )
    let verified = try SQLCipherKeyVerifier.verify(
      encryptionKey: encryptionKey,
      page1: sample.page1
    )
    PassphraseSecret.zeroize(&encryptionKey)
    if verified { verifiedSaltCount += 1 }
  }
  return verifiedSaltCount
}

do {
  let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
  switch arguments.command {
  case .help:
    print(usage)
  case .preflight:
    let binding = try resolveTarget(arguments)
    let result = runPreflight(
      binding: binding,
      includePaths: arguments.includePaths
    )
    if arguments.json {
      try printJSON(result.report)
    } else {
      printPreflight(result)
    }
    if !result.report.ready { exit(1) }
  case .capture:
    guard let output = arguments.output else { throw CLIError.missingRequiredOption("--output") }
    let binding = try resolveTarget(arguments)
    let preflight = runPreflight(
      binding: binding,
      includePaths: arguments.includePaths
    )
    guard preflight.report.ready else {
      if arguments.json {
        try printJSON(preflight.report)
      } else {
        printPreflight(preflight)
      }
      exit(1)
    }
    try binding.assertStillBound()
    let inventory = try DatabaseSaltInventory(root: binding.databaseRoot)
    printNote(
      "why this step: the passphrase only crosses the system key-derivation "
        + "function while WeChat opens its databases at login, so a fresh "
        + "login is required"
    )
    printNote("in WeChat, log out of the account (not just quit the app), then log back in")
    printNote("waiting up to \(arguments.timeoutSeconds) seconds for the login")
    var capture = LLDBPassphraseCapture()
    capture.verbose = arguments.verbose
    capture.candidateValidator = { candidate in
      guard !inventory.distinctSalts.isEmpty else { return false }
      return try verifyPassphrase(candidate, inventory: inventory) == inventory.distinctSalts.count
    }
    capture.outputHandler = { message in
      FileHandle.standardError.write(Data("note: \(message)\n".utf8))
    }
    let started = Date()
    let passphrase = try capture.capture(binding: binding, timeoutSeconds: arguments.timeoutSeconds)
    let captureDurationSeconds = Date().timeIntervalSince(started)
    let verifiedSaltCount = try verifyPassphrase(passphrase, inventory: inventory)
    guard !inventory.distinctSalts.isEmpty, verifiedSaltCount == inventory.distinctSalts.count
    else {
      throw CLIError.verificationFailed(
        "the captured bytes did not verify every database salt; nothing was written"
      )
    }
    try binding.assertStillBound()
    try SecretOutputWriter().write(passphrase, to: output, overwrite: arguments.overwrite)
    if arguments.json {
      try printJSON(
        AcquisitionReport(
          capturedAt: Date(),
          captureDurationSeconds: captureDurationSeconds,
          databaseCount: inventory.entries.count,
          distinctSaltCount: inventory.distinctSalts.count,
          verifiedSaltCount: verifiedSaltCount,
          clientMarketingVersion: preflight.report.clientMarketingVersion,
          clientBuildVersion: preflight.report.clientBuildVersion,
          clientReSigned: preflight.report.clientReSigned,
          databaseRoot: preflight.report.databaseRoot,
          outputWritten: true
        ))
    } else {
      let seconds = Int(captureDurationSeconds.rounded())
      print("")
      print(
        "\(statusMark(true)) passphrase captured in \(seconds)s and verified against "
          + "\(verifiedSaltCount)/\(inventory.distinctSalts.count) databases"
      )
      print("  written to \(output.path) (mode 0600, owner-only)")
      print("")
      print("Use it with:  cat \(output.path) | greenbubbles <args> --passphrase-stdin")
    }
  case .verify:
    guard arguments.passphraseStdin else {
      throw CLIError.missingRequiredOption("--passphrase-stdin")
    }
    let passphrase = try PassphraseSecret.readFromStandardInput()
    let root = try resolveDatabaseRoot(arguments.dbRoot)
    let inventory = try DatabaseSaltInventory(root: root)
    let verifiedSaltCount = try verifyPassphrase(passphrase, inventory: inventory)
    let distinctSaltCount = inventory.distinctSalts.count
    let allVerified = distinctSaltCount > 0 && verifiedSaltCount == distinctSaltCount
    if arguments.json {
      try printJSON(
        VerificationReport(
          formatVersion: 1,
          databaseCount: inventory.entries.count,
          distinctSaltCount: distinctSaltCount,
          verifiedSaltCount: verifiedSaltCount,
          allVerified: allVerified
        ))
    } else {
      if allVerified {
        print(
          "\(statusMark(true)) passphrase verified against all "
            + "\(verifiedSaltCount) databases (\(distinctSaltCount) distinct salts)"
        )
      } else {
        print(
          "\(statusMark(false)) passphrase verified against only "
            + "\(verifiedSaltCount)/\(distinctSaltCount) distinct salts"
        )
      }
    }
    if !allVerified { exit(1) }
  }
} catch let error as ProcessBindingError {
  printError(error.description)
  exit(error == .ambiguousTargets ? 3 : 4)
} catch {
  printError(String(describing: error))
  printError("Run greenbubbles-acquire help for usage.")
  exit(2)
}
