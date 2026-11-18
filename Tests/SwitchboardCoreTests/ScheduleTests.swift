import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 1_800_000_000_000
private let second: Int64 = 1000
private let minute: Int64 = 60 * second
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour
private let week: Int64 = 7 * day

private func make(every: String? = "30m", prompt: String? = "check the queue", by: String? = nil, at time: Int64 = now)
  throws -> Schedule
{
  try ScheduleRequest(every: every, prompt: prompt, by: by).makeSchedule(id: "rk3x9p", now: time)
}

/// The message of the error that the body throws, or "no error".
private func message(_ body: () throws -> Any) -> String {
  do {
    _ = try body()
    return "no error"
  } catch {
    return "\(error)"
  }
}

private func sessionWithSchedules() throws -> Session {
  var s = Session(id: "s1", name: "manager", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
  var active = try make(every: "30m", prompt: "/audit-waiting")
  active.last = Schedule.Run(t: now - 5 * minute, outcome: .pasted, skipped: 0, error: nil)
  var paused = try ScheduleRequest(every: "1h", prompt: "check the queue", by: "claude").makeSchedule(
    id: "r2mzq4", now: now)
  paused.paused = true
  paused.last = Schedule.Run(t: now - hour, outcome: .failed, skipped: 2, error: "the folder /tmp/a is gone")
  s.schedules = [active, paused]
  return s
}

/// The object form of an encoded value, with `key` removed.
private func encoded(_ value: some Encodable, without key: String) throws -> String {
  var object = try #require(JSON.parse(try JSONCoding.encode(value))?.object)
  object[key] = nil
  return JSON.object(object).text
}

@Suite struct ScheduleTests {
  @Suite struct ParseInterval {
    @Test(arguments: [
      ("90s", 90 * second),
      ("30m", 30 * minute),
      ("1h", hour),
      ("2d", 2 * day),
      ("1w", week),
    ])
    func readsOneNumberAndOneUnit(_ text: String, _ ms: Int64) throws {
      #expect(try Schedule.parseInterval(text) == ms)
    }

    @Test(arguments: ["60s", "1m"])
    func oneMinuteIsTheShortestInterval(_ text: String) throws {
      #expect(try Schedule.parseInterval(text) == Schedule.minInterval)
    }

    @Test func theShortestIntervalIsSixtySeconds() {
      #expect(Schedule.minInterval == 60_000)
    }

    @Test(arguments: ["59s", "0m", "0s", "1s"])
    func refusesAnIntervalUnderOneMinute(_ text: String) {
      #expect(message { try Schedule.parseInterval(text) }.contains("the shortest interval is 1m"))
    }

    @Test(arguments: [
      "30", "m", "", "30M", "-5m", "+5m", " 30m", "30m ", "1.5h", "5 m", "soon", "1d1h", "99999999999999w",
    ])
    func refusesTextThatIsNotOneWholeNumberAndOneUnit(_ text: String) {
      #expect(throws: (any Error).self) { try Schedule.parseInterval(text) }
    }

    @Test func refusesACompoundIntervalWithAHint() {
      let error = message { try Schedule.parseInterval("1h30m") }
      #expect(error != "no error")
      #expect(error.contains("90m"))
    }
  }

  @Suite struct IntervalText {
    @Test(arguments: [
      (90 * second, "90s"),
      (minute, "1m"),
      (30 * minute, "30m"),
      (90 * minute, "90m"),
      (hour, "1h"),
      (25 * hour, "25h"),
      (day, "1d"),
      (2 * day, "2d"),
      (week, "1w"),
      (2 * week, "2w"),
    ])
    func usesTheLargestUnitThatDividesEvenly(_ ms: Int64, _ text: String) {
      #expect(Schedule.intervalText(ms) == text)
    }

    @Test(arguments: ["90s", "1m", "30m", "90m", "1h", "25h", "1d", "2d", "1w", "2w"])
    func readsBackAsTheSameText(_ text: String) throws {
      #expect(Schedule.intervalText(try Schedule.parseInterval(text)) == text)
    }

    @Test(arguments: [("60m", "1h"), ("120s", "2m"), ("7d", "1w"), ("24h", "1d"), ("3600s", "1h")])
    func writesAnEqualIntervalInTheLargestUnit(_ typed: String, _ written: String) throws {
      #expect(Schedule.intervalText(try Schedule.parseInterval(typed)) == written)
    }

    @Test(arguments: [minute, 90 * second, 30 * minute, 25 * hour, 2 * day, 3 * week])
    func parsesBackToTheSameMilliseconds(_ ms: Int64) throws {
      #expect(try Schedule.parseInterval(Schedule.intervalText(ms)) == ms)
    }
  }

  @Suite struct MakeSchedule {
    @Test func theFirstRunIsOneIntervalAfterNow() throws {
      let s = try make(every: "30m")
      #expect(s.every == 30 * minute)
      #expect(s.next == now + 30 * minute)
    }

    @Test func recordsTheIdAndTheTimeItWasMade() throws {
      let s = try make()
      #expect(s.id == "rk3x9p")
      #expect(s.created == now)
    }

    @Test func aNewScheduleIsActiveAndHasNeverRun() throws {
      let s = try make()
      #expect(s.paused == nil)
      #expect(s.last == nil)
    }

    @Test func theAuthorDefaultsToYou() throws {
      #expect(try make(by: nil).by == .you)
    }

    @Test func claudeCanBeTheAuthor() throws {
      #expect(try make(by: "claude").by == .claude)
    }

    @Test func refusesAnUnknownAuthor() {
      #expect(throws: (any Error).self) { try make(by: "robot") }
    }

    @Test func trimsThePrompt() throws {
      #expect(try make(prompt: "  \n check the queue \t\n").prompt == "check the queue")
    }

    @Test func keepsASlashCommandPromptVerbatim() throws {
      #expect(try make(prompt: "/audit-waiting --all").prompt == "/audit-waiting --all")
    }

    @Test(arguments: [nil, "", "   ", " \n\t "] as [String?])
    func refusesAnEmptyPromptAndNamesTheField(_ prompt: String?) {
      let error = message { try make(prompt: prompt) }
      #expect(error != "no error")
      #expect(error.contains("prompt"))
    }

    @Test(arguments: [nil, "", "soon", "30", "1h30m", "30M", "-5m", " 30m", "99999999999999w"] as [String?])
    func refusesAMissingOrUnreadableIntervalAndNamesTheField(_ every: String?) {
      let error = message { try make(every: every) }
      #expect(error != "no error")
      #expect(error.contains("every"))
    }

    @Test(arguments: ["59s", "0m", "30s"])
    func refusesAnIntervalUnderOneMinute(_ every: String) {
      let error = message { try make(every: every) }
      #expect(error.contains("the shortest interval is 1m"))
      #expect(error.contains("every"))
    }

    @Test func refusesAnIntervalWhoseFirstRunOverflowsTheClock() {
      let error = message { try make(every: "1m", at: Int64.max - 1000) }
      #expect(error != "no error")
      #expect(error.contains("every"))
    }

    @Test func acceptsTheLastTimeThatDoesNotOverflow() throws {
      #expect(try make(every: "1m", at: Int64.max - minute).next == Int64.max)
    }
  }

  @Suite struct Limits {
    @Test func aSessionHoldsAtMostTenSchedules() {
      #expect(Schedule.maxPerSession == 10)
    }
  }

  @Suite struct Coding {
    /// sbd reads the rows that an older sbd stored. Their JSON has no `schedules` key.
    @Test func anOlderSessionRowDecodesWithNoSchedules() throws {
      let row = """
        {"claudeSessionId": "u1", "created": 5, "cwd": "/tmp/a", "done": false, "id": "s1", "name": "one",
         "started": true, "waits": [], "notes": []}
        """
      #expect(try JSONCoding.decode(Session.self, from: row).schedules == nil)
    }

    @Test func aSessionRowWithoutTheKeyDecodesAsTheSameSessionWithNoSchedules() throws {
      var s = try sessionWithSchedules()
      let decoded = try JSONCoding.decode(Session.self, from: try encoded(s, without: "schedules"))
      s.schedules = nil
      #expect(decoded == s)
    }

    @Test func aSessionWithSchedulesRoundTrips() throws {
      let s = try sessionWithSchedules()
      #expect(try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s)) == s)
    }

    @Test func aNewScheduleEncodesNoPausedOrLastKey() throws {
      let object = try #require(JSON.parse(try JSONCoding.encode(try make()))?.object)
      #expect(Set(object.keys) == ["id", "prompt", "every", "next", "by", "created"])
    }

    @Test func aFailedRunKeepsItsErrorAndSkippedCount() throws {
      let run = Schedule.Run(t: now, outcome: .failed, skipped: 3, error: "no folder")
      let decoded = try JSONCoding.decode(Schedule.Run.self, from: try JSONCoding.encode(run))
      #expect(decoded == run)
    }

    /// `pasted`, `resumed`, and `queued` are the raw values of `Delivery`, which `send` returns.
    @Test(arguments: [Delivery.pasted, .resumed, .queued])
    func eachDeliveryIsAnOutcome(_ delivery: Delivery) throws {
      let text = #"{"t": 1, "outcome": "\#(delivery.rawValue)", "skipped": 0}"#
      let run = try JSONCoding.decode(Schedule.Run.self, from: text)
      #expect(try JSONCoding.encode(run.outcome) == JSONCoding.encode(delivery))
    }

    @Test func failedIsAnOutcome() throws {
      let run = try JSONCoding.decode(Schedule.Run.self, from: #"{"t": 1, "outcome": "failed", "skipped": 0}"#)
      #expect(try JSONCoding.encode(run.outcome) == #""failed""#)
    }

    /// A row nests the schedule, so its Codable is synthesized.
    @Test func aRowNestsTheSchedule() throws {
      let schedule = try make()
      let row = ScheduleRow(session: "s1", name: "manager", schedule: schedule)
      let object = try #require(JSON.parse(try JSONCoding.encode(row))?.object)
      #expect(object["session"]?.string == "s1")
      #expect(object["name"]?.string == "manager")
      #expect(object["schedule"]?.object?["id"]?.string == schedule.id)
    }

    @Test func aRowRoundTrips() throws {
      let row = ScheduleRow(session: "s1", name: "manager", schedule: try make())
      let decoded = try JSONCoding.decode(ScheduleRow.self, from: try JSONCoding.encode(row))
      #expect(decoded.session == row.session)
      #expect(decoded.name == row.name)
      #expect(decoded.schedule == row.schedule)
    }

    /// A newer sb reads the summary that an sbd from before schedules sends.
    @Test func aSummaryWithoutTheKeyDecodesWithNoSchedules() throws {
      var summary = SessionSummary(
        id: "s1", name: "one", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "u1", state: .working,
        reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
        waits: [], notes: [])
      summary.schedules = [try make()]
      let decoded = try JSONCoding.decode(SessionSummary.self, from: try encoded(summary, without: "schedules"))
      #expect(decoded.schedules == nil)
    }

    @Test func aSummaryWithSchedulesRoundTrips() throws {
      var summary = SessionSummary(
        id: "s1", name: "one", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "u1", state: .working,
        reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
        waits: [], notes: [])
      summary.schedules = try sessionWithSchedules().schedules
      let decoded = try JSONCoding.decode(SessionSummary.self, from: try JSONCoding.encode(summary))
      #expect(decoded.schedules == summary.schedules)
    }
  }

  @Suite struct FromNow {
    @Test func aFutureTimeReadsAsInAndTheTime() {
      #expect(fromNow(now + 12 * minute, now: now) == "in 12m")
    }

    @Test(arguments: [second, minute, day])
    func aPastTimeReadsAsNow(_ behind: Int64) {
      #expect(fromNow(now - behind, now: now) == "now")
    }

    /// `fromNow` uses the same units and the same rounding as `ago`.
    @Test(arguments: [second, 59 * second, 59_999, minute, 3599 * second, hour, 86399 * second, day, 10 * day])
    func aFutureTimeUsesTheUnitsOfAgo(_ ahead: Int64) {
      #expect(fromNow(now + ahead, now: now) == "in \(ago(now - ahead, now: now))")
    }

    @Test func defaultNowReadsTheClock() {
      #expect(fromNow(nowMs() + 2 * hour + 30 * minute) == "in 2h")
    }
  }
}

private func due(at next: Int64, every: Int64 = 30 * minute, paused: Bool? = nil) -> Schedule {
  Schedule(
    id: "rk3x9p", prompt: "check the queue", every: every, next: next, paused: paused, by: .you,
    created: next - every)
}

private func idleFacts() -> SessionFacts {
  var f = SessionFacts()
  f.live = true
  return f
}

/// The prompts that `PromptGuard.openCard` reports. The card from `sb summary set` is left out.
private let scheduleGuardedCards = AutoContinueGuardTests.OpenPrompt.allCases.filter { $0 != .sessionCard }

extension ScheduleTests {
  @Suite struct IsDue {
    @Test func aScheduleWhoseNextRunIsNowIsDue() {
      #expect(due(at: now).isDue(now: now))
    }

    @Test func aScheduleWhoseNextRunHasPassedIsDue() {
      #expect(due(at: now - hour).isDue(now: now))
    }

    @Test func aScheduleWhoseNextRunIsAheadIsNotDue() {
      #expect(!due(at: now + 1).isDue(now: now))
    }

    @Test func aPausedScheduleIsNotDue() {
      #expect(!due(at: now - hour, paused: true).isDue(now: now))
    }

    /// Only `paused == true` pauses a schedule. Nil and false both mean active.
    @Test func aScheduleWithPausedFalseIsDue() {
      #expect(due(at: now - hour, paused: false).isDue(now: now))
    }
  }

  @Suite struct Fired {
    @Test func aRunOnTimeSkipsNothing() {
      let fired = due(at: now).fired(at: now)

      #expect(fired.skipped == 0)
    }

    @Test func aRunLessThanOneIntervalLateSkipsNothing() {
      let fired = due(at: now - 29 * minute).fired(at: now)

      #expect(fired.skipped == 0)
    }

    @Test func aRunOneAndAHalfIntervalsLateSkipsOne() {
      let fired = due(at: now - 45 * minute).fired(at: now)

      #expect(fired.skipped == 1)
    }

    @Test func aRunFiveIntervalsLateSkipsFive() {
      let fired = due(at: now - 5 * 30 * minute).fired(at: now)

      #expect(fired.skipped == 5)
    }

    /// The next run counts from the run, not from the old grid, so a run held
    /// for most of an interval is not followed by another one at once.
    @Test(arguments: [0, 1, 29 * minute, 45 * minute, 150 * minute, 3 * day])
    func theNextRunIsOneIntervalAfterTheRun(_ late: Int64) {
      let fired = due(at: now - late).fired(at: now)

      #expect(fired.next == now + 30 * minute)
    }

    @Test(arguments: [minute, 30 * minute, week])
    func theNextRunUsesTheSchedulesInterval(_ every: Int64) {
      let fired = due(at: now - 2 * every, every: every).fired(at: now)

      #expect(fired.next == now + every)
    }

    /// A message whose `UserPromptSubmit` never came stops holding the session
    /// after its in-flight window. The schedule must still wait for its next run.
    @Test(arguments: [0, 10 * second, 11 * second, 30 * minute - 1])
    func aFiredScheduleIsNotDueAgainBeforeOneInterval(_ after: Int64) {
      var s = due(at: now - 45 * minute)
      s.next = s.fired(at: now).next

      #expect(!s.isDue(now: now + after))
    }

    @Test func aFiredScheduleIsDueAgainOneIntervalAfterTheRun() {
      var s = due(at: now - 45 * minute)
      s.next = s.fired(at: now).next

      #expect(s.isDue(now: now + 30 * minute))
    }
  }

  @Suite struct Blocker {
    @Test func anIdleLiveClaudeIsFree() {
      #expect(Schedule.blocker(facts: idleFacts(), process: .running, messageWaiting: false) == nil)
    }

    /// `send` resumes a stopped claude with the prompt.
    @Test func aStoppedClaudeWithNothingWaitingIsFree() {
      #expect(Schedule.blocker(facts: SessionFacts(), process: .stopped, messageWaiting: false) == nil)
    }

    /// The host link has no snapshot, so sbd can't read the process. `send`
    /// would queue the prompt on every tick.
    @Test func anUnknownProcessHolds() {
      #expect(
        Schedule.blocker(facts: idleFacts(), process: nil, messageWaiting: false) == "its host is not connected")
    }

    @Test func aRunningTurnHolds() {
      var f = idleFacts()
      f.turnRunning = true

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == "a turn is running")
    }

    @Test func anOpenPermissionHolds() {
      var f = idleFacts()
      f.turnRunning = true
      AutoContinueGuardTests.OpenPrompt.permission.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == "an open card")
    }

    @Test func anOpenQuestionHolds() {
      var f = idleFacts()
      f.turnRunning = true
      AutoContinueGuardTests.OpenPrompt.question.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == "an open card")
    }

    /// A deferred question's turn has ended. A new prompt would start a turn without the user's answer.
    @Test func aDeferredCardWithNoTurnHolds() {
      var f = idleFacts()
      AutoContinueGuardTests.OpenPrompt.deferredCard.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == "an open card")
    }

    @Test(arguments: scheduleGuardedCards)
    func eachKindOfCardHolds(_ open: AutoContinueGuardTests.OpenPrompt) {
      var f = idleFacts()
      open.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == "an open card")
    }

    @Test(arguments: scheduleGuardedCards)
    func aCardOnAStoppedClaudeHolds(_ open: AutoContinueGuardTests.OpenPrompt) {
      var f = SessionFacts()
      open.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .stopped, messageWaiting: false) == "an open card")
    }

    /// A resolved `resume` wait does not hold on the turn's own summary card.
    /// A schedule does not hold on it either. Auto-continue does.
    @Test func aSessionSummaryAloneDoesNotHold() {
      var f = idleFacts()
      AutoContinueGuardTests.OpenPrompt.sessionCard.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .running, messageWaiting: false) == nil)
    }

    @Test func aSessionSummaryOnAStoppedClaudeDoesNotHold() {
      var f = SessionFacts()
      AutoContinueGuardTests.OpenPrompt.sessionCard.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .stopped, messageWaiting: false) == nil)
    }

    /// A queued message, a start queued behind the live cap, or a paste or
    /// resume whose `UserPromptSubmit` has not come.
    @Test func aWaitingMessageHolds() {
      #expect(
        Schedule.blocker(facts: idleFacts(), process: .running, messageWaiting: true) == "a message is on its way")
    }

    @Test func aWaitingMessageHoldsAStoppedClaude() {
      #expect(
        Schedule.blocker(facts: SessionFacts(), process: .stopped, messageWaiting: true) == "a message is on its way")
    }

    @Test func claudeStartingHolds() {
      #expect(
        Schedule.blocker(facts: SessionFacts(), process: .starting, messageWaiting: false)
          == "claude is starting or stopping")
    }

    @Test func claudeStartingWithALiveSessionHolds() {
      #expect(
        Schedule.blocker(facts: idleFacts(), process: .starting, messageWaiting: false)
          == "claude is starting or stopping")
    }

    @Test func claudeRunningButNotLiveHolds() {
      #expect(
        Schedule.blocker(facts: SessionFacts(), process: .running, messageWaiting: false)
          == "claude is starting or stopping")
    }

    @Test func anUnknownProcessComesBeforeAnOpenCardARunningTurnAndAWaitingMessage() {
      var f = idleFacts()
      f.turnRunning = true
      AutoContinueGuardTests.OpenPrompt.card.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: nil, messageWaiting: true) == "its host is not connected")
    }

    @Test(arguments: PromptGuardCase.all)
    func anUnknownProcessHoldsWhateverTheFacts(_ c: PromptGuardCase) {
      #expect(
        Schedule.blocker(facts: c.facts, process: nil, messageWaiting: c.messageWaiting)
          == "its host is not connected")
    }

    @Test func anOpenCardComesBeforeARunningTurnAndAWaitingMessage() {
      var f = idleFacts()
      f.turnRunning = true
      AutoContinueGuardTests.OpenPrompt.card.open(in: &f, since: now - minute)

      #expect(Schedule.blocker(facts: f, process: .starting, messageWaiting: true) == "an open card")
    }

    /// `AutoContinue.blocker` and `Schedule.blocker` share `PromptGuard`. For
    /// a known process, a schedule holds exactly when the shared checks hold,
    /// with no fallback for the summary card.
    @Test(arguments: PromptGuardCase.all)
    func aKnownProcessHoldsWhenThePromptGuardHolds(_ c: PromptGuardCase) {
      let f = c.facts

      let guarded = PromptGuard.openCard(f) ?? PromptGuard.turn(f, process: c.process, messageWaiting: c.messageWaiting)

      #expect(Schedule.blocker(facts: f, process: c.process, messageWaiting: c.messageWaiting) == guarded)
    }
  }
}

