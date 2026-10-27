import Foundation

@main struct Check {
  // bputil's output for a wrong owner password in Recovery.
  static let bputilRejection = """
    Please enter password for user owner:
    bputil: failed to set credential: Error Domain=com.apple.LocalAuthentication Code=-1 \
    "Password rejected (3)" UserInfo={NSDebugDescription=Password rejected (3), \
    NSLocalizedDescription=Authentication failure., NSUnderlyingError=0x8bec185a0 {Error \
    Domain=com.apple.LocalAuthentication Code=-1 "Password rejected: e00002ce" \
    UserInfo={NSDebugDescription=Password rejected: e00002ce, \
    NSLocalizedDescription=Authentication failure.}}}
    Failed to create ACM context with provided username and password
    """

  static func main() {
    precondition(
      RecoveryPasswordRejected.matches(status: 8, output: bputilRejection, repeatedPrompt: false))
    precondition(
      RecoveryPasswordRejected.matches(
        status: 8, output: "Failed to create ACM context with provided username and password\n",
        repeatedPrompt: false))
    precondition(
      RecoveryPasswordRejected.matches(status: -8, output: "Password:\n", repeatedPrompt: true))
    precondition(
      !RecoveryPasswordRejected.matches(
        status: 8, output: "Please enter password for user owner:\nbputil: exit status 8\n",
        repeatedPrompt: false))
    precondition(
      !RecoveryPasswordRejected.matches(
        status: 1, output: "kmutil: Error: Unable to install the boot object.\n",
        repeatedPrompt: false))
    // A command that succeeds is never a rejection, whatever it printed.
    precondition(
      !RecoveryPasswordRejected.matches(status: 0, output: bputilRejection, repeatedPrompt: false))
    precondition(
      RecoveryPasswordRejected(username: "owner").localizedDescription
        == "The password for owner was not accepted.")
    print(
      "PASS bputil password rejection; repeated password prompt; other failures and success do not match"
    )
  }
}
