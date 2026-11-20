import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func operatorItem(_ id: String) -> SessionSummary {
  var s = needsItem(id, manager: true, state: .working)
  s.kind = .operator
  s.name = Manager.operatorName
  return s
}

private let conversation = needsItem("m", manager: true)
private let work = needsItem("a")

private func run(sent: Int64?, outcome: Schedule.Run.Outcome = .pasted) -> Schedule.Run {
  Schedule.Run(t: scheduleNow, outcome: outcome, skipped: 0, sent: sent)
}

/// A loop's prompt sent three times, with a reply after each.
private let plainLog = [
  ChatMessage(role: .user, text: "Check the queue", t: 1), ChatMessage(role: .assistant, text: "Empty.", t: 2),
  ChatMessage(role: .user, text: "Check the queue", t: 3), ChatMessage(role: .assistant, text: "Two items.", t: 4),
  ChatMessage(role: .user, text: "Check the queue", t: 5), ChatMessage(role: .assistant, text: "Empty.", t: 6),
]

/// What `openRunReply` can change.
private struct JumpState: Equatable {
  var selection: String?
  var showingTerminal: Bool
  var chatJump: ChatJump?
  var entries: Int

  @MainActor init(_ model: BoardModel) {
    selection = model.selection
    showingTerminal = model.showingTerminal
    chatJump = model.chatJump
    entries = model.history.entries.count
  }
}

@MainActor
@Suite struct BoardModelChatJumpTests {
  /// Manager conversation `m`, operator `op`, chat `c`, and work session `a`.
  static var sessions: [SessionSummary] {
    [conversation, operatorItem("op"), chatItem("c", group: "g1"), work]
  }

  /// A model on the Loops tab with the Terminal toggle on, so a jump that turns it off shows.
  func model() -> BoardModel {
    let model = appliedModel(Self.sessions)
    model.show(.loops)
    model.showingTerminal = true
    return model
  }

  /// Records every request. It answers `chat-log` with `plainLog`, where the message at `marked` carries the
  /// request's `sent`, and every other request with null. With `hold`, the first `chat-log` waits for it.
  @discardableResult
  func stub(_ model: BoardModel, marked: Int? = 2, hold: DispatchSemaphore? = nil) -> SentRequests {
    let sent = SentRequests()
    let reads = Counter()
    model.send = { op, args in
      sent.append(op, args)
      guard op == "chat-log" else { return .null }
      if reads.increment() == 1 { hold?.wait() }
      var log = plainLog
      if let marked, let id = args["sent"]?.int { log[marked].sent = Int64(id) }
      return try JSONCoding.convert(log, to: JSON.self)
    }
    return sent
  }

  func chatLogArgs(_ sent: SentRequests) -> [[String: JSON]] {
    sent.value.filter { $0.op == "chat-log" }.map(\.args)
  }

  /// Reads chat `c`'s log, which no jump names, and waits for its answer. `poller` answers reads in order, so an
  /// earlier read's answer has arrived by then.
  func fence(_ model: BoardModel) async {
    model.loadChatLog("c")
    await settle { model.chatLogs["c"] != nil }
  }

  // MARK: Opening a run's reply

  @Test func openRunReplySelectsTheManagerConversation() {
    let model = model()

    model.openRunReply(conversation, run(sent: 7))

    #expect(model.selection == "m")
  }

  @Test func openRunReplyTurnsTheTerminalToggleOff() {
    let model = model()

    model.openRunReply(conversation, run(sent: 7))

    #expect(!model.showingTerminal)
  }

  @Test func openRunReplySetsTheJump() {
    let model = model()

    model.openRunReply(conversation, run(sent: 7))

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  @Test func openRunReplyAddsOneHistoryEntry() {
    let model = model()
    let before = model.history.entries.count

    model.openRunReply(conversation, run(sent: 7))

    #expect(model.history.entries.count == before + 1)
    #expect(model.history.current == model.location)
  }

  @Test func backAfterOpenRunReplyReturnsToLoops() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.goBack()

    #expect(model.selection == nil)
    #expect(model.mainView == .loops)
  }