extension ScheduleTests {
  /// `fireDueSchedules` skips a session exactly when `hold` returns a reason,
  /// and the Loops status shows the same reason as `held`.
  @Suite struct ScheduleHoldTests {
    @Test func aSessionWithNoHoldIsFree() {
      #expect(Schedule.hold(done: false, paused: false, removing: false) == nil)
    }

    @Test func aSessionMarkedDoneHolds() {
      #expect(Schedule.hold(done: true, paused: false, removing: false) == "the session is marked done")
    }

    @Test func aPausedSessionHolds() {
      #expect(Schedule.hold(done: false, paused: true, removing: false) == "the session is paused")
    }

    @Test func aSessionBeingRemovedHolds() {
      #expect(Schedule.hold(done: false, paused: false, removing: true) == "the session is being removed")
    }

    @Test func aSessionMarkedDoneAndPausedGivesTheDoneReason() {
      #expect(Schedule.hold(done: true, paused: true, removing: false) == "the session is marked done")
    }

    /// Every combination of the three facts, so the reason order is pinned
    /// for the pairs that the single-condition tests leave out.
    @Test(
      arguments: [
        (false, false, false, nil),
        (true, false, false, "the session is marked done"),
        (false, true, false, "the session is paused"),
        (false, false, true, "the session is being removed"),
        (true, true, false, "the session is marked done"),
        (true, false, true, "the session is marked done"),
        (false, true, true, "the session is paused"),
        (true, true, true, "the session is marked done"),
      ] as [(Bool, Bool, Bool, String?)])
    func theFirstHeldConditionNamesTheReason(_ done: Bool, _ paused: Bool, _ removing: Bool, _ reason: String?) {
      #expect(Schedule.hold(done: done, paused: paused, removing: removing) == reason)
    }
  }
}

