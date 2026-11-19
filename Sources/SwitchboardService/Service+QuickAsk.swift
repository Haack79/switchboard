import Foundation
import SwitchboardCore

extension Service {
  /// Answers a one-off question from a snapshot of the state, with a `claude`
  /// turn that has no tools, so the turn can't change anything. It records
  /// no event. It runs off the state queue and takes that queue only to read
  /// the snapshot. The turn ends when `clientGone` turns true.
  func quickAsk(_ args: JSON, clientGone: @escaping @Sendable () -> Bool) throws -> JSON {
    let question = args["question"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !question.isEmpty else { throw APIError("ask a question") }
    guard question.count <= QuickAsk.maxQuestion else {
      throw APIError("a question is at most \(QuickAsk.maxQuestion) characters")
    }
    let (sessions, accounts, groups, account) = queue.sync {
      (summaries(), accountList(), groupList().groups, activeAccount)
    }
    let input = QuickAsk.input(
      question: question, sessions: sessions, inbox: Triage.order(sessions), accounts: accounts, groups: groups)
    let env = headlessEnv(session: nil, account: account)
    try requireSignedIn(["account": .string(account.folder)])
    if clientGone() { throw APIError("cancelled") }
    let model = config.quickAsk.model
    do {
      let reply = try headlessCall(
        arguments: QuickAsk.arguments(model: model), input: input, env: env, folder: home.path,
        timeout: min(config.quickAsk.timeoutSeconds, QuickAsk.maxTimeout), cancelled: clientGone)
      return try JSON(encoding: QuickAskAnswer(answer: QuickAsk.parse(reply.output), model: model))
    } catch {
      logLine("quick ask failed: \(error)")
      throw error
    }
  }
}
