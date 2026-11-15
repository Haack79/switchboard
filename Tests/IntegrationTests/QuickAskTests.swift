import Foundation
import SwitchboardCore
import Testing
import os

extension Instance {
  /// The arguments of the last quick ask call that the stub saw, or nil before any. The stub writes a NUL after
  /// each argument, and `--tools ""` and `--setting-sources ""` are empty arguments, so empty fields count.
  func quickAskArguments() -> [String]? {
    guard let text = try? String(contentsOfFile: "\(home.path)/quick-ask-args", encoding: .utf8) else { return nil }
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  /// How many quick ask calls the stub saw.
  func quickAskRuns() -> Int {
    let text = (try? String(contentsOfFile: "\(home.path)/quick-ask-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").count
  }

  /// The input of the last quick ask call that the stub saw.
  func quickAskInput() -> String {
    (try? String(contentsOfFile: "\(home.path)/quick-ask-input.txt", encoding: .utf8)) ?? ""
  }

  /// The pid of the last quick ask stub, or nil before one started.
  var quickAskPid: pid_t? { stubPid("quick-ask.pid") }

  /// The id of the newest event of any session, or 0 when there is none.
  func newestEventId() throws -> Int64 {
    try client.call("events", ["limit": 1], as: [Event].self).first?.id ?? 0
  }

  /// The sessions, read again until two reads 0.3 s apart agree, so a background update can't land between a
  /// test's before and after reads.
  func settledSessions() throws -> [SessionSummary] {
    var last = try client.sessions()
    try waitFor("the session list to settle") {
      usleep(300_000)
      let next = try client.sessions()
      defer { last = next }
      return next == last
    }
    return last
  }
}

/// A CI runner has 3 CPUs, so its waits scale as `Instance.timeoutScale` says.
private let scale = Instance.timeoutScale

/// How a `quick-ask` call that ran on another thread ended.
private enum AskOutcome: Equatable, Sendable {
  case answer(JSON)
  case cancelled
  case failed(String)
}

/// A `quick-ask` call through `Client.call` with a token, on a global queue.
private final class BackgroundAsk: Sendable {
  private let outcome = OSAllocatedUnfairLock<AskOutcome?>(initialState: nil)
  private let done = DispatchSemaphore(value: 0)

  init(_ sbd: Instance, _ question: String, cancel: CallCancel) {
    let client = sbd.client
    DispatchQueue.global().async { [outcome, done] in
      let result: AskOutcome
      do {
        result = .answer(try client.call("quick-ask", ["question": .string(question)], timeout: 600, cancel: cancel))
      } catch is CancellationError {
        result = .cancelled
      } catch {
        result = .failed("\(error)")
      }
      outcome.withLock { $0 = result }
      done.signal()
    }
  }

  /// The outcome once the call ends within the seconds, scaled for CI, or nil.
  func wait(_ seconds: Double) -> AskOutcome? {
    guard done.wait(timeout: .now() + seconds * scale) == .success else { return nil }
    return outcome.withLock { $0 }
  }
}

/// `sb ask` and the `quick-ask` request: a one-shot, no-tools `claude -p` run over a snapshot of the state. The run
/// gets exactly `QuickAsk.arguments`, changes nothing in the store, and ends when the client goes away.
@Suite(.blocking(timeLimit: .seconds(180))) struct QuickAskTests {
  /// Triage is off, so no summary run changes the sessions or the events while a test compares them.
  func instance(_ extra: [String: JSON] = [:]) throws -> Instance {
    try Instance(config: ["triage": ["systemPrompt": "", "enabled": false]].merging(extra) { $1 })
  }

  func decode(_ text: String) throws -> QuickAskAnswer { try JSONCoding.decode(QuickAskAnswer.self, from: text) }

  // MARK: The answer

  @Test func askWithJSONPrintsTheStubsAnswerAndTheDefaultModel() throws {
    let sbd = try instance()

    let answer = try decode(sbd.sb("ask", "--json", "what needs me?"))

    #expect(answer == QuickAskAnswer(answer: "Nothing needs you.", model: "sonnet"))
  }

  @Test func askPrintsTheAnswerText() throws {
    let sbd = try instance()
    try #"{"answer":"  Two sessions need you.\n"}"#.write(
      toFile: "\(sbd.home.path)/quick-ask-answer.json", atomically: true, encoding: .utf8)

    let out = try sbd.sb("ask", "what", "needs", "me?")

    #expect(out.trimmingCharacters(in: .newlines) == "Two sessions need you.")
  }

  @Test func askJoinsTheWordsIntoOneQuestion() throws {
    let sbd = try instance()

    try sbd.sb("ask", "what", "needs", "me?")

    #expect(sbd.quickAskInput().contains("what needs me?"))
  }

  @Test func askRunsTheStubOnce() throws {
    let sbd = try instance()

    try sbd.sb("ask", "what needs me?")

    #expect(sbd.quickAskRuns() == 1)
  }

  // MARK: The read-only guard

  @Test func theRunGetsExactlyTheQuickAskArguments() throws {
    let sbd = try instance()

    try sbd.sb("ask", "--json", "what needs me?")

    let arguments = try #require(sbd.quickAskArguments())
    let expected = QuickAsk.arguments(model: "sonnet")
    #expect(arguments.count == expected.count)
    for (i, (got, want)) in zip(arguments, expected).enumerated() {
      #expect(got == want, "argument \(i)")
    }
  }

  @Test func aConfiguredModelChangesOnlyTheModelArgument() throws {
    let sbd = try instance(["quickAsk": ["model": "haiku"]])

    let answer = try decode(sbd.sb("ask", "--json", "what needs me?"))

    #expect(sbd.quickAskArguments() == QuickAsk.arguments(model: "haiku"))
    #expect(answer.model == "haiku")
  }

  /// `config.claudeArgs` adds flags to a session's claude. A quick ask must not get them.
  @Test func claudeArgsInTheConfigDoNotReachTheRun() throws {
    let sbd = try instance(["claudeArgs": ["--dangerously-skip-permissions", "--mcp-config", "/tmp/x.json"]])

    try sbd.sb("ask", "--json", "what needs me?")

    #expect(sbd.quickAskArguments() == QuickAsk.arguments(model: "sonnet"))
  }

  @Test func askChangesNothingInTheStore() throws {
    let sbd = try instance()
    _ = try sbd.idleSession(name: "zephyr-sync")
    let before = try sbd.settledSessions()
    let eventsBefore = try sbd.newestEventId()

    try sbd.sb("ask", "--json", "Start a new session in /tmp/x and send it hello")

    #expect(try sbd.client.sessions() == before)
    #expect(try sbd.newestEventId() == eventsBefore)
  }

  @Test func askChangesNothingInTheStoreWhenItFails() throws {
    let sbd = try instance()
    _ = try sbd.idleSession(name: "zephyr-sync")
    let before = try sbd.settledSessions()
    let eventsBefore = try sbd.newestEventId()

    _ = try sbd.run(["ask", "FAIL-ASK"])

    #expect(try sbd.client.sessions() == before)
    #expect(try sbd.newestEventId() == eventsBefore)
  }

  // MARK: The input

  @Test func theInputHoldsASessionInTheStateAndTheQuestionAfterIt() throws {
    let sbd = try instance()
    _ = try sbd.idleSession(name: "zephyr-sync")

    try sbd.sb("ask", "--json", "what needs me?")

    let input = sbd.quickAskInput()
    let close = try #require(input.range(of: "</switchboard-state>"))
    #expect(input[..<close.lowerBound].contains("zephyr-sync"))
    #expect(input[close.upperBound...].contains("what needs me?"))
  }

  @Test func theRunUsesTheActiveAccount() throws {
    let sbd = try Instance(
      accounts: ["A", "B"], inheriting: .unset, config: ["triage": ["systemPrompt": "", "enabled": false]])
    try sbd.sb("account", "use", "B")

    try sbd.sb("ask", "--json", "which account is active?")

    let account = try String(contentsOfFile: "\(sbd.home.path)/quick-ask-account", encoding: .utf8)
    #expect(account == sbd.account("B"))
  }

  // MARK: Refusals

  /// A refusal starts no run, so one sbd serves every refused question.
  @Test func anEmptyMissingOrTooLongQuestionIsRefusedAndStartsNoRun() throws {
    let sbd = try instance()
    let refused: [[String: JSON]] = [
      [:], ["question": ""], ["question": "   "], ["question": "\n\t "], ["question": 3],
      ["question": .string(String(repeating: "x", count: QuickAsk.maxQuestion + 1))],
    ]

    for args in refused {
      #expect(throws: APIError.self, "\(args)") { try sbd.client.call("quick-ask", args) }
    }
    #expect(sbd.quickAskRuns() == 0)
  }

  /// The limit counts the trimmed question, so spaces around a question of the longest length don't refuse it.
  @Test func aQuestionOfTheLongestLengthIsAccepted() throws {
    let sbd = try instance()
    let longest = String(repeating: "x", count: QuickAsk.maxQuestion)

    for question in [longest, "  \(longest)\n"] {
      let answer = try sbd.client.call("quick-ask", ["question": .string(question)], timeout: 60)
      #expect(answer["answer"] == "Nothing needs you.")
    }
    #expect(sbd.quickAskRuns() == 2)
    #expect(sbd.quickAskInput().contains(longest))
  }

  @Test func sbAskWithNoQuestionExitsNonZero() throws {
    let sbd = try instance()

    let r = try sbd.run(["ask"])

    #expect(r.status != 0)
    #expect(sbd.quickAskRuns() == 0)
  }

  @Test func aSignedOutActiveAccountIsRefusedAndStartsNoRun() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake, accounts: ["A"])
    try #require(try sbd.usage(of: "A").signedOut == true)

