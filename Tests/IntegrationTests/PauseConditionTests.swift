import Foundation
import SwitchboardCore
import Testing

/// The default resume text for a session that you paused without a reason, when its condition resolved with
/// `outcome`.
private func resumeBecause(_ outcome: String) -> String {
  "Switchboard: You were paused by you. You resume because \(outcome). Continue where you left off."
}

private let hourMs: Int64 = 3_600_000

extension Instance {
  /// The `until` field of the session's pause. The test fails when the session has no pause or no condition, so a
  /// test that checks that nothing happened can't pass because the condition was never stored.
  fileprivate func condition(_ id: String) throws -> JSON {
    let until = try #require(try pauseField(id)?["until"], "the session has no pause condition")
    try #require(until != .null, "the session has no pause condition")
    return until
  }

  fileprivate func conditionId(_ id: String) throws -> String {
    try #require(try condition(id)["id"]?.string)
  }

  fileprivate func unpausedEvents(_ id: String, after mark: Int64) throws -> [Event] {
    try events(id, after: mark).filter { $0.kind == "unpaused" }
  }

  /// Checks that a met condition resumed the session once: the pause is gone, one `unpaused` event carries the
  /// outcome, one launch has the `wait` trigger, and claude's first prompt is `prompt`. Every way that a condition
  /// resolves goes through this check, so that the tick, the poller, and `resolve-wait` agree.
  fileprivate func expectResumedByCondition(_ id: String, after mark: Int64, outcome: String, prompt: String) throws {
    let prompts = try waitForPrompts(id, after: mark, count: 1)
    #expect(prompts.first == prompt)
    usleep(1_000_000)
    #expect(try pauseField(id) == nil)
    let unpaused = try unpausedEvents(id, after: mark)
    #expect(unpaused.count == 1)
    #expect(unpaused.first?.data["outcome"]?.string == outcome, "\(unpaused.map(\.data))")
    let launches = try launchEvents(id, after: mark)
    #expect(launches.count == 1)
    #expect(launches.first?.data["trigger"] == "wait", "\(launches.map(\.data))")
  }

  /// Checks that the session stays paused after `mark`: no `unpaused` event, no launch, and no live claude.
  fileprivate func expectStillPaused(_ id: String, after mark: Int64) throws {
    #expect(try pauseField(id) != nil)
    #expect(try unpausedEvents(id, after: mark).isEmpty)
    #expect(try launchEvents(id, after: mark).isEmpty)
    #expect(try !get(id).live)
  }

  /// The session's open wait of the kind.
  fileprivate func openWait(_ id: String, _ kind: Wait.Kind) throws -> Wait {
    try #require(try get(id).waits.first { $0.kind == kind })
  }

  /// Waits until the claude that the pause stopped has exited.
  fileprivate func waitForPausedExit(_ id: String) throws {
    try waitFor(id, "claude to exit after the pause") { !$0.live && $0.claudePid == nil }
  }
}