private func run(_ t: Int64, _ outcome: Schedule.Run.Outcome = .pasted, skipped: Int = 0, error: String? = nil)
  -> Schedule.Run
{
  Schedule.Run(t: t, outcome: outcome, skipped: skipped, error: error)
}

extension ScheduleTests {
  /// `runs` keeps the last `maxRuns` runs, newest first, and `last` always equals `runs.first`.
  @Suite struct Runs {
    @Test func aScheduleKeepsAtMostTenRuns() {
      #expect(Schedule.maxRuns == 10)
    }

    @Test func recordingOnAFreshScheduleSetsLastAndRuns() {
      var s = due(at: now)
      let r = run(now)

      s.record(r)

      #expect(s.last == r)
      #expect(s.runs == [r])
    }

    @Test func runsListTheNewestFirst() {
      var s = due(at: now)

      for i in 0..<3 { s.record(run(now + Int64(i) * minute)) }

      #expect(s.runs?.map(\.t) == [now + 2 * minute, now + minute, now])
    }

    @Test func theEleventhRunDropsTheOldest() {
      var s = due(at: now)

      for i in 0..<11 { s.record(run(now + Int64(i) * minute)) }

      #expect(s.runs?.count == Schedule.maxRuns)
      #expect(s.runs?.map(\.t) == (1..<11).reversed().map { now + Int64($0) * minute })
    }

