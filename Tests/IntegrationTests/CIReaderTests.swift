import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Makes the stub's CI reader judge answer with `cause` and `message`, as Fixtures/claude-stub reads
  /// `$SB_HOME/ci-judge-answer.json`.
  func answerCIJudge(_ cause: String, message: String = CIReaderTests.message) throws {
    let json: JSON = ["cause": .string(cause), "message": .string(message)]
    try json.text.write(toFile: "\(home.path)/ci-judge-answer.json", atomically: true, encoding: .utf8)
  }

  /// The model of each CI reader judge call that the stub answered, oldest first.
  func ciJudgeCalls() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/ci-judge-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// The prompt of the last CI reader judge call.
  func ciJudgeInput() -> String {
    (try? String(contentsOfFile: "\(home.path)/ci-judge-input.txt", encoding: .utf8)) ?? ""
  }

  /// Each `gh run rerun` that gh-merge-stub ran, oldest first, as `<owner/name> <id>` and the call's flags.
  func ghReruns() -> [String] {
    let text = (try? String(contentsOfFile: "\(home.path)/gh-reruns.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// Makes gh-merge-stub print `runs` for `gh run list --repo <repo> --commit <head>`.
  func serveRuns(_ runs: [JSON], repo: String = MergeTests.charts, head: String) throws {
    try serveGh("run/\(repo)/commit/\(head)", .array(runs))
  }

  /// Makes gh-merge-stub print `log` for `gh run view <run> --repo <repo> --log-failed`.
  func serveFailedLog(_ log: String, repo: String = MergeTests.charts, run: Int) throws {
    try writeGhLive("run/\(repo)/\(run)/log-failed.txt", log)
  }

  /// Makes gh-merge-stub refuse `gh run rerun <run> --repo <repo>` with `text` on stderr.
  func ghRerunFails(repo: String = MergeTests.charts, run: Int, with text: String) throws {
    try writeGhLive("run/\(repo)/\(run)/rerun.error", text)
  }

  private func writeGhLive(_ path: String, _ text: String) throws {
    let file = "\(home.path)/gh-live/\(path)"
    try FileManager.default.createDirectory(
      atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: file, atomically: true, encoding: .utf8)
  }
}

/// A merge-armed session whose checks fail at one head on two ticks `operator.holdRetrySeconds` apart, while the
/// session is idle, gets a headless CI reader. sbd reads the failed runs with `gh run list --commit` and their logs with
/// `gh run view --log-failed`, asks the reader, and then sends the session the reader's summary (`real`, `timeout`),
/// reruns the failed runs once (`flake`), or raises a judgment message to the Operator. Fixtures/gh-merge-stub serves
/// the runs and the logs, and Fixtures/claude-stub answers the reader from `ci-judge-answer.json`.
///
/// `holdRetrySeconds` is 60, not a second or two: sbd ticks once a second of real time, so a window that short would
/// pass on real ticks alone, and every check that the reader has not run yet would race. The tests move sbd's clock
/// instead.
///
/// The tests arm waits from the test runner, which counts as the user, so the Operator exists without a launch and
/// any `sent` event on it comes from sbd. Each arms the merge wait while the checks already fail, so the subject is
/// never Ready to merge and the merge action does not run.
@Suite(.blocking(timeLimit: .seconds(120))) struct CIReaderTests {
  let follow = FollowThroughTests()

  static let charts = MergeTests.charts
  static let number = MergeTests.number
  static let holdRetrySeconds = 60
  /// Past `holdRetrySeconds`.
  static let pastHoldRetry: Int64 = 61_000
  static let message = "parsesTitles() fails on a nil title in TitleParser.swift."
  /// The id of the failed run that the default setup serves.
  static let failed = 501
  /// The start of sbd's message to the session, before the short head.
  static let framing = "Switchboard: the checks on #\(number) failed at "
  static let reader = "sbd's CI reader, which read the failed logs, says: "
  static let failingLine = "✘ Test parsesTitles() failed"

  /// One run as `gh run list --json databaseId,name,workflowName,conclusion,status` prints it.
  static func run(_ id: Int, _ conclusion: String = "failure", workflow: String = "Swift CI") -> JSON {
    [
      "databaseId": .number(Double(id)), "name": .string(workflow), "workflowName": .string(workflow),
      "conclusion": .string(conclusion), "status": "completed",
    ]
  }

  /// A failed log as `gh run view --log-failed` prints it: the job, the step, and the timestamped text, split by tabs.
  static func log(_ line: String = failingLine, job: String = "swift-test") -> String {
    [
      "\(job)\tRun bin/test\t2026-11-19T10:00:00.0000000Z Building for debugging…",
      "\(job)\tRun bin/test\t2026-11-19T10:00:05.0000000Z \(line)",
    ].joined(separator: "\n") + "\n"
  }

  static func operatorSettings(_ mergeRepos: [String]) -> JSON {
    ["mergeRepos": .array(mergeRepos.map(JSON.string)), "holdRetrySeconds": .number(Double(holdRetrySeconds))]
  }

  /// A private sbd with Fixtures/gh-merge-stub as its gh that merges in PostHog/charts. `config` replaces the whole
  /// `operator` object, so it carries `mergeRepos` too.
  func instance(_ github: FakeGitHub) throws -> Instance {
    try Instance.withMergeStub(github, config: ["operator": Self.operatorSettings([Self.charts])])
  }

  func head(_ github: FakeGitHub) -> String { follow.head(github) }

  /// A fix-cache on #18303's branch whose checks failed, idle in Needs you.
  func failingTarget(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.checks(Self.number, "FAILURE")
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: WaitActionTests.target)
    try sbd.poll()
    return try sbd.waitFor(s.id, "the failed checks on #18303") {
      $0.pr?.number == Self.number && $0.state == .needsYou
    }
  }

  /// `failingTarget` with `runs` served for the head and `log` for each failed run in `runs`, and a merge wait on it
  /// that the user armed. Nil `runs` or `log` serves nothing, so the read fails.
  func armedFailure(
    _ github: FakeGitHub, _ sbd: Instance, runs: [JSON]? = [CIReaderTests.run(CIReaderTests.failed)],
    log: String? = CIReaderTests.log()
  ) throws -> (s: SessionSummary, wait: String) {
    let s = try failingTarget(github, sbd)
    if let runs {
      try sbd.serveRuns(runs, head: head(github))
      if let log {
        for run in runs where run["conclusion"]?.string == "failure" {
          try sbd.serveFailedLog(log, run: try #require(run["databaseId"]?.int))
        }
      }
    }
    let wait = try follow.arm(sbd, follow.arming.mergeArgs(s))
    return (s, wait)
  }

  func operatorsWait(_ sbd: Instance, _ id: String) throws -> Wait? { try follow.operatorsWait(sbd, id) }

  func ciCheck(_ sbd: Instance, _ wait: String) throws -> CICheck? { try operatorsWait(sbd, wait)?.ciCheck }

  /// Runs a tick and waits until the wait records the failure at `head` as seen, later than `after` when it is set.
  /// Returns when the failure was seen.
  @discardableResult
  func waitForSeen(_ sbd: Instance, _ wait: String, head: String, after: Int64? = nil) throws -> Int64 {
    try follow.tick(sbd)
    var since: Int64 = 0
    try sbd.waitFor("the CI reader to see the failure at \(head.prefix(7))", timeout: 30) {
      guard let check = try ciCheck(sbd, wait), check.head == head, check.step == .seen else { return false }
      if let after, check.since <= after { return false }
      since = check.since
      return true
    }
    return since
  }

  /// Sees the failure at `head`, then runs a tick past `holdRetrySeconds` later, which starts the reader.
  func failTwice(_ sbd: Instance, _ wait: String, head: String) throws {
    try waitForSeen(sbd, wait, head: head)
    try sbd.advanceClock(Self.pastHoldRetry)
  }

  func waitForCIJudgeCalls(_ sbd: Instance, _ count: Int) throws {
    try sbd.waitFor("CI judge call \(count)", timeout: 30) { sbd.ciJudgeCalls().count >= count }
  }

  /// sbd's messages to `s` that carry the CI reader's summary.
  func ciMessages(_ sbd: Instance, _ s: SessionSummary) throws -> [String] {
    try sbd.messagesFromSbd(s.id).filter { $0.hasPrefix(Self.framing) }
  }

  /// Waits for sbd's `count`th message to `s` that carries the CI reader's summary, and returns it.
  @discardableResult
  func ciMessage(_ sbd: Instance, _ s: SessionSummary, count: Int = 1) throws -> String {
    var found: [String] = []
    try sbd.waitFor("CI message \(count) to \(s.name)", timeout: 30) {
      found = try ciMessages(sbd, s)
      return found.count >= count
    }
    return found[count - 1]
  }

  /// sbd's judgment messages to the Operator about the wait `id` that offer no approval. Stage 1's question about
  /// the last reply offers `sb operator approve`, so it is not one of them.
  func ciJudgments(_ sbd: Instance, _ id: String) throws -> [String] {
    try follow.operatorMessages(sbd).filter {
      $0.contains("judgment needed for wait \(id)") && !$0.contains("sb operator approve")
    }.map {
      // Clearing the wait would cancel the merge that sbd still runs once the checks pass.
      #expect(!$0.contains("--clear"), Comment(rawValue: $0))
      return $0
    }
  }

  /// Waits for sbd's `count`th judgment message to the Operator about the wait `id` that offers no approval.
  @discardableResult
  func ciJudgment(_ sbd: Instance, _ id: String, count: Int = 1) throws -> String {
    var found: [String] = []
    try sbd.waitFor("CI judgment \(count) about \(id)", timeout: 30) {
      found = try ciJudgments(sbd, id)
      return found.count >= count
    }
    return found[count - 1]
  }

  /// The Operator's `judge` events of the CI reader, oldest first.
  func ciJudgeEvents(_ sbd: Instance) throws -> [Event] {
    try sbd.events(try follow.theOperator(sbd).id).filter {
      $0.kind == OperatorJudge.event && $0.data["kind"]?.string == "ci-failure"
    }
  }

  /// Moves the clock past `holdRetrySeconds` twice more with ticks between, so a reader that repeats would run again.
  func passMoreTicks(_ sbd: Instance) throws {
    for _ in 0..<2 {
      try sbd.advanceClock(Self.pastHoldRetry)
      try follow.tick(sbd, 2)
    }
  }

  /// Moves the clock past `holdRetrySeconds` twice with ticks between, for a case where the reader must not start.
  func passTwoWindows(_ sbd: Instance) throws {
    try follow.tick(sbd)
    try passMoreTicks(sbd)
  }

  /// Expects that the reader read nothing, asked nothing, and told nobody.
  func expectNoReader(
    _ sbd: Instance, _ s: SessionSummary, _ wait: String?, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    #expect(sbd.ghCalls("run ").isEmpty, "\(sbd.ghCalls("run "))", sourceLocation: sourceLocation)
    #expect(sbd.ciJudgeCalls().isEmpty, "\(sbd.ciJudgeCalls())", sourceLocation: sourceLocation)
    #expect(try ciMessages(sbd, s).isEmpty, sourceLocation: sourceLocation)
    if let wait { #expect(try ciJudgments(sbd, wait).isEmpty, sourceLocation: sourceLocation) }
  }
}

// MARK: real and timeout

extension CIReaderTests {
  /// Decision 43: `real` and `timeout` send the subject the reader's summary, framed as the reader's, by sbd.
  @Test(arguments: ["real", "timeout"])
  func aFailureOnTwoTicksAtOneHeadSendsTheSessionTheFramedMessage(_ cause: String) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge(cause)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    let text = try ciMessage(sbd, s)
    #expect(text.hasPrefix(Self.framing + head(github).prefix(7)), Comment(rawValue: text))
    #expect(text.contains(Self.reader + Self.message), Comment(rawValue: text))
  }

  /// Decision 42: nothing repeats for the same head across ticks.
  @Test(arguments: ["real", "timeout"])
  func theFramedMessageGoesOncePerHead(_ cause: String) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    try sbd.answerCIJudge(cause)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)

    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.count == 1, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
  }

  @Test func aSentMessageRecordsTheHeadAsJudgedOnTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try ciMessage(sbd, s)
    try sbd.waitFor("the judged step", timeout: 30) { try ciCheck(sbd, wait)?.step == .judged }
    #expect(try ciCheck(sbd, wait)?.head == head(github))
  }

  @Test func aRealCauseSendsTheOperatorNothingAndRerunsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)

    try passMoreTicks(sbd)

    try follow.expectNoSentToOperator(sbd)
    #expect(sbd.ghReruns().isEmpty, "\(sbd.ghReruns())")
  }

  /// Decision 43: the reader reads the PR, the failed runs' workflow and job names, and their failed log lines.
  @Test func theReaderReadsThePRTheJobsAndTheirFailedLogLines() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try waitForCIJudgeCalls(sbd, 1)
    let prompt = sbd.ciJudgeInput()
    for text in ["<ci-log", Self.failingLine, "swift-test", "Swift CI", "\(Self.charts)#\(Self.number)"] {
      #expect(prompt.contains(text), "\(text) in \(prompt)")
    }
    #expect(prompt.contains(head(github).prefix(7)), Comment(rawValue: prompt))
  }

  /// Decision 43: the reads are `gh run list --commit` at the head and `gh run view --log-failed` of the failed run.
  @Test func theReaderListsTheRunsAtTheHeadAndReadsTheFailedRunsLog() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd, runs: [Self.run(Self.failed), Self.run(503, "success")])

    try failTwice(sbd, wait, head: head(github))

    try waitForCIJudgeCalls(sbd, 1)
    let lists = sbd.ghCalls("run list ")
    let views = sbd.ghCalls("run view ")
    #expect(lists.count == 1 && lists.allSatisfy { $0.contains("--commit \(head(github))") }, "\(lists)")
    #expect(views.count == 1, "\(views)")
    #expect(views.allSatisfy { $0.contains("\(Self.failed)") && $0.contains("--log-failed") }, "\(views)")
  }

  /// Decision 39: each judge call records a `judge` event on the Operator. Stage 5 reads `.data.inputTokens` and
  /// `.data.outputTokens`.
  @Test func aReaderCallRecordsACIFailureJudgeEventOnTheOperator() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    var events: [Event] = []
    try sbd.waitFor("the CI judge event", timeout: 30) {
      events = try ciJudgeEvents(sbd)
      return !events.isEmpty
    }
    let data = events[0].data
    #expect(data["session"]?.string == s.id, Comment(rawValue: data.text))
    #expect(data["wait"]?.string == wait, Comment(rawValue: data.text))
    #expect(data["head"]?.string == head(github), Comment(rawValue: data.text))
    #expect(data["model"]?.string == "sonnet", Comment(rawValue: data.text))
    #expect(data["inputTokens"]?.int == stubUsage.input, Comment(rawValue: data.text))
    #expect(data["outputTokens"]?.int == stubUsage.output, Comment(rawValue: data.text))
    #expect(data["answer"]?.string == "real", Comment(rawValue: data.text))
    #expect(data["error"] == nil, Comment(rawValue: data.text))
  }

  @Test func aReaderCallShowsInHeadlessUsageAsCIFailure() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFailure(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    let row = try sbd.waitForHeadlessUsageRow("ciFailure", calls: 1)
    #expect(headlessUsage(row["usage"]) == stubUsage, Comment(rawValue: row.text))
  }
}

