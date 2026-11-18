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