    @Test func manyRunsNeverGrowPastTheCap() {
      var s = due(at: now)

      for i in 0..<25 { s.record(run(now + Int64(i) * minute)) }

      #expect(s.runs?.count == Schedule.maxRuns)
      #expect(s.runs?.first?.t == now + 24 * minute)
    }

    @Test func theFirstRunIsTheLastAfterEachRecord() {
      var s = due(at: now)

      for i in 0..<12 {
        s.record(run(now + Int64(i) * minute, i % 3 == 0 ? .failed : .pasted, error: i % 3 == 0 ? "gone" : nil))
        #expect(s.runs?.first == s.last, "after run \(i)")
      }
    }

    /// A failed run stays in the history after a later run clears the failure from `last`.
    @Test func aFailedRunFollowedByAPastedOneKeepsBoth() {
      var s = due(at: now)
      let failed = run(now, .failed, error: "the folder /tmp/a is gone")
      let pasted = run(now + minute, .pasted, skipped: 2)

      s.record(failed)
      s.record(pasted)

      #expect(s.last == pasted)
      #expect(s.runs == [pasted, failed])
    }

    @Test func recordKeepsTheOtherFields() {
      let before = due(at: now)
      var s = before

      s.record(run(now))

      var expected = before
      expected.last = s.last
      expected.runs = s.runs
      #expect(s == expected)
    }

