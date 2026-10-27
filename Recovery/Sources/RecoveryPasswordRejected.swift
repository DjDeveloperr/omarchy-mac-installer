import Foundation

/// The owner's password was refused, so the person can simply enter it again.
struct RecoveryPasswordRejected: Error, LocalizedError {
  let username: String
  var errorDescription: String? { "The password for \(username) was not accepted." }

  /// bputil reports LocalAuthentication's refusal and exits 8. A command that
  /// asks for the password a second time has also refused the first one.
  static func matches(status: Int32, output: String, repeatedPrompt: Bool) -> Bool {
    guard status != 0 else { return false }
    let text = output.lowercased()
    return repeatedPrompt || text.contains("password rejected")
      || text.contains("failed to create acm context with provided username and password")
  }
}