// MARK: Twice in a row on one head

extension CIReaderTests {
  /// Decision 41: the first tick that sees the failure records the head and reads nothing yet, so the session's own
  /// ci-monitor gets `holdRetrySeconds` to rerun or fix first.
  @Test func theFirstFailingTickRecordsTheHeadAsSeenAndReadsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)

    try waitForSeen(sbd, wait, head: head(github))

    try expectNoReader(sbd, s, wait)
  }

  @Test func aSecondTickWithinHoldRetrySecondsReadsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try waitForSeen(sbd, wait, head: head(github))

    try sbd.advanceClock(Self.pastHoldRetry - 31_000)
    try follow.tick(sbd, 2)

    try expectNoReader(sbd, s, wait)
    try sbd.advanceClock(31_000)
    try ciMessage(sbd, s)
  }

  /// Decision 41: a rollup that flips back to pending starts the count again. The failure at T, pending at T+31,
  /// and the failure again at about T+32 put the second tick at T+93 or later, not at T+60.
  @Test func pendingChecksBetweenTheTicksStartTheCountAgain() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    let first = try waitForSeen(sbd, wait, head: head(github))
    github.checks(Self.number, "PENDING")
    try sbd.advanceClock(30_000)
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the checks running") { $0.state != .needsYou }
    try follow.tick(sbd)
    github.checks(Self.number, "FAILURE")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the checks failing again") { $0.state == .needsYou }
    let again = try waitForSeen(sbd, wait, head: head(github), after: first)

    let now = try sbd.now()
    try sbd.advanceClock(first + Self.pastHoldRetry + 1_000 - now)
    try follow.tick(sbd, 2)
    try #require(try sbd.now() < again + Int64(Self.holdRetrySeconds) * 1000)

    try expectNoReader(sbd, s, wait)
    try sbd.advanceClock(Self.pastHoldRetry)
    try ciMessage(sbd, s)
  }

  /// Decision 41: the reader runs only while the subject's turn is not running. Once the turn ends, it runs.
  @Test func aSessionWhoseTurnRunsGetsNothingUntilTheTurnEnds() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try sbd.sb("send", s.id, "slow held")
    try sbd.waitFor(s.id, "the held turn", timeout: 30) { $0.state == .working }

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, wait)
    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor(s.id, "the turn's end", timeout: 30) { $0.state == .needsYou }
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 41: only a subject whose PR is in `operator.mergeRepos` gets the reader. sbd reads config.json on each
  /// use, so the edit applies without a restart, and putting the repository back starts the reader.
  @Test func aSessionWhosePRIsNotInMergeReposGetsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try sbd.set("operator", to: Self.operatorSettings(["PostHog/other"]))

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, wait)
    try sbd.set("operator", to: Self.operatorSettings([Self.charts]))
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 41: the reader looks only at merge action waits. Arming one afterward starts it.
  @Test func aSessionWithFailingChecksAndNoMergeWaitGetsNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try failingTarget(github, sbd)
    try sbd.serveRuns([Self.run(Self.failed)], head: head(github))
    try sbd.serveFailedLog(Self.log(), run: Self.failed)

    try passTwoWindows(sbd)

    try expectNoReader(sbd, s, nil)
    let wait = try follow.arm(sbd, follow.arming.mergeArgs(s))
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
  }

  /// Decision 42: a new head replaces the CI state, so a failure at the new head gets a reader of its own.
  @Test func aNewHeadGetsAReaderOfItsOwn() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor(s.id, "the reply to the message", timeout: 30) {
      $0.state == .needsYou && $0.lastReply?.contains(Self.framing) == true
    }
    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.serveRuns([Self.run(601)], head: pushed)
    try sbd.serveFailedLog(Self.log("✘ Test parsesDates() failed"), run: 601)
    try sbd.poll(all: true)

    try failTwice(sbd, wait, head: pushed)

    let text = try ciMessage(sbd, s, count: 2)
    #expect(text.hasPrefix(Self.framing + pushed.prefix(7)), Comment(rawValue: text))
    #expect(sbd.ciJudgeInput().contains("✘ Test parsesDates() failed"), Comment(rawValue: sbd.ciJudgeInput()))
    #expect(sbd.ciJudgeCalls().count == 2, "\(sbd.ciJudgeCalls())")
  }

  /// A push while the reader reads the old head's runs makes its answer stale, so sbd drops it, sends nothing, and
  /// counts the new head from its first failure.
  @Test func aPushDuringTheReadDropsTheReadersAnswer() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    let gate = "\(sbd.home.path)/gh-live/run/\(Self.charts)/commit/\(head(github)).gate"
    guard mkfifo(gate, 0o600) == 0 else { throw TestError(description: "mkfifo failed") }
    try failTwice(sbd, wait, head: head(github))
    try sbd.waitFor("the held run list", timeout: 30) { !sbd.ghCalls("run list ").isEmpty }

    let pushed = FakeGitHub.sha(18_400)
    github.change(Self.number) { $0["headRefOid"] = .string(pushed) }
    try sbd.poll(all: true)
    let writer = open(gate, O_WRONLY | O_NONBLOCK)
    if writer >= 0 {
      _ = "go\n".withCString { write(writer, $0, 3) }
      close(writer)
    }
    unlink(gate)

    try sbd.waitFor("the CI judge event", timeout: 30) { try !ciJudgeEvents(sbd).isEmpty }
    try sbd.waitFor("the new head seen", timeout: 30) {
      try follow.tick(sbd)
      let check = try ciCheck(sbd, wait)
      return check?.head == pushed && check?.step == .seen
    }
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciJudgments(sbd, wait).isEmpty)
  }

  /// Decision 42: the state is stored with the wait, so a restart does not send the message again. sbd's clock
  /// offset lives in memory and starts again at zero, so the test moves the clock past where it was before the
  /// restart. Without that, the stored `since` would be in the future and nothing would run for the wrong reason.
  @Test func aRestartDoesNotRepeatTheMessage() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor("the judged step", timeout: 30) { try ciCheck(sbd, wait)?.step == .judged }
    let before = try sbd.now()

    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.now()
    try sbd.advanceClock(max(before - after, 0) + Self.pastHoldRetry)
    try sbd.poll(all: true)
    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.count == 1, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }
}