    @Test func aNewScheduleHasNoRunsAndNoHistory() throws {
      let s = try make()

      #expect(s.runs == nil)
      #expect(s.history.isEmpty)
    }

    @Test func historyIsTheRunsWhenThereAreRuns() {
      var s = due(at: now)
      for i in 0..<4 { s.record(run(now + Int64(i) * minute)) }

      #expect(s.history == s.runs)
    }

    /// A row that an sbd from before the history stored has `last` and no `runs`.
    @Test func aStoredRowWithoutRunsDecodesWithNoRunsAndItsLastAsTheHistory() throws {
      let text = """
        {"id": "rk3x9p", "prompt": "check the queue", "every": 1800000, "next": 1800000000000, "by": "you",
         "created": 1799998200000, "last": {"t": 1799999000000, "outcome": "failed", "skipped": 1, "error": "gone"}}
        """

      let s = try JSONCoding.decode(Schedule.self, from: text)

      #expect(s.runs == nil)
      #expect(s.history == [run(1_799_999_000_000, .failed, skipped: 1, error: "gone")])
    }

    /// A row stored before the history has `last` and no `runs`. The first new run keeps that `last` behind it.
    @Test func recordingOnARowWithOnlyLastKeepsTheOldLastInTheHistory() {
      var s = due(at: now)
      let old = run(now - hour, .failed, skipped: 1, error: "gone")
      s.last = old
      let new = run(now)

      s.record(new)

      #expect(s.last == new)
      #expect(s.runs == [new, old])
    }

    @Test func aStoredRowWithNeitherLastNorRunsHasNoHistory() throws {
      let text = """
        {"id": "rk3x9p", "prompt": "check the queue", "every": 1800000, "next": 1800000000000, "by": "you",
         "created": 1799998200000}
        """

      let s = try JSONCoding.decode(Schedule.self, from: text)

      #expect(s.runs == nil)
      #expect(s.last == nil)
      #expect(s.history.isEmpty)
    }

    @Test func aScheduleWithRunsRoundTrips() throws {
      var s = due(at: now)
      s.record(run(now - minute, .failed, skipped: 3, error: "no folder"))
      s.record(run(now, .queued))

      let decoded = try JSONCoding.decode(Schedule.self, from: try JSONCoding.encode(s))

      #expect(decoded == s)
      #expect(decoded.runs?.count == 2)
    }

    /// `history` is computed. Only `runs` and `last` are stored.
    @Test func aScheduleWithRunsEncodesRunsAndNoHistory() throws {
      var s = due(at: now)
      s.record(run(now))

      let object = try #require(JSON.parse(try JSONCoding.encode(s))?.object)

      #expect(object["runs"]?.array?.count == 1)
      #expect(object["history"] == nil)
    }

    @Test func aSessionWithRunsRoundTrips() throws {
      var s = try sessionWithSchedules()
      s.schedules?[0].record(run(now, .resumed))
      s.schedules?[0].record(run(now + minute, .pasted))

      #expect(try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s)) == s)
    }
  }
}

/// A schedule due at `now + ahead` (negative for one in the past), with an optional last run.
private func status(
  ahead: Int64, every: Int64 = 30 * minute, paused: Bool? = nil, last: Schedule.Run? = nil, hold: String? = nil,
  at time: Int64 = now
) -> ScheduleStatus {
  var s = due(at: time + ahead, every: every, paused: paused)
  s.last = last
  return ScheduleStatus(s, hold: hold, now: time)
}

private let holds = ["the session is marked done", "the session is paused", "the session is being removed"]

extension ScheduleTests {
  /// Decision 3's rules, first match wins: paused, failed, active, held, overdue, due.
  @Suite struct ScheduleStatusTests {
    // MARK: Paused

    @Test func aPausedScheduleIsPaused() {
      let s = status(ahead: 10 * minute, paused: true)

      #expect(s.state == .paused)
      #expect(s.text == "paused")
    }

    /// The user stopped the loop, so a failure does not ask for attention.
    @Test func aPausedScheduleWhoseLastRunFailedIsPaused() {
      let s = status(ahead: -hour, paused: true, last: run(now - 2 * hour, .failed, error: "gone"))

      #expect(s.state == .paused)
    }

    @Test(arguments: holds)
    func aPausedScheduleOnAHeldSessionIsPaused(_ hold: String) {
      #expect(status(ahead: -hour, paused: true, hold: hold).state == .paused)
    }

    /// Only `paused == true` pauses a schedule.
    @Test func aScheduleWithPausedFalseIsNotPaused() {
      #expect(status(ahead: 10 * minute, paused: false).state == .active)
    }

    // MARK: Failed

