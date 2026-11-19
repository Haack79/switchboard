import Foundation
import SwitchboardCore
import Testing

/// sbd starts a fresh Operator conversation, a new `claudeSessionId`, after `operator.maxTurns` turns or once the
/// conversation is older than `operator.resetEverySeconds`. It stops a quiet running claude first, and it rotates
/// only while nothing in flight needs the old conversation. The next message launches claude with `--session-id` on
/// the new id. Every transcript and event stays.
///
/// The tests set `operator.maxTurns` to 2 with `sbd.set`, which edits config.json without a restart, so two stub
/// turns make a reset due.
@Suite(.blocking(timeLimit: .seconds(180))) struct OperatorResetTests {
  let operatorHelpers = OperatorTests()
  let conversationHelpers = ManagerConversationsTests()
  let reportHelpers = OperatorReportTests()
  let followThrough = FollowThroughTests()

  static let resetKind = "conversation-reset"
  static let stopReason = "its conversation restarts"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// Sets config.json's `operator` section to `settings`. sbd reads the operator settings on each use.
  func setOperator(_ sbd: Instance, _ settings: [String: JSON]) throws {
    try sbd.set("operator", to: .object(settings))
  }

  func setMaxTurns(_ sbd: Instance, _ turns: Int) throws {
    try setOperator(sbd, ["maxTurns": .number(Double(turns))])
  }

  /// An operator whose turns for each text, sent with `sb operator`, have ended. Its claude still runs.
  @discardableResult
  func operatorAfter(_ sbd: Instance, turns texts: [String] = ["one", "two"]) throws -> SessionSummary {
    let op = try operatorHelpers.idleOperator(sbd, texts[0])
    for text in texts.dropFirst() { try turn(sbd, op.id, text) }
    return try sbd.get(op.id)
  }

  /// Sends `text` with `sb operator` and waits for its reply.
  func turn(_ sbd: Instance, _ id: String, _ text: String) throws {
    try sbd.sb("operator", text)
    try sbd.waitFor(id, "the operator's reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  func resets(_ sbd: Instance, _ id: String) throws -> [Event] { try sbd.events(id, kind: Self.resetKind) }

  /// Moves sbd's clock a second at a time until the operator has a `conversation-reset` after the event `mark`,
  /// and returns it.
  @discardableResult
  func waitForReset(_ sbd: Instance, _ id: String, after mark: Int64 = 0) throws -> Event {
    try sbd.waitFor(
      "a conversation-reset of \(id)", timeout: 30,
      fetch: {
        try sbd.advanceClock(1000)
        return try sbd.events(id, after: mark).last { $0.kind == Self.resetKind }
      }, until: { _ in true })
  }

  /// Runs five ticks a second apart and checks that the operator kept its conversation. sbd stops a running claude
  /// on one tick and swaps the id on a later one, so the check also refuses a stop with the reset's reason.
  func expectNoReset(
    _ sbd: Instance, _ op: SessionSummary, _ what: String, sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    for _ in 0..<5 { try sbd.advanceClock(1000) }
    usleep(300_000)
    #expect(try resets(sbd, op.id).isEmpty, "\(what)", sourceLocation: sourceLocation)
    #expect(
      try sbd.events(op.id, kind: "stopped").allSatisfy { $0.data["reason"]?.string != Self.stopReason },
      "\(what)", sourceLocation: sourceLocation)
    #expect(
      try sbd.get(op.id).claudeSessionId == op.claudeSessionId, "\(what)", sourceLocation: sourceLocation)
  }

  /// An operator that had two turns with `maxTurns` 2, after its reset. Returns the operator before the reset (with
  /// the old id), after it (with the new id), and the reset event.
  func rotatedOperator(_ sbd: Instance) throws -> (old: SessionSummary, new: SessionSummary, reset: Event) {
    try setMaxTurns(sbd, 2)
    let old = try operatorAfter(sbd)
    let reset = try waitForReset(sbd, old.id)
    return (old, try sbd.get(old.id), reset)
  }

  /// A rotated operator whose next message, `three`, launched claude on the new conversation and got its reply.
  func rotatedOperatorAfterTheNextTurn(_ sbd: Instance) throws -> (
    old: SessionSummary, new: SessionSummary, reset: Event
  ) {
    let rotated = try rotatedOperator(sbd)
    try turn(sbd, rotated.old.id, "three")
    return rotated
  }

  // MARK: The reset

  @Test func twoTurnsThenIdleRecordAResetFromTheOldIdToTheNewOne() throws {
    let sbd = try Instance()

    let (old, new, reset) = try rotatedOperator(sbd)

    #expect(reset.data["from"]?.string == old.claudeSessionId, "\(reset.data.text)")
    #expect(reset.data["to"]?.string == new.claudeSessionId, "\(reset.data.text)")
    #expect(new.claudeSessionId != old.claudeSessionId)
  }

  @Test func theResetRecordsTheOldConversationsTurns() throws {
    let sbd = try Instance()

    let (_, _, reset) = try rotatedOperator(sbd)

    #expect(reset.data["turns"]?.int == 2, "\(reset.data.text)")
  }

  @Test func theNewIdIsALowercasedUUID() throws {
    let sbd = try Instance()

    let (_, new, _) = try rotatedOperator(sbd)

    #expect(UUID(uuidString: new.claudeSessionId) != nil, "\(new.claudeSessionId)")
    #expect(new.claudeSessionId == new.claudeSessionId.lowercased())
  }

  @Test func aDueResetStopsTheQuietClaudeWithItsReason() throws {
    let sbd = try Instance()

    let (old, _, reset) = try rotatedOperator(sbd)

    let stops = try sbd.events(old.id).filter { $0.kind == "stopped" && $0.id < reset.id }
    #expect(stops.map { $0.data["reason"]?.string } == [Self.stopReason], "\(stops.map(\.data.text))")
  }

  @Test func theResetLaunchesNoClaude() throws {
    let sbd = try Instance()
    let (old, new, _) = try rotatedOperator(sbd)

    for _ in 0..<5 { try sbd.advanceClock(1000) }
    usleep(300_000)

    #expect(conversationHelpers.launches(sbd, new).isEmpty, "\(sbd.stubArgs())")
    #expect(try sbd.get(old.id).live == false)
  }

  /// A fresh conversation has no turn since its reset, so it does not reset again however long it stays idle.
  @Test func anIdleRotatedOperatorDoesNotResetAgain() throws {
    let sbd = try Instance()
    let (old, _, _) = try rotatedOperator(sbd)

    for _ in 0..<5 { try sbd.advanceClock(1000) }
    try sbd.advanceClock(2 * 86_400_000)
    usleep(300_000)

    #expect(try resets(sbd, old.id).count == 1)
  }

  @Test func aConversationOlderThanResetEverySecondsResets() throws {
    let sbd = try Instance()
    try setOperator(sbd, ["maxTurns": 0, "resetEverySeconds": 60])
    let op = try operatorAfter(sbd, turns: ["one"])
    try #require(try resets(sbd, op.id).isEmpty)

    try sbd.advanceClock(61_000)

    let reset = try waitForReset(sbd, op.id)
    #expect(reset.data["from"]?.string == op.claudeSessionId, "\(reset.data.text)")
  }

  /// `turnsSinceReset` is a fact that the events give, so a restart's replay rebuilds it.
  @Test func aTurnBeforeARestartStillCounts() throws {
    let sbd = try Instance()
    try setMaxTurns(sbd, 2)
    let op = try operatorAfter(sbd, turns: ["one"])
    sbd.stopSbd()
    try sbd.startSbd()

    try turn(sbd, op.id, "two")

    let reset = try waitForReset(sbd, op.id)
    #expect(reset.data["turns"]?.int == 2, "\(reset.data.text)")
  }

  /// sbd reads `operator.maxTurns` on each use, so a limit lowered while sbd runs applies at the next tick.
  @Test func aMaxTurnsLoweredWhileSbdRunsResetsAtTheNextTick() throws {
    let sbd = try Instance()
    let op = try operatorAfter(sbd)
    try expectNoReset(sbd, op, "with the default maxTurns of 20")

    try setMaxTurns(sbd, 2)

    try waitForReset(sbd, op.id)
  }

  @Test func theSummaryShowsWhenTheConversationStarted() throws {
    let sbd = try Instance()

    let (old, new, reset) = try rotatedOperator(sbd)

    #expect(old.conversationStarted == nil)
    #expect(new.conversationStarted == reset.t)
  }

  // MARK: The next message

  @Test func theNextMessageLaunchesWithSessionIdOfTheNewConversation() throws {
    let sbd = try Instance()
    let (old, new, _) = try rotatedOperator(sbd)

    try sbd.sb("operator", "three")

    let launched = try conversationHelpers.launch(sbd, new, after: 0)
    #expect(launched.hasPrefix("--session-id \(new.claudeSessionId) "), "\(launched)")
    try sbd.waitFor(old.id, "the reply in the new conversation", timeout: 30) { $0.lastReply == "Done: three" }
  }

  @Test func theOldTranscriptStaysAfterTheNextTurn() throws {
    let sbd = try Instance()

    let (old, _, _) = try rotatedOperatorAfterTheNextTurn(sbd)

    #expect(sbd.transcriptContains(old, "one"))
    #expect(sbd.transcriptContains(old, "two"))
  }

  @Test func theNextTurnGoesToTheNewTranscriptOnly() throws {
    let sbd = try Instance()

    let (old, new, _) = try rotatedOperatorAfterTheNextTurn(sbd)

    #expect(sbd.transcriptContains(new, "three"))
    #expect(!sbd.transcriptContains(old, "three"))
  }

  @Test func noEventIsDeletedByTheReset() throws {
    let sbd = try Instance()
    try setMaxTurns(sbd, 2)
    let op = try operatorAfter(sbd)
    let before = try sbd.events(op.id).map(\.id)

    try waitForReset(sbd, op.id)
    try turn(sbd, op.id, "three")

    let after = Set(try sbd.events(op.id).map(\.id))
    #expect(Set(before).isSubset(of: after), "\(Set(before).subtracting(after))")
  }

  /// A rotated launch reports SessionStart `source: startup`, so the fresh conversation gets the start digest.
  @Test func theRotatedLaunchGetsAStartDigest() throws {
    let sbd = try Instance()
    let work = try sbd.new(prompt: "hello", name: "work")
    try sbd.waitFor(work.id, "the work session's reply") { $0.lastReply == "Done: hello" }

    let (_, new, _) = try rotatedOperatorAfterTheNextTurn(sbd)

    let text = try conversationHelpers.startDigest(sbd, new)
    #expect(text.contains(work.id), "\(text)")
    #expect(conversationHelpers.startContexts(sbd, new).count == 1)
  }

  @Test func operatorLogAfterTheNextTurnShowsOnlyTheNewConversation() throws {
    let sbd = try Instance()
    _ = try rotatedOperatorAfterTheNextTurn(sbd)

    let log = try decode([ChatMessage].self, sbd.sb("operator", "--log", "--json"))

    #expect(log.map { "\($0.role): \($0.text)" } == ["user: three", "assistant: Done: three"])
  }

  @Test func operatorReportsStillListsAReportFromTheOldConversation() throws {
    let sbd = try Instance()
    try setMaxTurns(sbd, 2)
    let op = try operatorAfter(sbd, turns: ["one"])
    try reportHelpers.reported(sbd, op, "PR #12 merged.", needsYou: false)
    try turn(sbd, op.id, "two")
    try waitForReset(sbd, op.id)
    try turn(sbd, op.id, "three")

    let texts = try reportHelpers.reports(sbd, all: true).compactMap { $0["text"]?.string }

    #expect(texts.contains("PR #12 merged."), "\(texts)")
  }

  // MARK: The auto-compact window

  @Test func theOperatorLaunchesWithTheDefaultAutoCompactWindow() throws {
    let sbd = try Instance()

    let op = try operatorHelpers.idleOperator(sbd)

    #expect(try conversationHelpers.compactWindows(sbd, op, count: 1) == ["183000"])
  }

  @Test func aWindowSetWhileSbdRunsAppliesToTheOperatorsLaunch() throws {
    let sbd = try Instance()
    try setOperator(sbd, ["autoCompactWindow": 120_000])

    let op = try operatorHelpers.idleOperator(sbd)

    #expect(try conversationHelpers.compactWindows(sbd, op, count: 1) == ["120000"])
  }

  @Test func aWindowOfZeroLeavesTheOperatorOnClaudesOwnWindow() throws {
    let sbd = try Instance()
    try setOperator(sbd, ["autoCompactWindow": 0])

    let op = try operatorHelpers.idleOperator(sbd)

    #expect(try conversationHelpers.compactWindows(sbd, op, count: 1) == [""])
  }

  @Test func theRotatedLaunchCarriesTheWindow() throws {
    let sbd = try Instance()

    let (_, new, _) = try rotatedOperatorAfterTheNextTurn(sbd)

    #expect(try conversationHelpers.compactWindows(sbd, new, count: 1) == ["183000"])
  }

  // MARK: Import

  /// A `claude agents` row for a stopped background conversation in the work folder.
  func agentRow(_ sbd: Instance, _ id: String, name: String) -> JSON {
    [
      "sessionId": .string(id), "cwd": .string(sbd.work), "kind": "background",
      "startedAt": .number(Double(nowMs())), "id": "0badf00d", "state": "stopped", "name": .string(name),
    ]
  }

  @Test func importDoesNotOfferARotatedAwayOperatorConversation() throws {
    let sbd = try Instance(accounts: ["A"])
    let (old, _, _) = try rotatedOperator(sbd)
    let other = UUID().uuidString.lowercased()
    try sbd.writeAgents(
      "A", [agentRow(sbd, old.claudeSessionId, name: "old operator"), agentRow(sbd, other, name: "notes")])

    let listed = try sbd.client.importable(all: true).sessions.map(\.id)

    #expect(!listed.contains(old.claudeSessionId), "\(listed)")
    #expect(listed.contains(other), "\(listed)")
  }

  @Test func importingARotatedAwayOperatorConversationImportsNothing() throws {
    let sbd = try Instance(accounts: ["A"])
    let (old, _, _) = try rotatedOperator(sbd)
    try sbd.writeAgents("A", [agentRow(sbd, old.claudeSessionId, name: "old operator")])
    let before = try sbd.client.sessions().map(\.id)

    let result = try sbd.client.importSessions([old.claudeSessionId])

    #expect(result.imported.isEmpty, "\(result.imported.map(\.name))")
    #expect(try sbd.client.sessions().map(\.id) == before)
  }
}