// MARK: flake

extension CIReaderTests {
  static let flakeRuns = [run(failed), run(502), run(503, "success")]

  /// `armedFailure` with the reader answering `flake` for two failed runs and one that passed.
  func armedFlake(_ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    try sbd.answerCIJudge("flake", message: "The runner lost its network during setup.")
    return try armedFailure(github, sbd, runs: Self.flakeRuns)
  }

  func waitForReruns(_ sbd: Instance, _ count: Int) throws {
    try sbd.waitFor("rerun \(count)", timeout: 30) { sbd.ghReruns().count >= count }
  }

  /// `armedFlake`, the reruns, then the checks running again and failing again at the same head.
  func rerunThenFailAgain(_ github: FakeGitHub, _ sbd: Instance) throws -> (s: SessionSummary, wait: String) {
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)
    github.checks(Self.number, "PENDING")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the rerun's checks running") { $0.state != .needsYou }
    try follow.tick(sbd)
    github.checks(Self.number, "FAILURE")
    try sbd.poll(all: true)
    try sbd.waitFor(s.id, "the rerun's checks failing") { $0.state == .needsYou }
    try follow.tick(sbd)
    try sbd.advanceClock(Self.pastHoldRetry)
    return (s, wait)
  }

  /// Decision 43: `flake` reruns each failed run with `--failed`, and not the run that passed.
  @Test func aFlakeRerunsEachFailedRunOnce() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFlake(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try waitForReruns(sbd, 2)
    try passMoreTicks(sbd)
    #expect(
      sbd.ghReruns().sorted() == ["\(Self.charts) 501 --failed", "\(Self.charts) 502 --failed"], "\(sbd.ghReruns())")
  }

  @Test func aFlakeRecordsTheRerunOnTheWait() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedFlake(github, sbd)

    try failTwice(sbd, wait, head: head(github))

    try waitForReruns(sbd, 2)
    try sbd.waitFor("the reran step", timeout: 30) { try ciCheck(sbd, wait)?.step == .reran }
    #expect(try ciCheck(sbd, wait)?.head == head(github))
  }

  @Test func aFlakeSendsTheSessionAndTheOperatorNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)

    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    try follow.expectNoSentToOperator(sbd)
  }

  /// Decision 43: a second failure at the head after the rerun raises one judgment message to the Operator.
  @Test func aSecondFailureAfterTheRerunRaisesOneOperatorJudgment() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try rerunThenFailAgain(github, sbd)

    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
  }

  /// Risk "a rerun loop": one rerun per head, stored on the wait. The pending rollup between the two failures must
  /// not clear it.
  @Test func aSecondFailureAfterTheRerunRerunsNothingMore() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try rerunThenFailAgain(github, sbd)
    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)

    #expect(sbd.ghReruns().count == 2, "\(sbd.ghReruns())")
    #expect(sbd.ciJudgeCalls().count == 1, "\(sbd.ciJudgeCalls())")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// The rerun passed, so nothing about CI reaches the session or the Operator.
  @Test func aRerunThatPassesRaisesNothing() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFlake(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try waitForReruns(sbd, 2)
    // The subject becomes Ready to merge, so the merge action's live reads must pass.
    try sbd.serve(LiveGitHub(github))

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)
    try passMoreTicks(sbd)

    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.isEmpty, "\(judgments)")
    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ghReruns().count == 2, "\(sbd.ghReruns())")
  }
}

