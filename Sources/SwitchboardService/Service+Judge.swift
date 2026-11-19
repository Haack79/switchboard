import Foundation
import SwitchboardCore

/// The Operator's judges: one-shot `claude -p` calls that answer a bounded question before the Operator wakes.
extension Service {
  /// Runs one judge call of `kind` about the session `session`, the wait `wait`, and the PR head `head`, and records
  /// a `judge` event on the Operator. `answer` gives the word that the event records for a parsed answer.
  ///
  /// The call runs `operator.judgeModel` under `triage.account`, or under the Operator's pane environment when that
  /// is unset, and ends after `triage.timeoutSeconds`. It returns nil and runs nothing when the account has no quota
  /// left or sbd can't create the Operator. It runs off the state queue.
  func judge<T>(
    _ kind: OperatorJudge.Kind, session: String, wait: String, head: String, input: String,
    arguments: (String) -> [String], parse: (String) throws -> T, answer: (T) -> String
  ) -> Result<T, Error>? {
    let model = operatorSettings.judgeModel
    let setup: (op: String, env: [String: String])? = queue.sync {
      let op: String
      do { op = try ensureOperator() } catch {
        logLine("can't run the \(kind.rawValue) judge for wait \(wait): \(error)")
        return nil
      }
      let triageAccount = config.triage.account.map(ClaudeAccount.init(folder:))
      let account = triageAccount?.folder ?? claudeAccount(of: op).key
      guard quota.hasBudget(account: account) else {
        logLine("skipping the \(kind.rawValue) judge for wait \(wait): no quota left for \(account)")
        return nil
      }
      return (op, headlessEnv(session: op, account: triageAccount))
    }
    guard let setup else { return nil }
    let call = headlessCall(
      kind.headless, session: session, arguments: arguments(model), input: input, env: setup.env, folder: home.path,
      timeout: config.triage.timeoutSeconds, parse: parse)
    var data: [String: JSON] = [
      "kind": .string(kind.rawValue), "session": .string(session), "wait": .string(wait), "head": .string(head),
      "model": .string(model),
    ]
    data.merge(call.reply?.eventFields ?? [:]) { $1 }
    if let usage = call.reply?.usage {
      data["inputTokens"] = .number(Double(usage.input))
      data["outputTokens"] = .number(Double(usage.output))
    }
    switch call.result {
    case .success(let value):
      data["answer"] = .string(answer(value))
    case .failure(let error):
      logLine("the \(kind.rawValue) judge for wait \(wait) failed: \(error)")
      data["error"] = .string("\(error)")
    }
    queue.sync { _ = record(setup.op, OperatorJudge.event, .object(data)) }
    return call.result
  }
}