// MARK: What blocks a reset

extension OperatorResetTests {
  /// One condition that holds the old conversation. The operator on a host, an MCP relaunch, and a resume launch
  /// under way are not driven here: sbd always creates the operator on this Mac, and the two launches pass too fast
  /// to hold. A permission prompt or question opens only during a turn, which `turnRunning` covers.
  enum Blocker: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// One of the operator's waits asked its question in the old conversation.
    case awaitingJudgment
    /// The user's answer to an open report arrives as a message without the question.
    case needsYouReport
    /// A paste whose UserPromptSubmit the stub holds until `$SB_HOME/report` exists.
    case messageInFlight
    /// A message in sbd's queue for a stopped claude, which waits for claude's next launch. Only a stopped claude's
    /// id can change, so this is the condition that guards the swap itself.
    case queuedForStoppedClaude
    /// A Bash call that lasts until `$SB_HOME/report` exists.
    case turnRunning
    /// A background job that runs after the turn ended.
    case backgroundJob
    /// A subagent that started and has not stopped.
    case subagent
    /// A terminal shows the operator's claude pane.
    case terminalAttached
    case paused

    var testDescription: String { rawValue }
  }

  /// Puts the blocker on the operator and returns what clears it.
  func block(_ sbd: Instance, _ op: SessionSummary, _ blocker: Blocker) throws -> () throws -> Void {
    switch blocker {
    case .awaitingJudgment:
      let repo = try sbd.repoWithOrigin()
      let s = try sbd.worktreeSession(repo)
      let wait = try followThrough.arm(sbd, followThrough.rmWorktreeArgs(s))
      let stops = try mainStops(sbd, op.id)
      try sbd.sb("done", s.id)
      try followThrough.waitForStatus(sbd, wait, .awaitingJudgment)
      try sbd.waitFor("the operator's turn for the question", timeout: 30) { try mainStops(sbd, op.id) > stops }
      return { try sbd.sb("wait", "Operator", "--clear") }
    case .needsYouReport:
      try reportHelpers.reported(sbd, op)
      return { try sbd.sb("ack", "Operator") }
    case .messageInFlight:
      try sbd.sb("send", op.id, "lag held")
      try sbd.waitFor("the paste of the held message") { try !sbd.events(op.id, "pasting", text: "lag held").isEmpty }
      return { sbd.hold("report") }
    case .queuedForStoppedClaude:
      let queue = StoppedQueueTests()
      try sbd.stopClaude(op.id)
      let mark = try sbd.lastEventId(op.id)
      let pid = try queue.launchUnreported(sbd, op, .killed, after: mark)
      let sent = try #require(JSON.parse(try sbd.sb("send", "--json", op.id, "the stranded note")))
      try #require(sent["delivery"]?.string == "queued", "\(sent.text)")
      kill(pid_t(pid), SIGTERM)
      try sbd.waitFor(op.id, "claude to exit before SessionStart") { $0.claudePid == nil && !$0.live }
      try sbd.release(EarlyExit.killed.gate)
      return { try sbd.sb("open", op.id) }
    case .turnRunning:
      try sbd.sb("send", op.id, "slow held")
      try sbd.waitFor(op.id, "the held tool call") { $0.state == .working }
      return { sbd.hold("report") }
    case .backgroundJob:
      try sbd.sb("send", op.id, "background 100 held")
      try sbd.waitFor(op.id, "the turn that starts the job") { $0.lastReply == "Started a job of 100 s." }
      return {
        try sbd.endJob()
        sbd.hold("report")
      }
    case .subagent:
      try sbd.postHook(op.id, "SubagentStart", ["agent_id": "agent-reset-1", "agent_type": "general-purpose"])
      return { try sbd.postHook(op.id, "SubagentStop", ["agent_id": "agent-reset-1"]) }
    case .terminalAttached:
      let detach = try sbd.attach(op.id)
      try sbd.waitFor(op.id, "the attached terminal") { $0.attached }
      return { detach() }
    case .paused:
      try sbd.pauseJSON(op.id)
      _ = try sbd.waitForPausedExit(op.id)
      return { try sbd.sb("resume", op.id) }
    }
  }

  /// The operator's Stop events from its main session.
  func mainStops(_ sbd: Instance, _ id: String) throws -> Int {
    try sbd.events(id, kind: "Stop").filter { !$0.fromSubagent }.count
  }

  /// The operator has had its two turns under the default limit of 20. The blocker goes on, and only then does
  /// `maxTurns` drop to 2, so the reset is due while the blocker holds and no reset can slip in before it.
  @Test(arguments: Blocker.allCases)
  func aBlockerHoldsADueResetAndTheResetFollowsOnceItClears(_ blocker: Blocker) throws {
    let sbd = try Instance()
    let op = try operatorAfter(sbd)
    let clear = try block(sbd, op, blocker)
    try setMaxTurns(sbd, 2)

    try expectNoReset(sbd, op, "while \(blocker) holds")
    try clear()

    let reset = try waitForReset(sbd, op.id)
    #expect(reset.data["from"]?.string == op.claudeSessionId, "\(reset.data.text)")
  }

  /// A wait whose condition has not been met holds no question in the conversation.
  @Test func aWaitWhoseConditionIsUnmetDoesNotBlockTheReset() throws {
    let sbd = try Instance()
    let op = try operatorAfter(sbd)
    let kid = try sbd.idleSession(name: "kid")
    let wait = try followThrough.arm(
      sbd, ["--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm", "--note", "remove it"])
    try #require(try followThrough.operatorsWait(sbd, wait)?.actionStatus == nil)

    try setMaxTurns(sbd, 2)

    try waitForReset(sbd, op.id)
  }
}