  @Test(arguments: [
    (work, run(sent: 7)), (conversation, run(sent: nil)), (work, run(sent: nil)),
    (conversation, run(sent: nil, outcome: .failed)),
  ])
  func openRunReplyWithoutALinkChangesNothing(_ session: SessionSummary, _ run: Schedule.Run) {
    let model = model()
    let before = JumpState(model)

    model.openRunReply(session, run)

    #expect(JumpState(model) == before)
  }

  @Test func openRunReplyOnTheOperatorSelectsIt() {
    let model = model()

    model.openRunReply(operatorItem("op"), run(sent: 7))

    #expect(model.selection == "op")
    #expect(model.chatJump == ChatJump(session: "op", sent: 7))
  }

  /// `operator` resumes a stopped operator, and reading a run's reply must not start claude.
  @Test func openRunReplyOnTheOperatorSendsNoOperatorRequest() async {
    let model = model()
    let sent = stub(model)

    model.openRunReply(operatorItem("op"), run(sent: 7))
    // `perform` sends on one serial queue, so an `operator` request would reach sbd before this one.
    model.perform("probe", [:])
    await sent.wait(for: "probe")

    #expect(!sent.ops.contains("operator"))
  }

  // MARK: Reading the jumped chat's log

  @Test func loadChatLogSendsTheRunsSentForTheJumpedSession() async {
    let request = await firstRequest {
      $0.chatJump = ChatJump(session: "m", sent: 7)
      $0.loadChatLog("m")
    }

    #expect(request.op == "chat-log")
    #expect(request.args == ["session": "m", "sent": .number(7)])
  }

  @Test func loadChatLogSendsNoSentForAnotherSession() async {
    let request = await firstRequest {
      $0.chatJump = ChatJump(session: "m", sent: 7)
      $0.loadChatLog("c")
    }

    #expect(request.args == ["session": "c"])
  }

  /// Without a jump, the read asks for what it asked for before jumps existed.
  @Test(arguments: ["m", "c", "op"])
  func loadChatLogWithoutAJumpSendsOnlyTheSession(_ session: String) async {
    let request = await firstRequest { $0.loadChatLog(session) }

    #expect(request.args == ["session": .string(session)])
  }

  @Test(arguments: [0, 2, 4])
  func loadChatLogStoresTheLogWithoutTheMarker(_ marked: Int) async {
    let model = model()
    stub(model, marked: marked)
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.loadChatLog("m")
    await settle { model.chatLogs["m"] != nil }

    #expect(model.chatLogs["m"] == plainLog)
  }

  @Test(arguments: [0, 2, 4])
  func loadChatLogSetsTheFoundRow(_ marked: Int) async {
    let model = model()
    stub(model, marked: marked)
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.loadChatLog("m")
    await settle { model.chatJump?.found != nil }

    #expect(model.chatJump?.found == .row(marked))
  }

  @Test func loadChatLogSetsMissingWhenTheAnswerMarksNothing() async {
    let model = model()
    stub(model, marked: nil)
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.loadChatLog("m")
    await settle { model.chatJump?.found != nil }

    #expect(model.chatJump?.found == .missing)
  }

