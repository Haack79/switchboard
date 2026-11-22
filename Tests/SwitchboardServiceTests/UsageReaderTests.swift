import SwitchboardCore
import Testing

@testable import SwitchboardService

@Suite struct UsageReaderFailures {
  @Test func aMissingKeychainItemOrASuccessIsNotAKeychainFailure() {
    #expect(UsageReader.keychainFailure(status: 0, stderr: "") == nil)
    #expect(UsageReader.keychainFailure(status: 44, stderr: "The specified item could not be found") == nil)
  }

  @Test func anyOtherKeychainStatusIsAKeychainFailureThatNamesTheStatus() {
    let failure = UsageReader.keychainFailure(status: 51, stderr: " User interaction is not allowed.\n")
    #expect(failure == "security exited with status 51: User interaction is not allowed.")
  }

  @Test func aKeychainFailureLeavesSignedOutUnset() {
    var usage = AccountUsage(name: "a", folder: "/a")

    usage.fail(with: APIError("could not read the login from the keychain: security exited with status 51: locked"))

    #expect(usage.error?.contains("keychain") == true)
    #expect(usage.signedOut == nil)
  }

  @Test func anAccountWithNoCredentialsIsSignedOut() {
    var usage = AccountUsage(name: "a", folder: "/a")

    usage.fail(with: SignedOut(login: "claude"))

    #expect(usage.error == "not signed in; run `claude` and /login")
    #expect(usage.signedOut == true)
  }
}

/// `codex login status` under a timeout. A codex that handles SIGTERM can exit 1, which alone means signed out.
@Suite struct UsageReaderCodexLogin {
  func failure(_ r: CommandResult) -> Error? {
    do {
      try UsageReader.checkCodexLogin(r, login: "codex login")
      return nil
    } catch {
      return error
    }
  }

  @Test func anExitOneAfterTheTimeoutIsATimeoutAndNotASignOut() {
    let error = failure(CommandResult(status: 1, stdout: "", stderr: "", timedOut: true))

    #expect(!(error is SignedOut))
    #expect("\(error.map { "\($0)" } ?? "")".contains("did not answer"))
  }

  @Test func anExitOneByItselfIsASignOut() {
    #expect(failure(CommandResult(status: 1, stdout: "", stderr: "Not logged in\n")) is SignedOut)
  }

  /// codex exits 1 for a config it can't load or a login it can't read, and logging in again fixes neither.
  @Test(arguments: [
    "Error loading configuration: config.toml: expected a table\n", "Error checking login status: permission denied\n",
  ])
  func anExitOneThatIsNotASignOutNamesTheProblem(_ stderr: String) {
    let error = failure(CommandResult(status: 1, stdout: "", stderr: stderr))

    #expect(error != nil)
    #expect(!(error is SignedOut))
    #expect("\(error.map { "\($0)" } ?? "")".contains(stderr.trimmingCharacters(in: .newlines)))
  }

  @Test func anotherStatusNamesTheProblem() {
    let error = failure(CommandResult(status: 2, stdout: "", stderr: "boom\n"))

    #expect("\(error.map { "\($0)" } ?? "")" == "`codex login status` failed: boom")
  }
}