// MARK: Raised to the Operator

extension CIReaderTests {
  /// Each way the reader can't decide, which raises a judgment message to the Operator once per head.
  enum Undecided: String, CaseIterable, CustomTestStringConvertible {
    case judgeFails = "the judge fails"
    case noFailedRun = "only a passing run"
    case noRuns = "no runs"
    case runListFails = "gh run list fails"
    case logReadFails = "gh run view fails"
    case rerunRefused = "gh refuses the rerun"

    var testDescription: String { rawValue }

    /// The CI judge calls that the case makes.
    var judgeCalls: Int { [.judgeFails, .rerunRefused].contains(self) ? 1 : 0 }
  }

  /// A merge wait on a failing fix-cache whose reader can't decide in the way `undecided` says.
  func armedUndecided(_ undecided: Undecided, _ github: FakeGitHub, _ sbd: Instance) throws -> (
    s: SessionSummary, wait: String
  ) {
    switch undecided {
    case .judgeFails:
      return try armedFailure(github, sbd, log: Self.log("✘ FAIL-CI-JUDGE"))
    case .noFailedRun:
      return try armedFailure(github, sbd, runs: [Self.run(503, "success")])
    case .noRuns:
      return try armedFailure(github, sbd, runs: [])
    case .runListFails:
      return try armedFailure(github, sbd, runs: nil)
    case .logReadFails:
      return try armedFailure(github, sbd, log: nil)
    case .rerunRefused:
      try sbd.answerCIJudge("flake")
      try sbd.ghRerunFails(run: Self.failed, with: "HTTP 403: Resource not accessible by integration")
      return try armedFailure(github, sbd)
    }
  }