  @Test func aPlainReadOfAnotherSessionLeavesTheJumpAlone() async {
    let model = model()
    stub(model)
    model.chatJump = ChatJump(session: "m", sent: 7)

    await fence(model)

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  // MARK: Answers that started before the current jump

  /// Reads `m` for a jump to `sent` 1, and moves the jump to `sent` 2 before sbd answers.
  func answerForAnOlderJump() async -> BoardModel {
    let model = model()
    let hold = DispatchSemaphore(value: 0)
    stub(model, hold: hold)
    model.chatJump = ChatJump(session: "m", sent: 1)
    model.loadChatLog("m")
    model.chatJump = ChatJump(session: "m", sent: 2)
    hold.signal()
    await fence(model)
    return model
  }

  @Test func anAnswerForAnOlderJumpLeavesTheLogAlone() async {
    let model = await answerForAnOlderJump()

    #expect(model.chatLogs["m"] == nil)
  }

  @Test func anAnswerForAnOlderJumpLeavesFoundAlone() async {
    let model = await answerForAnOlderJump()

    #expect(model.chatJump == ChatJump(session: "m", sent: 2))
  }

  /// Reads `m` without a jump, and opens a run's reply in `m` before sbd answers.
  func plainAnswerFromBeforeTheJump() async -> BoardModel {
    let model = model()
    let hold = DispatchSemaphore(value: 0)
    stub(model, hold: hold)
    model.loadChatLog("m")
    model.openRunReply(conversation, run(sent: 7))
    hold.signal()
    await fence(model)
    return model
  }

  @Test func aPlainAnswerFromBeforeTheJumpLeavesTheLogAlone() async {
    let model = await plainAnswerFromBeforeTheJump()

    #expect(model.chatLogs["m"] == nil)
  }

  @Test func aPlainAnswerFromBeforeTheJumpLeavesFoundAlone() async {
    let model = await plainAnswerFromBeforeTheJump()

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  /// Reads `m` for a jump, and opens a run's reply in chat `c` before sbd answers.
  @Test func anAnswerForAJumpInAnotherChatLeavesFoundAlone() async {
    let model = model()
    let hold = DispatchSemaphore(value: 0)
    stub(model, hold: hold)
    model.chatJump = ChatJump(session: "m", sent: 1)
    model.loadChatLog("m")
    model.openRunReply(chatItem("c", group: "g1"), run(sent: 9))
    hold.signal()
    await settle { model.chatLogs["m"] != nil }

    #expect(model.chatJump == ChatJump(session: "c", sent: 9))
  }

  // MARK: Releasing the jump

  @Test func releaseChatJumpClearsItsOwnSessionsJump() {
    let model = model()
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.releaseChatJump("m")

    #expect(model.chatJump == nil)
  }

  @Test func releaseChatJumpKeepsAnotherSessionsJump() {
    let model = model()
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.releaseChatJump("c")

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  @Test func sendingAMessageIntoTheJumpedChatClearsTheJump() {
    let (model, release, _) = heldModel(Self.sessions)
    defer { release.signal() }
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.send("m", "Check it again")

    #expect(model.chatJump == nil)
  }

  @Test func sendingAMessageIntoAnotherChatKeepsTheJump() {
    let (model, release, _) = heldModel(Self.sessions)
    defer { release.signal() }
    model.chatJump = ChatJump(session: "m", sent: 7)

    model.send("c", "Rebase onto main")

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  // MARK: Navigation clears the jump (Decision 14)

  @Test func selectingAnotherChatClearsTheJump() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.selection = "c"

    #expect(model.chatJump == nil)
  }

  @Test func clearingTheSelectionClearsTheJump() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.selection = nil

    #expect(model.chatJump == nil)
  }

  @Test func backToLoopsClearsTheJump() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.goBack()

    #expect(model.chatJump == nil)
  }

  @Test func backToTheJumpedChatReadsWithoutSent() async throws {
    let model = model()
    let sent = stub(model)
    model.openRunReply(conversation, run(sent: 7))
    model.selection = "c"
    model.goBack()
    try #require(model.selection == "m")

    model.loadChatLog("m")
    await settle { chatLogArgs(sent).count == 1 }

    #expect(chatLogArgs(sent) == [["session": "m"]])
  }

  @Test func selectingTheJumpsOwnSessionKeepsTheJump() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.selection = "m"

    #expect(model.chatJump == ChatJump(session: "m", sent: 7))
  }

  @Test func turningTheTerminalOnForTheJumpedChatClearsTheJump() {
    let model = model()
    model.openRunReply(conversation, run(sent: 7))

    model.showingTerminal = true

    #expect(model.chatJump == nil)
  }

  // MARK: Which runs link

  @Test(arguments: [SessionKind.manager, .chat, .operator])
  func aChatKindsRunWithSentLinks(_ kind: SessionKind) {
    var session = work
    session.kind = kind

    #expect(LoopRow.linksReply(session, run(sent: 7)))
  }

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator])
  func aRunWithoutSentDoesNotLink(_ kind: SessionKind) {
    var session = work
    session.kind = kind

    #expect(!LoopRow.linksReply(session, run(sent: nil)))
  }

  @Test func aWorkSessionsRunWithSentDoesNotLink() {
    #expect(!LoopRow.linksReply(work, run(sent: 7)))
  }

  @Test func aFailedRunDoesNotLink() {
    let failed = Schedule.Run(t: scheduleNow, outcome: .failed, skipped: 0, error: "the folder is missing")

    #expect(!LoopRow.linksReply(conversation, failed))
  }
}