    @Test func aFailedLastRunWithTheNextRunAheadIsFailed() {
      let s = status(ahead: 25 * minute, last: run(now - 5 * minute, .failed, error: "the folder /tmp/a is gone"))

      #expect(s.state == .failed)
    }

    @Test func theFailedTextNamesWhenAndTheErrorAndTheNextRun() {
      let s = status(ahead: 25 * minute, last: run(now - 5 * minute, .failed, error: "the folder /tmp/a is gone"))

      #expect(s.text.contains("failed 5m ago: the folder /tmp/a is gone"), "\(s.text)")
      #expect(s.text.contains("next in 25m"), "\(s.text)")
    }

    @Test func aFailedLastRunThatIsDueAgainIsFailed() {
      let s = status(ahead: -3 * minute, last: run(now - 33 * minute, .failed, error: "gone"))

      #expect(s.state == .failed)
      #expect(s.text.contains("failed 33m ago: gone"), "\(s.text)")
    }

    /// A failed run stays failed past the grace, so it never reads as overdue.
    @Test func aFailedLastRunPastTheGraceIsFailed() {
      #expect(status(ahead: -2 * hour, last: run(now - 3 * hour, .failed, error: "gone")).state == .failed)
    }

    @Test(arguments: holds)
    func aFailedLastRunOnAHeldSessionIsFailed(_ hold: String) {
      #expect(status(ahead: -3 * minute, last: run(now - hour, .failed, error: "gone"), hold: hold).state == .failed)
    }

    /// The next run that does not fail clears the failure.
    @Test(arguments: [Schedule.Run.Outcome.pasted, .resumed, .queued])
    func aLastRunThatDidNotFailIsNotFailed(_ outcome: Schedule.Run.Outcome) {
      #expect(status(ahead: 25 * minute, last: run(now - 5 * minute, outcome)).state == .active)
    }

    // MARK: Active

    @Test func aScheduleWithTheNextRunAheadIsActive() {
      let s = status(ahead: 12 * minute)

      #expect(s.state == .active)
      #expect(s.text == "next in 12m")
    }

    @Test func aScheduleOneMsBeforeItsNextRunIsActive() {
      #expect(status(ahead: 1).state == .active)
    }

    /// Rule 3 comes before rule 4: a held session's schedule that is not due yet is active.
    @Test(arguments: holds)
    func aScheduleNotDueOnAHeldSessionIsActive(_ hold: String) {
      #expect(status(ahead: 12 * minute, hold: hold).state == .active)
    }

    // MARK: Held

    @Test(arguments: holds)
    func aDueScheduleOnAHeldSessionIsHeld(_ hold: String) {
      let s = status(ahead: -3 * minute, hold: hold)

      #expect(s.state == .held)
      #expect(s.text == "held: \(hold)")
    }

    /// A held loop does not turn overdue, because the user marked the session done or paused it.
    @Test(arguments: holds)
    func aScheduleHeldPastTheGraceIsHeld(_ hold: String) {
      #expect(status(ahead: -2 * hour, hold: hold).state == .held)
    }

    // MARK: Due and overdue

    /// `isDue` counts a schedule whose next run is now as due, and so does the status.
    @Test func aScheduleWhoseNextRunIsNowIsDue() {
      #expect(status(ahead: 0).state == .due)
    }

    @Test func aScheduleDueInsideTheGraceIsDue() {
      let s = status(ahead: -3 * minute)

      #expect(s.state == .due)
      #expect(s.text == "due 3m ago, runs when the session is free")
    }

    @Test func aScheduleDueExactlyTheGraceAgoIsOverdue() {
      #expect(status(ahead: -30 * minute).state == .overdue)
    }

    @Test func aScheduleDueOneMsShortOfTheGraceIsDue() {
      #expect(status(ahead: -30 * minute + 1).state == .due)
    }

    @Test(arguments: [minute, 10 * minute, 30 * minute, hour, day, week])
    func theOverdueEdgeIsTheGraceOfTheInterval(_ every: Int64) {
      let grace = Schedule.overdueGrace(every)

      #expect(status(ahead: -grace, every: every).state == .overdue)
      #expect(status(ahead: -grace + 1, every: every).state == .due)
    }

    /// The text counts from the due time.
    @Test func theOverdueTextSaysHowLongPastTheDueTime() {
      let s = status(ahead: -42 * minute)

      #expect(s.state == .overdue)
      #expect(s.text == "overdue by 42m, runs when the session is free")
    }

    /// A 1m loop held through an ordinary turn stays calm for 10 minutes.
    @Test func aOneMinuteLoopDueNineMinutesAgoIsDue() {
      #expect(status(ahead: -9 * minute, every: minute).state == .due)
    }

    /// A daily loop stuck for an hour asks for attention.
    @Test func aDailyLoopDueAnHourAgoIsOverdue() {
      #expect(status(ahead: -hour, every: day).state == .overdue)
    }

    // MARK: The grace

    @Test(arguments: [
      (minute, 10 * minute),
      (5 * minute, 10 * minute),
      (10 * minute, 10 * minute),
      (30 * minute, 30 * minute),
      (hour, hour),
      (2 * hour, hour),
      (day, hour),
      (week, hour),
    ])
    func theGraceIsTheIntervalBetweenTenMinutesAndAnHour(_ every: Int64, _ grace: Int64) {
      #expect(Schedule.overdueGrace(every) == grace)
    }

    // MARK: Attention

    @Test func onlyFailedAndOverdueNeedAttention() {
      let cases: [(ScheduleStatus, Bool)] = [
        (status(ahead: 10 * minute, paused: true), false),
        (status(ahead: 25 * minute, last: run(now - 5 * minute, .failed, error: "gone")), true),
        (status(ahead: 12 * minute), false),
        (status(ahead: -3 * minute, hold: holds[0]), false),
        (status(ahead: -42 * minute), true),
        (status(ahead: -3 * minute), false),
      ]

      #expect(cases.map(\.0.state) == [.paused, .failed, .active, .held, .overdue, .due])
      for (s, attention) in cases {
        #expect(s.needsAttention == attention, "\(s.state)")
      }
    }

