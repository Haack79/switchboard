import Foundation
import SwitchboardCore
import Testing

/// The idle stop runs earlier in the tick than the schedules, after 600 s of quiet. Each test that expects a live
/// session moves the clock less than that past the last turn, so the schedules run every 1m.
@Suite(.blocking(timeLimit: .seconds(120))) struct ScheduleFireTests {
  static let every: Int64 = 60_000
  /// Past one interval, and well short of the idle stop.
  static let pastDue: Int64 = 61_000

  /// Adds a schedule through `sb schedule <session> --every 1m <prompt> --json`.
  func schedule(_ sbd: Instance, _ session: String, _ prompt: String) throws -> Schedule {
    try JSONCoding.decode(
      ScheduleRow.self, from: sbd.sb("schedule", session, "--every", "1m", prompt, "--json")
    ).schedule
  }

  /// The schedule as `sb get` shows it now.
  func current(_ sbd: Instance, _ session: String, _ id: String) throws -> Schedule? {
    try sbd.get(session).schedules?.first { $0.id == id }
  }

  /// The `sent` events that carry the prompt.
  func runs(_ sbd: Instance, _ session: String, _ prompt: String) throws -> [Event] {
    try sbd.events(session, "sent", text: prompt)
  }

  func scheduleRan(_ sbd: Instance, _ session: String) throws -> [Event] {
    try sbd.events(session).filter { $0.kind == "schedule-ran" }
  }

  /// The `UserPromptSubmit` events of the prompt.
  func prompts(_ sbd: Instance, _ session: String, _ prompt: String) throws -> [Event] {
    try sbd.events(session).filter { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == prompt }
  }

  /// Waits until the stub reports the prompt, which starts its turn.
  @discardableResult
  func waitForPrompt(_ sbd: Instance, _ session: String, _ prompt: String) throws -> Event {
    try sbd.waitFor(
      "the turn of \(prompt)", fetch: { try prompts(sbd, session, prompt).first }, until: { _ in true })
  }

  /// Waits until the schedule records a run, and returns that run.
  @discardableResult
  func waitForRun(_ sbd: Instance, _ session: String, _ id: String, timeout: Double = 15) throws -> Schedule.Run {
    try sbd.waitFor(
      "a run of \(id)", timeout: timeout, fetch: { try current(sbd, session, id)?.last }, until: { _ in true })
  }

  /// Whether a turn ended after `first` and before `second`.
  func turnEnded(_ sbd: Instance, _ session: String, after first: Event, before second: Event) throws -> Bool {
    try sbd.events(session).contains { $0.kind == "Stop" && $0.id > first.id && $0.id < second.id }
  }

  // MARK: Delivery

  @Test func aDueScheduleIsPastedIntoAnIdleSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick one")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick one" }
    let after = try #require(try current(sbd, s.id, made.id))
    let last = try #require(after.last)
    #expect(last.outcome == .pasted)
    #expect(last.skipped == 0)
    #expect(last.error == nil)
    #expect(after.next == last.t + ScheduleFireTests.every)
    let ran = try scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "pasted")
    #expect(ran[0].data["skipped"]?.int == 0)
  }

  /// The prompt goes as typed, with no "Switchboard:" in front, so a slash command runs as one.
  @Test func theRunSendsThePromptVerbatimAsSbd() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    _ = try schedule(sbd, s.id, "tick verbatim")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick verbatim" }
    #expect(try sbd.messagesFromSbd(s.id) == ["tick verbatim"])
  }

  @Test func aDueScheduleResumesAStoppedSession() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    // The idle stop moves the clock 601 s, which would pass a schedule made before it.
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick two")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the resumed run", timeout: 30) { $0.lastReply == "Done: tick two" }
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(s.claudeSessionId) ") == true, "\(sbd.stubArgs())")
    #expect(try current(sbd, s.id, made.id)?.last?.outcome == .resumed)
    #expect(try sbd.triggers(s.id).compactMap { $0 }.last == "schedule")
  }

  /// A run can start claude, which needs the shared MCP servers. `mcpStarting` counts only a server that started
  /// in the last 10 s, so the server restarts after the long clock move and just before the run is due.
  @Test func aRunThatResumesASessionWaitsForAStartingServer() throws {
    let gate = try MCPGate(open: true)
    let sbd = try Instance(config: ["mcpServers": ["slow": Instance.stubServer("slow", gate: gate)]])
    let s = try sbd.idleSession()
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick after the server")
    try sbd.advanceClock(made.next - (try sbd.now()) - 1_000)
    try sbd.restartServer(try sbd.waitForRunning("slow"), behind: gate)

    try sbd.advanceClock(2_000)

    #expect(try sbd.events(s.id, kind: "resumed").isEmpty)
    #expect(try runs(sbd, s.id, "tick after the server").isEmpty)
    try gate.open()
    try sbd.waitFor(s.id, "the resumed run", timeout: 30) { $0.lastReply == "Done: tick after the server" }
    let resumed = try #require(try sbd.events(s.id, kind: "resumed").last)
    #expect(resumed.data["mcp"] == ["slow"])
    #expect(resumed.data["trigger"]?.string == "schedule")
  }

  // MARK: Queue one

  /// `slow held` runs a tool call until $SB_HOME/report exists, so `turnRunning` holds through the clock move.
  @Test func aRunningTurnHoldsTheScheduleAndItRunsOnceAfterTheTurn() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick held")
    try sbd.sb("send", s.id, "slow held")
    try waitForPrompt(sbd, s.id, "slow held")
    try sbd.waitFor(s.id, "the held turn") { $0.state == .working }

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick held").isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick held" }
    // Three due times passed during the turn, and one of them runs.
    #expect(try current(sbd, s.id, made.id)?.last?.skipped == 2)
    sleep(3)
    #expect(try runs(sbd, s.id, "tick held").count == 1)
    #expect(try scheduleRan(sbd, s.id).count == 1)
  }

  /// sbd visits sessions in id order, so the busy session has the lower id and comes first.
  @Test func aBusySessionDoesNotHoldBackAnotherSessionsSchedule() throws {
    let sbd = try Instance()
    let pair = [try sbd.idleSession(name: "a"), try sbd.idleSession(name: "b")].sorted { $0.id < $1.id }
    let (busy, free) = (pair[0], pair[1])
    let held = try schedule(sbd, busy.id, "tick busy")
    let other = try schedule(sbd, free.id, "tick free")
    try sbd.sb("send", busy.id, "slow held")
    try waitForPrompt(sbd, busy.id, "slow held")
    try sbd.waitFor(busy.id, "the held turn") { $0.state == .working }

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    #expect(try waitForRun(sbd, free.id, other.id).outcome == .pasted)
    #expect(try current(sbd, busy.id, held.id)?.last == nil)
  }

  /// `resolveDueWaits` runs before the schedules in the tick. The wait's message is in flight when the schedule
  /// comes due, so the schedule runs after that message's turn.
  @Test func aWaitDueOnTheSameTickGoesFirst() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1m")
    _ = try schedule(sbd, s.id, "tick after the wait")

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick after the wait" }
    let sent = try sbd.sbdMessages(s.id)
    try #require(sent.count == 2, "\(sent)")
    #expect(sent[0].data["text"]?.string?.hasPrefix("Switchboard:") == true, "\(sent[0])")
    #expect(sent[1].data["text"]?.string == "tick after the wait")
    #expect(try turnEnded(sbd, s.id, after: sent[0], before: sent[1]))
  }

  /// The first schedule's prompt holds its turn, so the second can't run during it.
  @Test func twoSchedulesDueTogetherSendOneMessageAtATime() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let first = try schedule(sbd, s.id, "slow held")
    let second = try schedule(sbd, s.id, "tick second")
    try #require(first.next <= second.next)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForPrompt(sbd, s.id, "slow held")
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id) == ["slow held"])
    #expect(try current(sbd, s.id, second.id)?.last == nil)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the second run's reply", timeout: 30) { $0.lastReply == "Done: tick second" }
    let sent = try sbd.sbdMessages(s.id)
    try #require(sent.count == 2, "\(sent)")
    #expect(sent.compactMap { $0.data["text"]?.string } == ["slow held", "tick second"])
    #expect(try turnEnded(sbd, s.id, after: sent[0], before: sent[1]))
    #expect(try current(sbd, s.id, first.id)?.last?.outcome == .pasted)
    #expect(try current(sbd, s.id, second.id)?.last?.outcome == .pasted)
  }

  /// The user's message waits in `pending` behind a running turn. When the turn ends, the user's message goes
  /// first, and the schedule runs after the user's turn.
  @Test func aUserMessageQueuedBehindATurnGoesBeforeTheRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick behind")
    try sbd.sb("send", s.id, "slow held")
    try waitForPrompt(sbd, s.id, "slow held")
    try sbd.sb("send", s.id, "my own words")
    let mine = try #require(try sbd.events(s.id, "sent", text: "my own words").first)
    try #require(mine.data["delivery"]?.string == "queued", "\(mine)")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick behind").isEmpty)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick behind" }
    let run = try #require(try runs(sbd, s.id, "tick behind").first)
    let typed = try #require(try prompts(sbd, s.id, "my own words").first)
    #expect(typed.id < run.id)
    #expect(try turnEnded(sbd, s.id, after: typed, before: run))
    #expect(try runs(sbd, s.id, "tick behind").count == 1)
    #expect(try current(sbd, s.id, made.id)?.last?.outcome == .pasted)
  }

  /// `lag held` keeps the user's message in flight: the stub reads it and does not report it until
  /// $SB_HOME/report exists. The clock stops 2 s short of the due time before the message goes, so the schedule
  /// comes due inside the message's 10 s in-flight window.
  @Test func aUserMessageInFlightGoesBeforeTheRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick in flight")
    let now = try sbd.now()
    try sbd.advanceClock(made.next - now - 2_000)
    try sbd.sb("send", s.id, "lag held")
    let mine = try #require(try sbd.events(s.id, "sent", text: "lag held").first)
    try #require(mine.data["delivery"]?.string == "pasted", "\(mine)")

    try sbd.advanceClock(2_500)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick in flight").isEmpty)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run", timeout: 30) { $0.lastReply == "Done: tick in flight" }
    let run = try #require(try runs(sbd, s.id, "tick in flight").first)
    let typed = try #require(try prompts(sbd, s.id, "lag held").first)
    #expect(try turnEnded(sbd, s.id, after: typed, before: run))
    #expect(try runs(sbd, s.id, "tick in flight").count == 1)
  }

  /// While $SB_HOME/hold exists, the stub reads the run's paste and never reports it. The paste stops counting as
  /// in flight after 10 s. The next run is still a whole interval after the first.
  @Test func aRunWhosePromptIsNeverReportedDoesNotRunAgainBeforeItsNextTime() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick unreported")
    sbd.hold("hold")

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor("the run's paste") { try runs(sbd, s.id, "tick unreported").count == 1 }
    for _ in 0..<3 { try sbd.advanceClock(11_000) }
    sleep(1)

    #expect(try prompts(sbd, s.id, "tick unreported").isEmpty)
    #expect(try runs(sbd, s.id, "tick unreported").count == 1)
    #expect(try scheduleRan(sbd, s.id).count == 1)
    let after = try #require(try current(sbd, s.id, made.id))
    let last = try #require(after.last)
    #expect(after.next == last.t + ScheduleFireTests.every)
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the run") { $0.lastReply == "Done: tick unreported" }
    #expect(try runs(sbd, s.id, "tick unreported").count == 1)
  }

  // MARK: Done and paused

  @Test func aDoneSessionsScheduleWaitsAndRunsOnceAfterUndone() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick done")
    try sbd.sb("done", s.id)

    try sbd.advanceClock(3 * ScheduleFireTests.every + 30_000)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick done").isEmpty)
    let kept = try #require(try current(sbd, s.id, made.id))
    #expect(kept.last == nil)
    try sbd.sb("undone", s.id)
    let last = try waitForRun(sbd, s.id, made.id, timeout: 30)
    #expect(last.skipped == 2)
    sleep(2)
    #expect(try runs(sbd, s.id, "tick done").count == 1)
  }

  @Test func aPausedScheduleDoesNotRun() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick paused")
    try sbd.sb("schedule", "pause", made.id)

    try sbd.advanceClock(ScheduleFireTests.pastDue)
    sleep(1)

    #expect(try runs(sbd, s.id, "tick paused").isEmpty)
    #expect(try current(sbd, s.id, made.id)?.last == nil)
    #expect(try scheduleRan(sbd, s.id).isEmpty)
    // A resume sets the next run one interval later, so the pause is what held the schedule.
    try sbd.sb("schedule", "resume", made.id)
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try waitForRun(sbd, s.id, made.id)
    #expect(try runs(sbd, s.id, "tick paused").count == 1)
  }

  // MARK: Restart and failure

  /// `Clock`'s offset lives only in sbd's memory, so the clock moves after the restart.
  @Test func aScheduleMissedWhileSbdWasDownRunsOnceAndCountsTheRestAsSkipped() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let made = try schedule(sbd, s.id, "tick catch up")
    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.advanceClock(5 * ScheduleFireTests.every + 1_000)

    let last = try waitForRun(sbd, s.id, made.id, timeout: 30)
    #expect(last.skipped == 4)
    sleep(3)
    #expect(try runs(sbd, s.id, "tick catch up").count == 1)
  }

  /// `send` throws because the session's folder is gone. The run records the failure once and waits a whole
  /// interval, unlike a wait, which stays open and tries again on each tick.
  @Test func aRunThatCantBeSentRecordsTheFailureOnceAndMovesToTheNextTime() throws {
    let sbd = try Instance()
    let folder = "\(sbd.home.path)/doomed"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let s = try sbd.client.call(
      "new", ["path": .string(folder), "name": "doomed", "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.passIdleStop(s.id)
    let made = try schedule(sbd, s.id, "tick gone")
    try FileManager.default.removeItem(atPath: folder)

    try sbd.advanceClock(ScheduleFireTests.pastDue)

    let last = try waitForRun(sbd, s.id, made.id)
    sleep(3)
    #expect(last.outcome == .failed)
    #expect(last.error?.contains(s.cwd) == true, "\(String(describing: last.error))")
    #expect(try current(sbd, s.id, made.id)?.next == last.t + ScheduleFireTests.every)
    let ran = try scheduleRan(sbd, s.id)
    try #require(ran.count == 1, "\(ran)")
    #expect(ran[0].data["outcome"]?.string == "failed")
    #expect(ran[0].data["error"]?.string?.isEmpty == false)
    #expect(try runs(sbd, s.id, "tick gone").isEmpty)
    let log = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? ""
    #expect(log.split(separator: "\n").filter { $0.contains("\(s.cwd) is gone") }.count == 1, "\(log)")
  }
}

/// A remote session's process state is unknown while sbd can't read its host.
@Suite(.blocking(timeLimit: .seconds(180))) struct ScheduleFireRemoteTests {
  private let refusal = "ssh: connect to host mini.local port 22: Operation timed out"

  @Test func aScheduleOnAHostWhoseLinkIsDownWaitsForTheLink() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let summary = try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello")
    let id = try sbd.id(of: summary)
    let claudeSessionId = try #require(summary["claudeSessionId"]?.string)
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }
    try sbd.waitFor("the first turn's transcript on the box") { !sbd.boxTranscripts(claudeSessionId).isEmpty }
    let made = try JSONCoding.decode(
      ScheduleRow.self, from: sbd.sb("schedule", id, "--every", "1m", "tick remote", "--json")
    ).schedule
    try sbd.dropLinkAndRefuse(refusal)

    try sbd.advanceClock(61_000)
    for _ in 0..<2 { try sbd.advanceClock(11_000) }

    #expect(try sbd.events(id, "sent", text: "tick remote").isEmpty)
    #expect(try sbd.get(id).schedules?.first { $0.id == made.id }?.last == nil)
    try sbd.restoreLink()
    try sbd.waitFor("the run after the link returns", timeout: 30) {
      try sbd.events(id, "sent", text: "tick remote").count == 1
    }
    sleep(2)
    #expect(try sbd.events(id, "sent", text: "tick remote").count == 1)
  }
}