  /// Decision 43: no failed run, a failed read, a judge failure, or a refused rerun raises one judgment message.
  @Test(arguments: Undecided.allCases)
  func aReaderThatCannotDecideRaisesOneOperatorJudgment(_ undecided: Undecided) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(undecided, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)
    let judgments = try ciJudgments(sbd, wait)
    #expect(judgments.count == 1, "\(judgments)")
  }

  @Test(arguments: Undecided.allCases)
  func aReaderThatCannotDecideSendsTheSessionNothing(_ undecided: Undecided) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedUndecided(undecided, github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciJudgment(sbd, wait)

    try passMoreTicks(sbd)

    let messages = try ciMessages(sbd, s)
    #expect(messages.isEmpty, "\(messages)")
    #expect(sbd.ciJudgeCalls().count == undecided.judgeCalls, "\(sbd.ciJudgeCalls())")
    #expect(try ciCheck(sbd, wait)?.step == .judged)
  }

  /// Decision 44: the CI question names the PR and offers no approval, because no reply is being approved.
  @Test func theOperatorsCIJudgmentNamesThePRAndOffersNoApproval() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    let text = try ciJudgment(sbd, wait)

    #expect(text.hasPrefix("Switchboard: judgment needed for wait \(wait)"), Comment(rawValue: text))
    #expect(text.contains("#\(Self.number)"), Comment(rawValue: text))
    #expect(!text.contains("sb operator approve"), Comment(rawValue: text))
  }

  @Test func aJudgeThatFailsRecordsTheErrorOnTheJudgeEvent() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (_, wait) = try armedUndecided(.judgeFails, github, sbd)
    try failTwice(sbd, wait, head: head(github))

    try ciJudgment(sbd, wait)

    let event = try #require(try ciJudgeEvents(sbd).first)
    #expect(event.data["error"] != nil, Comment(rawValue: event.data.text))
    #expect(event.data["head"]?.string == head(github), Comment(rawValue: event.data.text))
  }
}