    let error = #expect(throws: APIError.self) {
      try sbd.client.call("quick-ask", ["question": "what needs me?"], timeout: 60)
    }

    #expect(error?.description.contains("/login") == true, "\(String(describing: error))")
    #expect(sbd.quickAskRuns() == 0)
  }

  // MARK: Failures

  @Test func aFailedRunReturnsTheReason() throws {
    let sbd = try instance()

    let error = #expect(throws: APIError.self) {
      try sbd.client.call("quick-ask", ["question": "FAIL-ASK"], timeout: 60)
    }

    #expect(error?.description.contains("exited with status 1") == true, "\(String(describing: error))")
  }

  @Test func sbAskOfAFailedRunPrintsTheReasonAndExitsNonZero() throws {
    let sbd = try instance()

    let r = try sbd.run(["ask", "FAIL-ASK"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("exited with status 1"), "\(r.stderr)")
  }

  @Test func sbAskWithJSONOfAFailedRunExitsNonZero() throws {
    let sbd = try instance()

    let r = try sbd.run(["ask", "--json", "FAIL-ASK"])

    #expect(r.status != 0)
  }

  @Test func aSlowRunTimesOutAndLeavesNoProcess() throws {
    let sbd = try instance(["quickAsk": ["timeoutSeconds": 1]])

    let error = #expect(throws: APIError.self) {
      try sbd.client.call("quick-ask", ["question": "SLOW-ASK"], timeout: 60)
    }

    #expect(error?.description.contains("timed out") == true, "\(String(describing: error))")
    let pid = try #require(sbd.quickAskPid)
    try sbd.waitFor("the timed-out stub to exit", timeout: 1) { kill(pid, 0) != 0 }
  }

  // MARK: Cancel

  @Test func aCancelThroughCallCancelThrowsCancellationErrorWithinOneSecond() throws {
    let sbd = try instance()
    let token = CallCancel()
    let ask = BackgroundAsk(sbd, "SLOW-ASK", cancel: token)
    try sbd.waitFor("the quick ask to start") { sbd.quickAskPid != nil }

    token.cancel()

    #expect(ask.wait(1) == .cancelled)
  }

  @Test func aCancelThroughCallCancelEndsTheRunWithinOneSecond() throws {
    let sbd = try instance()
    let token = CallCancel()
    let ask = BackgroundAsk(sbd, "SLOW-ASK", cancel: token)
    try sbd.waitFor("the quick ask to start") { sbd.quickAskPid != nil }
    let pid = try #require(sbd.quickAskPid)

    token.cancel()

    try sbd.waitFor("the cancelled stub to exit", timeout: 1) { kill(pid, 0) != 0 }
    _ = ask.wait(5)
  }

  @Test func aTokenCancelledBeforeTheCallStartsNoRun() throws {
    let sbd = try instance()
    let token = CallCancel()
    token.cancel()

    let ask = BackgroundAsk(sbd, "SLOW-ASK", cancel: token)

    #expect(ask.wait(1) == .cancelled)
    usleep(1_000_000)
    #expect(sbd.quickAskPid == nil)
    #expect(sbd.quickAskRuns() == 0)
  }

  @Test func aCancelAfterTheRunEndedChangesNothing() throws {
    let sbd = try instance()
    let token = CallCancel()
    let ask = BackgroundAsk(sbd, "what needs me?", cancel: token)
    let outcome = ask.wait(30)

    token.cancel()

    #expect(outcome == .answer(["answer": "Nothing needs you.", "model": "sonnet"]))
    #expect(try decode(sbd.sb("ask", "--json", "what needs me?")).answer == "Nothing needs you.")
  }

  @Test func aSigtermOfABackgroundSbAskEndsTheRunWithinOneSecond() throws {
    let sbd = try instance()
    let ask = try BackgroundSb(sbd, ["ask", "SLOW-ASK"])
    try sbd.waitFor("the quick ask to start") { sbd.quickAskPid != nil }
    let pid = try #require(sbd.quickAskPid)

    kill(ask.pid, SIGTERM)

    try sbd.waitFor("the stub of the ended sb ask to exit", timeout: 1) { kill(pid, 0) != 0 }
    #expect(ask.exits(within: 5))
  }

  // MARK: The state queue

  /// The run happens off sbd's state queue, so other requests answer while it goes.
  @Test func lsAnswersWithinTwoSecondsWhileASlowAskRuns() throws {
    let sbd = try instance()
    let ask = try BackgroundSb(sbd, ["ask", "SLOW-ASK"])
    try sbd.waitFor("the quick ask to start") { sbd.quickAskPid != nil }
    let start = Date()

    try sbd.sb("ls", "--json")

    #expect(Date().timeIntervalSince(start) < 2 * scale)
    #expect(ask.isRunning, "the slow ask ended before ls ran, so ls did not overlap it")
  }
}