    // MARK: Coding

    /// Agents read these raw values in `sb schedule ls --json`.
    @Test func eachStateEncodesItsName() throws {
      let cases: [(ScheduleStatus, String)] = [
        (status(ahead: 12 * minute), "active"),
        (status(ahead: -3 * minute), "due"),
        (status(ahead: -42 * minute), "overdue"),
        (status(ahead: 25 * minute, last: run(now - 5 * minute, .failed, error: "gone")), "failed"),
        (status(ahead: -3 * minute, hold: holds[0]), "held"),
        (status(ahead: 10 * minute, paused: true), "paused"),
      ]

      for (s, name) in cases {
        let object = try #require(JSON.parse(try JSONCoding.encode(s))?.object)
        #expect(object["state"]?.string == name)
      }
    }

    /// `needsAttention` is computed, so it is not on the wire.
    @Test func aStatusEncodesOnlyItsStateAndText() throws {
      let s = status(ahead: -42 * minute)

      let object = try #require(JSON.parse(try JSONCoding.encode(s))?.object)

      #expect(Set(object.keys) == ["state", "text"])
      #expect(object["text"]?.string == s.text)
    }

    @Test func aStatusRoundTrips() throws {
      let s = status(ahead: -3 * minute, hold: holds[1])

      #expect(try JSONCoding.decode(ScheduleStatus.self, from: try JSONCoding.encode(s)) == s)
    }

    /// A newer sb reads the rows that an sbd from before the status sends.
    @Test func aRowWithoutAStatusDecodesWithNone() throws {
      var row = ScheduleRow(session: "s1", name: "manager", schedule: try make())
      row.status = status(ahead: 12 * minute)

      let decoded = try JSONCoding.decode(ScheduleRow.self, from: try encoded(row, without: "status"))

      #expect(decoded.status == nil)
      #expect(decoded.schedule == row.schedule)
    }

    @Test func aRowWithAStatusRoundTrips() throws {
      var row = ScheduleRow(session: "s1", name: "manager", schedule: try make())
      row.status = status(ahead: -42 * minute)

      let decoded = try JSONCoding.decode(ScheduleRow.self, from: try JSONCoding.encode(row))

      #expect(decoded.status == row.status)
    }
  }
}

/// A row on the session whose status is the one that the rules give at `now`.
private func row(
  _ id: String, session: String, ahead: Int64, paused: Bool? = nil, failed: Bool = false, hold: String? = nil
) -> ScheduleRow {
  var s = due(at: now + ahead, paused: paused)
  s.id = id
  if failed { s.last = run(now - hour, .failed, error: "gone") }
  var r = ScheduleRow(session: session, name: session, schedule: s)
  r.status = ScheduleStatus(s, hold: hold, now: now)
  return r
}

extension ScheduleTests {
  /// The Loops tab's order: failed, overdue, due, active, held, paused, then by `next`, then id.
  @Suite struct AttentionOrder {
    /// Two rows of each state on two sessions. `ra1` and `rb1` tie on `next`, and so do `rc3` and `rd3`.
    static let sorted: [ScheduleRow] = [
      row("ra1", session: "s2", ahead: -2 * hour, failed: true),
      row("rb1", session: "s1", ahead: -2 * hour, failed: true),
      row("ra2", session: "s1", ahead: 20 * minute, failed: true),
      row("rc3", session: "s2", ahead: -50 * minute),
      row("rd3", session: "s1", ahead: -50 * minute),
      row("ra4", session: "s1", ahead: -40 * minute),
      row("ra5", session: "s2", ahead: -5 * minute),
      row("ra6", session: "s1", ahead: -minute),
      row("ra7", session: "s1", ahead: 2 * minute),
      row("rb7", session: "s2", ahead: 2 * minute),
      row("ra8", session: "s2", ahead: 20 * minute),
      row("ra9", session: "s2", ahead: -2 * hour, hold: holds[0]),
      row("rb9", session: "s1", ahead: -minute, hold: holds[1]),
      row("raa", session: "s1", ahead: -3 * hour, paused: true),
      row("rab", session: "s2", ahead: 5 * minute, paused: true, failed: true),
    ]

    @Test func theFixtureHasEveryStateInOrder() {
      let states = AttentionOrder.sorted.compactMap(\.status?.state)

      #expect(states.count == AttentionOrder.sorted.count)
      #expect(
        states == [
          .failed, .failed, .failed, .overdue, .overdue, .overdue, .due, .due, .active, .active, .active, .held, .held,
          .paused, .paused,
        ])
    }

    @Test func reversedRowsSortIntoTheAttentionOrder() {
      let ids = AttentionOrder.sorted.reversed().sorted(by: ScheduleRow.attentionOrder).map(\.schedule.id)

      #expect(ids == AttentionOrder.sorted.map(\.schedule.id))
    }

    @Test(arguments: 0..<5)
    func shuffledRowsSortIntoTheAttentionOrder(_ seed: Int) {
      var rng = SeededGenerator(seed: UInt64(seed + 1))
      let shuffled = AttentionOrder.sorted.shuffled(using: &rng)

      let ids = shuffled.sorted(by: ScheduleRow.attentionOrder).map(\.schedule.id)

      #expect(ids == AttentionOrder.sorted.map(\.schedule.id))
    }

    /// A strict order: no row comes before itself.
    @Test func noRowComesBeforeItself() {
      for r in AttentionOrder.sorted {
        #expect(!ScheduleRow.attentionOrder(r, r), "\(r.schedule.id)")
      }
    }

    /// A failed loop due later still comes before an overdue one due long ago.
    @Test func attentionComesBeforeTheNextRun() {
      let failed = row("rz", session: "s1", ahead: 20 * minute, failed: true)
      let overdue = row("ra", session: "s1", ahead: -2 * hour)

      #expect(ScheduleRow.attentionOrder(failed, overdue))
      #expect(!ScheduleRow.attentionOrder(overdue, failed))
    }
  }
}

/// A fixed sequence of random numbers, so a shuffled test case is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