// MARK: sb events --all

/// `sb events --all` and the `events` request's `all`, which read every matching event past the default limit of 200.
@Suite(.blocking(timeLimit: .seconds(120))) struct EventsAllTests {
  /// An idle session with 201 notes and two Notifications after them.
  func sessionWithManyNotes(_ sbd: Instance) throws -> String {
    let s = try sbd.idleSession()
    for i in 0...200 { try sbd.addPlainNote(s.id, "note \(i)") }
    try sbd.postProbe(s.id)
    try sbd.postProbe(s.id)
    return s.id
  }

  @Test func allWithTwoKindsListsEveryMatchingEventPastTheDefaultLimit() throws {
    let sbd = try Instance()
    let id = try sessionWithManyNotes(sbd)
    let every = try sbd.events(id)
    let expected = every.filter { ["note", "Notification"].contains($0.kind) }.map(\.id)
    try #require(expected.count > Event.defaultLimit)
    try #require(every.count > expected.count, "the session has no event of another kind")

    let listed = try sbd.sbEvents("--session", id, "--kind", "note", "--kind", "Notification", "--all")

    #expect(listed.map(\.id) == expected)
  }

  @Test func allListsMoreThanALimitWould() throws {
    let sbd = try Instance()
    let id = try sessionWithManyNotes(sbd)
    let limited = try sbd.sbEvents("--session", id, "--kind", "note", "--limit", "50")

    let listed = try sbd.sbEvents("--session", id, "--kind", "note", "--all")

    #expect(limited.count == 50)
    #expect(listed.count == 201)
  }

  /// Existing callers that pass `--kind` without `--all` keep the default limit.
  @Test func kindWithoutAllKeepsTheDefaultLimit() throws {
    let sbd = try Instance()
    let id = try sessionWithManyNotes(sbd)
    let newest = try sbd.events(id).filter { $0.kind == "note" }.suffix(Event.defaultLimit).map(\.id)

    let listed = try sbd.sbEvents("--session", id, "--kind", "note")

    #expect(listed.map(\.id) == Array(newest))
  }

  @Test func theEventsRequestWithAllListsEveryEventOfTheKind() throws {
    let sbd = try Instance()
    let id = try sessionWithManyNotes(sbd)
    let notes = try sbd.events(id).filter { $0.kind == "note" }.map(\.id)

    let listed = try sbd.client.call(
      "events", ["session": .string(id), "kinds": ["note"], "all": true], as: [Event].self)

    #expect(listed.map(\.id) == notes)
  }

  @Test func theEventsRequestWithAllAndSinceListsEveryLaterEvent() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let mark = try sbd.lastEventId(s.id)
    for i in 0...200 { try sbd.addPlainNote(s.id, "note \(i)") }
    let notes = try sbd.events(s.id, after: mark).filter { $0.kind == "note" }.map(\.id)

    let listed = try sbd.client.call(
      "events", ["session": .string(s.id), "since": .number(Double(mark)), "kinds": ["note"], "all": true],
      as: [Event].self)

    #expect(listed.map(\.id) == notes)
  }
}