// MARK: The merge action

extension CIReaderTests {
  enum Path: String, CaseIterable, CustomTestStringConvertible {
    case message, rerun, raise
    var testDescription: String { rawValue }
  }

  /// Decision 44: the CI path never changes the merge wait's `actionStatus`, so a later Ready to merge still fires
  /// the merge action.
  @Test(arguments: Path.allCases)
  func theCIPathLeavesTheMergeActionsStatusAlone(_ path: Path) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let armed: (s: SessionSummary, wait: String)
    switch path {
    case .message: armed = try armedFailure(github, sbd)
    case .rerun: armed = try armedFlake(github, sbd)
    case .raise: armed = try armedUndecided(.judgeFails, github, sbd)
    }
    let (s, wait) = armed
    let before = try operatorsWait(sbd, wait)?.actionStatus

    try failTwice(sbd, wait, head: head(github))

    switch path {
    case .message: try ciMessage(sbd, s)
    case .rerun: try waitForReruns(sbd, 2)
    case .raise: try ciJudgment(sbd, wait)
    }
    try follow.tick(sbd, 2)
    #expect(try operatorsWait(sbd, wait)?.actionStatus == before)
  }

  /// Success criterion: a subject whose checks pass later still merges through Stage 1's path.
  @Test func aSubjectWhoseChecksPassLaterStillMerges() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let (s, wait) = try armedFailure(github, sbd)
    try failTwice(sbd, wait, head: head(github))
    try ciMessage(sbd, s)
    try sbd.waitFor(s.id, "the reply to the message", timeout: 30) {
      $0.state == .needsYou && $0.lastReply?.contains(Self.framing) == true
    }
    try sbd.serve(LiveGitHub(github))
    try sbd.answerJudge("merge")

    github.checks(Self.number, "SUCCESS")
    try sbd.poll(all: true)

    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try follow.tick(sbd, 2)
    #expect(sbd.ghMerges() == [follow.ghMerge(head(github))], "\(sbd.ghCalls())")
  }
}