extension ScheduleTests {
  @Suite struct CleanPrompt {
    @Test func trimsSpacesAndNewlinesAtTheEnds() throws {
      #expect(try Schedule.cleanPrompt("  \n check the queue \t\n") == "check the queue")
    }

    @Test func keepsTheLinesInside() throws {
      #expect(try Schedule.cleanPrompt(" first line\nsecond line ") == "first line\nsecond line")
    }

    @Test func keepsASlashCommandVerbatim() throws {
      #expect(try Schedule.cleanPrompt("/audit-waiting --all") == "/audit-waiting --all")
    }

    @Test(arguments: [nil, "", "   ", " \n\t "] as [String?])
    func refusesAnEmptyPrompt(_ prompt: String?) {
      #expect(message { try Schedule.cleanPrompt(prompt) }.contains("a schedule needs a prompt"))
    }

    /// `makeSchedule` refuses with the same words, through `cleanPrompt`.
    @Test(arguments: [nil, "", "   "] as [String?])
    func makeScheduleRefusesWithTheSameWords(_ prompt: String?) {
      #expect(message { try make(prompt: prompt) }.contains(message { try Schedule.cleanPrompt(prompt) }))
    }
  }
}

/// An active schedule made at `now - 10m` with a 1h interval, whose next run is 50 minutes away.
private func hourly(next: Int64 = now + 50 * minute, paused: Bool? = nil) -> Schedule {
  var s = Schedule(
    id: "rk3x9p", prompt: "check the queue", every: hour, next: next, paused: paused, by: .claude,
    created: now - 10 * minute)
  s.record(run(now - 10 * minute, .failed, skipped: 1, error: "gone"))
  return s
}

extension ScheduleTests {
  /// `edited` changes only `every`, `prompt`, and `next`. A new interval sets `next = min(next, now + every)`.
  @Suite struct ScheduleEditTests {
    @Test func shorteningTheIntervalBringsTheNextRunCloser() throws {
      let before = hourly()

      let after = try before.edited(every: "10m", prompt: nil, now: now)

      var expected = before
      expected.every = 10 * minute
      expected.next = now + 10 * minute
      #expect(after == expected)
    }

    @Test func lengtheningTheIntervalKeepsASoonerNextRun() throws {
      var before = hourly(next: now + 5 * minute)
      before.every = 10 * minute

      let after = try before.edited(every: "1d", prompt: nil, now: now)

      var expected = before
      expected.every = day
      #expect(after == expected)
    }

    @Test(arguments: ["1m", "10m", "1h", "1d"])
    func aDueScheduleStaysDueAfterAnIntervalChange(_ every: String) throws {
      let before = hourly(next: now - 5 * minute)

      let after = try before.edited(every: every, prompt: nil, now: now)

      #expect(after.next == before.next)
      #expect(after.isDue(now: now))
    }

    @Test func aPromptOnlyEditKeepsTheIntervalAndTheNextRun() throws {
      let before = hourly()

      let after = try before.edited(every: nil, prompt: "look at the flags", now: now)

      var expected = before
      expected.prompt = "look at the flags"
      #expect(after == expected)
    }

    @Test func anEditOfBothChangesBoth() throws {
      let before = hourly()

      let after = try before.edited(every: "10m", prompt: "look at the flags", now: now)

      var expected = before
      expected.every = 10 * minute
      expected.prompt = "look at the flags"
      expected.next = now + 10 * minute
      #expect(after == expected)
    }

    /// Resume sets the next run of a paused schedule, so an edit leaves it.
    @Test func aPausedScheduleKeepsItsNextRun() throws {
      let before = hourly(paused: true)

      let after = try before.edited(every: "10m", prompt: nil, now: now)

      var expected = before
      expected.every = 10 * minute
      #expect(after == expected)
      #expect(after.paused == true)
    }

    @Test func anEditToTheSameValuesChangesNothing() throws {
      let before = hourly()

      let after = try before.edited(every: "1h", prompt: "check the queue", now: now)

      #expect(after == before)
    }

    @Test func theNewPromptIsTrimmed() throws {
      let after = try hourly().edited(every: nil, prompt: "  \n look at the flags \t", now: now)

      #expect(after.prompt == "look at the flags")
    }

    @Test func theAuthorDoesNotChange() throws {
      #expect(try hourly().edited(every: "10m", prompt: "new words", now: now).by == .claude)
    }

    @Test(arguments: ["29s", "1h30m", "soon", "59s", "99999999999999w"])
    func refusesAnIntervalThatParseIntervalRefuses(_ every: String) {
      let parse = message { try Schedule.parseInterval(every) }

      let error = message { try hourly().edited(every: every, prompt: nil, now: now) }

      #expect(parse != "no error")
      #expect(error.contains(parse), "\(error)")
    }

    @Test(arguments: ["", "   ", " \n\t "])
    func refusesAnEmptyPrompt(_ prompt: String) {
      let error = message { try hourly().edited(every: nil, prompt: prompt, now: now) }

      #expect(error.contains("a schedule needs a prompt"), "\(error)")
    }

    /// A good interval does not save an empty prompt, and a good prompt does not save a bad interval.
    @Test func refusesWhenEitherFieldIsBad() {
      #expect(throws: (any Error).self) { try hourly().edited(every: "10m", prompt: " ", now: now) }
      #expect(throws: (any Error).self) { try hourly().edited(every: "soon", prompt: "fine", now: now) }
    }

    /// `makeSchedule` refuses this interval, so an edit does too, even on a paused schedule whose next run stays.
    @Test(arguments: [nil, true] as [Bool?])
    func refusesAnIntervalWhoseNextRunIsPastTheEndOfTheClock(_ paused: Bool?) {
      let every = "9223372036854775s"

      let error = message { try hourly(paused: paused).edited(every: every, prompt: nil, now: now) }

      #expect(error.contains("past the end of the clock"), "\(error)")
      #expect(message { try make(every: every) }.contains("past the end of the clock"))
    }

    @Test func refusesAnEditOfNeitherField() {
      #expect(throws: (any Error).self) { try hourly().edited(every: nil, prompt: nil, now: now) }
    }
  }
}
