import Foundation
import SwitchboardCore

/// One-shot `claude -p` turns that sbd runs for itself, such as the triage
/// summary and the plan update.
extension Service {
  /// The environment of a turn under a Claude account. With `session`, the
  /// turn takes the session's pane environment and account. Without one, it
  /// takes `config.env`. `account` overrides either. The turn is not a
  /// session, so it gets no session id.
  func headlessEnv(session: String?, account: String?) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if let session {
      env.merge(paneEnv(session)) { $1 }
    } else {
      for (key, value) in config.env { env[key] = value.expandingTilde }
      env["SB_HOME"] = home.path
    }
    env["SB_SESSION_ID"] = nil
    if let account { ClaudeAccount.apply(account, to: &env) }
    return env
  }

  /// Runs `claude` with the arguments and the input on stdin, in the folder,
  /// ends it after `timeout` seconds or once `cancelled` returns true, and
  /// returns what it printed.
  func runHeadless(
    _ arguments: [String], input: String, env: [String: String], folder: String, timeout: Double,
    cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> String {
    guard let claude = findExecutable(config.claude) else { throw APIError("can't find \(config.claude)") }
    return try Headless.run(
      claude: claude, arguments: arguments, input: input, env: env, folder: folder, timeout: timeout,
      cancelled: cancelled)
  }
}