/// `sb pause --until`: a `date`, `merge`, or `session` condition that resumes the session when it's met, and a
/// paused session's own waits.
@Suite(.blocking(timeLimit: .seconds(120))) struct PauseConditionTests {
  // MARK: Setting a condition

  @Test func aDateConditionIsStoredOnThePauseAndNotAsAWait() throws {
    let sbd = try Instance()
    let before = try sbd.now()

    let s = try sbd.pausedStopped("t", ["--until", "1h"])

    let until = try sbd.condition(s.id)
    #expect(until["kind"] == "date")
    let at = try #require(until["until"]?.int)
    #expect(Int64(at) >= before + hourMs)
    #expect(Int64(at) <= (try sbd.now()) + hourMs)
    #expect(try sbd.get(s.id).waits.isEmpty)
    #expect(try sbd.get(s.id).reason.hasPrefix("Paused by you; resumes when at "))
  }

  @Test(arguments: [
    ("pr:1190", "#1190"), ("#1190", "#1190"), ("PostHog/posthog#1190", "PostHog/posthog#1190"),
    ("https://github.com/PostHog/posthog/pull/1190", "PostHog/posthog#1190"),
  ])
  func aPRConditionIsAMergeConditionWithNoRecheck(_ text: String, _ pr: String) throws {
    let sbd = try Instance()

    let s = try sbd.pausedStopped("t", ["--until", text])

    let until = try sbd.condition(s.id)
    #expect(until["kind"] == "merge")
    #expect(until["pr"]?["number"]?.int == 1190)
    #expect(until["recheck"]?.int == nil)
    #expect(try sbd.get(s.id).reason == "Paused by you; resumes when \(pr) merges")
  }

  /// The other session reaches Needs you on its own within seconds, so a condition on Needs you would resume at once.
  @Test func aSessionConditionNamesTheOtherSessionAndTheState() throws {
    let sbd = try Instance()
    let other = try sbd.new(name: "other")

    let s = try sbd.pausedStopped("t", ["--until", "session:other=ready_to_merge"])

    let until = try sbd.condition(s.id)
    #expect(until["kind"] == "session")
    #expect(until["session"]?["id"]?.string == other.id)
    #expect(until["state"] == "ready_to_merge")
    #expect(until["recheck"]?.int == nil)
    #expect(try sbd.get(s.id).reason == "Paused by you; resumes when other reaches Ready to merge")
  }

  @Test func aSessionConditionWaitsForDoneByDefault() throws {
    let sbd = try Instance()
    _ = try sbd.new(name: "other")

    let s = try sbd.pausedStopped("t", ["--until", "session:other"])

    #expect(try sbd.condition(s.id)["state"] == "done")
    #expect(try sbd.get(s.id).reason == "Paused by you; resumes when other reaches Done")
  }

  @Test func theConditionShowsInGetAndLs() throws {
    let sbd = try Instance()

    let s = try sbd.pausedStopped("t", ["--until", "#1190", "--reason", "wait for the fix"])

    let line = try #require(try sbd.sb("get", s.id).split(separator: "\n").first { $0.contains("paused:") })
    #expect(line.contains("wait for the fix; resumes when #1190 merges"), "\(line)")
    #expect(try sbd.listed(s.id)["reason"] == "Paused by you: wait for the fix; resumes when #1190 merges")
  }

  /// A second pause replaces the condition, so the first one's time passes without a resume.
  @Test func aSecondPauseReplacesTheCondition() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)
    let before = try sbd.now()

    try sbd.pauseJSON(s.id, ["--until", "3h"])

    let second = try sbd.condition(s.id)
    #expect(second["kind"] == "date")
    #expect(Int64(try #require(second["until"]?.int)) >= before + 3 * hourMs)
    #expect(try sbd.events(s.id).filter { $0.kind == "paused" }.count == 2)
    let mark = try sbd.lastEventId(s.id)
    try sbd.advanceClock(2 * hourMs)
    try sbd.tickThrice()
    try sbd.expectStillPaused(s.id, after: mark)
    try sbd.advanceClock(2 * hourMs)
    try sbd.expectResumedByCondition(
      s.id, after: mark, outcome: "the time came", prompt: resumeBecause("the time came"))
  }

  /// A second pause without `--until` replaces the condition with none.
  @Test func aSecondPauseWithoutUntilDropsTheCondition() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)

    try sbd.pauseJSON(s.id, ["--reason", "hold on"])

    let until = try sbd.pauseField(s.id)?["until"]
    #expect(until == nil || until == .null)
    let mark = try sbd.lastEventId(s.id)
    try sbd.advanceClock(2 * hourMs)
    try sbd.tickThrice()
    try sbd.expectStillPaused(s.id, after: mark)
  }

  // MARK: Refusals

  enum BadUntil: String, CaseIterable, Sendable {
    case bareNumber, word, pastTime, notAPR, emptySession, unknownSession, unknownState, itselfById, itselfByName
  }

  /// sbd refuses the condition before it pauses anything, so claude keeps running.
  @Test(arguments: BadUntil.allCases)
  func aConditionThatCantBeUsedIsRefusedAndLeavesTheSessionRunning(_ bad: BadUntil) throws {
    let sbd = try Instance()
    _ = try sbd.new(name: "other")
    let s = try sbd.liveIdle("t")
    let pid = try #require(s.claudePid)
    let text: String
    switch bad {
    case .bareNumber: text = "30"
    case .word: text = "soon"
    case .pastTime: text = "2020-01-01 09:00"
    case .notAPR: text = "pr:abc"
    case .emptySession: text = "session:"
    case .unknownSession: text = "session:nosuch"
    case .unknownState: text = "session:other=bogus"
    case .itselfById: text = "session:\(s.id)"
    case .itselfByName: text = "session:t"
    }

    let r = try sbd.run(["pause", s.id, "--until", text])

    #expect(r.status != 0, "\(r.stdout)")
    if bad == .bareNumber {
      #expect(r.stderr.contains("#30"), "\(r.stderr)")
      #expect(r.stderr.contains("30m"), "\(r.stderr)")
    }
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try !sbd.events(s.id).contains { $0.kind == "paused" })
    #expect(sbd.runs(pid))
    #expect(try sbd.get(s.id).claudePid == pid)
  }

  // MARK: A met condition resumes the session

  @Test func aDateConditionResumesTheSessionWithItsMessageWhenTheTimeComes() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h", "--message", "check the dashboard"])
    _ = try sbd.condition(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)

    try sbd.expectResumedByCondition(s.id, after: mark, outcome: "the time came", prompt: "check the dashboard")
  }

  @Test func aDateConditionWithoutAMessageResumesWithTextThatSaysWhy() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)

    try sbd.expectResumedByCondition(
      s.id, after: mark, outcome: "the time came", prompt: resumeBecause("the time came"))
    let launch = try #require(sbd.stubArgs().last { $0.hasPrefix("--resume \(s.claudeSessionId) ") })
    #expect(launch.contains(resumeBecause("the time came")), "\(launch)")
  }

  @Test func aDateConditionDoesNotResumeBeforeItsTime() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(30 * 60_000)
    try sbd.tickThrice()

    try sbd.expectStillPaused(s.id, after: mark)
  }

  /// `sb wait --resolve --id` is the `resolve-wait` request that the poller sends.
  @Test func resolvingTheConditionByItsIdResumesTheSession() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "pr:1190"])
    let id = try sbd.conditionId(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("wait", s.id, "--resolve", "it merged", "--id", id)

    try sbd.expectResumedByCondition(s.id, after: mark, outcome: "it merged", prompt: resumeBecause("it merged"))
  }

  @Test func thePollerResumesTheSessionWhenTheConditionsPRMerges() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.charts, branch: PollerWaitTests.branch)
    try sbd.poll()
    try sbd.pauseJSON(s.id, ["--until", "#18303"])
    try sbd.waitForPausedExit(s.id)
    #expect(try sbd.condition(s.id)["kind"] == "merge")
    let mark = try sbd.lastEventId(s.id)
    try sbd.poll()
    try sbd.expectStillPaused(s.id, after: mark)

    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(stamp(60))
    }
    try sbd.poll()

    try sbd.expectResumedByCondition(s.id, after: mark, outcome: "it merged", prompt: resumeBecause("it merged"))
  }

  enum TargetEnd: String, CaseIterable, Sendable { case done, removed, doneBeforeItsState }

  @Test(arguments: TargetEnd.allCases)
  func aSessionConditionResumesTheSessionWhenTheOtherSessionGetsThere(_ end: TargetEnd) throws {
    let sbd = try Instance()
    let other = try sbd.idleSession(name: "other")
    let until = end == .doneBeforeItsState ? "session:other=ready_for_review" : "session:other"
    let s = try sbd.pausedStopped("t", ["--until", until])
    _ = try sbd.condition(s.id)
    let mark = try sbd.lastEventId(s.id)
    let outcome: String
    switch end {
    case .done:
      try sbd.sb("done", other.id)
      outcome = "it did"
    case .removed:
      try sbd.sb("rm", other.id)
      outcome = "it was removed"
    case .doneBeforeItsState:
      try sbd.sb("done", other.id)
      outcome = "it reached Done first"
    }

    try sbd.expectResumedByCondition(s.id, after: mark, outcome: outcome, prompt: resumeBecause(outcome))
  }

  /// sbd loads the condition with the session's row, so the tick still resolves it after a restart, and only once.
  @Test func aConditionResumesTheSessionOnceAfterARestart() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.condition(s.id)["kind"] == "date")
    let mark = try sbd.lastEventId(s.id)
    try sbd.advanceClock(2 * hourMs)
    try sbd.expectResumedByCondition(
      s.id, after: mark, outcome: "the time came", prompt: resumeBecause("the time came"))
    try sbd.tickThrice()
    #expect(try sbd.unpausedEvents(s.id, after: mark).count == 1)
    #expect(try sbd.launchEvents(s.id, after: mark).count == 1)
  }

  // MARK: What doesn't resume the session

  @Test func aPausedSessionMarkedDoneDoesNotResumeWhenItsConditionIsMet() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)
    try sbd.sb("done", s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)
    try sbd.tickThrice()

    try sbd.expectStillPaused(s.id, after: mark)
    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.condition(s.id)["kind"] == "date")
  }

  @Test func resolvingAnOrdinaryWaitOfAPausedSessionKeepsThePauseAndHoldsTheMessage() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    let condition = try sbd.conditionId(s.id)
    try sbd.sb("wait", s.id, "--kind", "ci")
    let ci = try sbd.openWait(s.id, .ci)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("wait", s.id, "--resolve", "the checks passed", "--id", ci.id)

    try sbd.tickThrice()
    try sbd.expectStillPaused(s.id, after: mark)
    #expect(try sbd.heldCount(s.id) == 1)
    #expect(try sbd.conditionId(s.id) == condition)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }

  @Test func clearingWaitsWithNoIdKeepsTheCondition() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    let condition = try sbd.conditionId(s.id)
    try sbd.sb("wait", s.id, "--kind", "ci")

    try sbd.sb("wait", s.id, "--clear")

    #expect(try sbd.get(s.id).waits.isEmpty)
    #expect(try sbd.conditionId(s.id) == condition)
    let mark = try sbd.lastEventId(s.id)
    try sbd.advanceClock(2 * hourMs)
    try sbd.expectResumedByCondition(
      s.id, after: mark, outcome: "the time came", prompt: resumeBecause("the time came"))
  }

  /// Only a resume or the condition itself ends the pause, so naming the condition to `--clear` leaves it.
  @Test func clearingTheConditionsIdKeepsTheCondition() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    let condition = try sbd.conditionId(s.id)
    let mark = try sbd.lastEventId(s.id)

    _ = try sbd.run(["wait", s.id, "--clear", "--id", condition])

    #expect(try sbd.conditionId(s.id) == condition)
    try sbd.expectStillPaused(s.id, after: mark)
  }

  @Test func clearingTheConditionsIdIsRefusedWithTheWayToEndIt() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    let condition = try sbd.conditionId(s.id)

    let r = try sbd.run(["wait", s.id, "--clear", "--id", condition])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("sb resume \(s.id)"), "\(r.stderr)")
    #expect(try !sbd.events(s.id).contains { $0.kind == "wait-cleared" })
  }

  /// The resume clears the condition with the pause, so its time passes without a second resume or a message.
  @Test func aResumeByHandEndsTheCondition() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped("t", ["--until", "1h"])
    _ = try sbd.condition(s.id)
    let resumeMark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id)
    try sbd.waitForPrompts(s.id, after: resumeMark, count: 1)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)
    try sbd.tickThrice()

    #expect(try sbd.unpausedEvents(s.id, after: mark).isEmpty)
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(try !sbd.events(s.id, after: mark).contains { $0.kind == "sent" })
    #expect(try sbd.unpausedEvents(s.id, after: resumeMark).first?.data["outcome"] == nil)
  }

  // MARK: Waits while paused

  @Test func aDateWaitResolvesWhilePausedAndItsMessageFollowsTheResumeMessage() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)

    try sbd.waitFor("the wait to resolve") { try sbd.events(s.id, after: mark).contains { $0.kind == "wait-resolved" } }
    try sbd.tickThrice()
    try sbd.expectStillPaused(s.id, after: mark)
    #expect(try sbd.heldCount(s.id) == 1)
    #expect(try sbd.get(s.id).waits.isEmpty)
    let resumeMark = try sbd.lastEventId(s.id)
    try sbd.sb("resume", s.id, "--message", "go on")
    let prompts = try sbd.waitForPrompts(s.id, after: resumeMark, count: 2)
    #expect(prompts.first == "go on")
    #expect(prompts.dropFirst().first?.hasPrefix("Switchboard: until ") == true, "\(prompts)")
    #expect(prompts.dropFirst().first?.contains("the time came") == true, "\(prompts)")
  }

  /// A paused session's waits keep resolving, so `sb wait --block` returns while the session stays paused.
  @Test func aBlockedWaitOfAPausedSessionReturnsWhenItResolves() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mark = try sbd.lastEventId(s.id)
    let blocked = try BackgroundSb(sbd, ["wait", s.id, "--block", "--kind", "date", "--until", "1m"])
    try sbd.waitFor(s.id, "the blocked wait") { $0.waits.count == 1 }
    try #require(blocked.isRunning, "sb wait --block exited before its wait resolved")

    try sbd.advanceClock(2 * 60_000)

    let r = try blocked.finish(within: 15)
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.tickThrice()
    try sbd.expectStillPaused(s.id, after: mark)
  }

  /// A `ci` wait rechecks 2 h after it was set. The resume comes 1 h in, so the recheck moves to 2 h after the
  /// resume, and the wait isn't overdue 90 min after the resume.
  @Test func resumingRestampsTheRecheckOfAnOpenWaitFromTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("wait", s.id, "--kind", "ci")
    let set = try sbd.openWait(s.id, .ci)
    try #require(set.recheck == set.created + 2 * hourMs)
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try sbd.advanceClock(hourMs)
    let mark = try sbd.lastEventId(s.id)
    let before = try sbd.now()

    try sbd.sb("resume", s.id)

    let after = try sbd.now()
    let recheck = try #require(try sbd.openWait(s.id, .ci).recheck)
    #expect(recheck >= before + 2 * hourMs)
    #expect(recheck <= after + 2 * hourMs)
    try sbd.waitForPrompts(s.id, after: mark, count: 1)
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard: You were paused") == true }
    try sbd.advanceClock(90 * 60_000)
    let later = try sbd.get(s.id)
    #expect(later.state != .needsYou)
    #expect(!later.reason.contains("still open after"), "\(later.reason)")
  }

  /// A `review` wait rechecks a day after it was set, and that day passes while the session is paused.
  @Test func aWaitWhoseRecheckPassedWhilePausedIsNotOverdueAfterTheResume() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try sbd.advanceClock(25 * hourMs)
    #expect(try sbd.get(s.id).reason == "Paused by you")
    let mark = try sbd.lastEventId(s.id)
    let before = try sbd.now()

    try sbd.sb("resume", s.id)

    try sbd.waitForPrompts(s.id, after: mark, count: 1)
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard: You were paused") == true }
    try sbd.tickThrice()
    let resumed = try sbd.get(s.id)
    #expect(resumed.state == .waiting)
    #expect(resumed.reason == "a review from alex on the session's PR")
    let recheck = try #require(try sbd.openWait(s.id, .review).recheck)
    #expect(recheck >= before + 24 * hourMs)
  }

  /// A `date` wait and a manual wait with `--until` carry their own times and no recheck, so the resume leaves them.
  @Test func resumingKeepsTheTimesOfDateAndManualWaits() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "10h")
    try sbd.sb("wait", s.id, "--kind", "manual", "--note", "ask Alex", "--until", "10h")
    let set = try sbd.get(s.id).waits
    try #require(set.count == 2)
    try sbd.pauseJSON(s.id)
    try sbd.waitForPausedExit(s.id)
    try sbd.advanceClock(hourMs)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("resume", s.id)

    try sbd.waitForPrompts(s.id, after: mark, count: 1)
    #expect(try sbd.get(s.id).waits == set)
  }

  // MARK: The same tick

  /// The ordinary wait and the condition come due on one tick. Whichever resolves first, claude starts once and gets
  /// the resume message before the wait's message.
  @Test func anOrdinaryWaitAndTheConditionDueOnOneTickResumeOnceWithTheResumeMessageFirst() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try sbd.pauseJSON(s.id, ["--until", "1h", "--message", "go on"])
    try sbd.waitForPausedExit(s.id)
    _ = try sbd.condition(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * hourMs)

    let prompts = try sbd.waitForPrompts(s.id, after: mark, count: 2)
    #expect(prompts.first == "go on")
    #expect(prompts.dropFirst().first?.hasPrefix("Switchboard: until ") == true, "\(prompts)")
    usleep(1_500_000)
    #expect(try sbd.promptsSince(s.id, after: mark).count == 2)
    #expect(try sbd.launchEvents(s.id, after: mark).count == 1)
    #expect(try sbd.unpausedEvents(s.id, after: mark).count == 1)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "wait-resolved" }.count == 1)
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.get(s.id).waits.isEmpty)
  }
}
