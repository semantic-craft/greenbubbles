// Derived from wcdb-key-tool (https://github.com/TANGandXUE/wcdb-key-tool), MIT license.

import Darwin
import Foundation

public enum SecretOutputError: Error, Equatable, CustomStringConvertible {
  case outputExists
  case posix(operation: String, code: Int32)

  public var description: String {
    switch self {
    case .outputExists:
      return "The passphrase output file already exists; pass --overwrite to replace it"
    case .posix(let operation, let code):
      return "\(operation) failed with POSIX error \(code)"
    }
  }
}

/// The only egress point for a captured passphrase: writes exactly 64
/// lowercase hexadecimal characters plus a trailing newline to an
/// owner-specified file. The parent directory is created or enforced to mode
/// 0700 and the file is mode 0600. A staged, synchronized file is published
/// exclusively, or atomically replaces the destination when overwrite is requested.
public struct SecretOutputWriter: Sendable {
  public init() {}

  public func write(
    _ secret: PassphraseSecret,
    to url: URL,
    overwrite: Bool = false
  ) throws {
    let parent = url.standardizedFileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

    // Publish only a fully written file. A failed write must not truncate an old key.
    let temporary = parent.appendingPathComponent(".greenbubbles-key-" + UUID().uuidString)
    let descriptor = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SecretOutputError.posix(operation: "create private key staging file", code: errno)
    }
    defer {
      Darwin.close(descriptor)
      Darwin.unlink(temporary.path)
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else {
      throw SecretOutputError.posix(operation: "restrict passphrase output", code: errno)
    }

    var payload = Self.hexPayload(of: secret)
    defer { PassphraseSecret.zeroize(&payload) }
    try payload.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
        guard count > 0 else {
          throw SecretOutputError.posix(operation: "write passphrase output", code: errno)
        }
        written += count
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw SecretOutputError.posix(operation: "sync passphrase output", code: errno)
    }
    // link is exclusive; rename atomically replaces a directory entry, never follows a symlink.
    let result =
      overwrite ? Darwin.rename(temporary.path, url.path) : Darwin.link(temporary.path, url.path)
    guard result == 0 else {
      if errno == EEXIST, !overwrite { throw SecretOutputError.outputExists }
      throw SecretOutputError.posix(operation: "publish passphrase output", code: errno)
    }
  }

  private static func hexPayload(of secret: PassphraseSecret) -> [UInt8] {
    let digits = Array("0123456789abcdef".utf8)
    var payload: [UInt8] = []
    payload.reserveCapacity(65)
    secret.withUnsafeBytes { buffer in
      for byte in buffer {
        payload.append(digits[Int(byte >> 4)])
        payload.append(digits[Int(byte & 0x0F)])
      }
    }
    payload.append(0x0A)
    return payload
  }
}
