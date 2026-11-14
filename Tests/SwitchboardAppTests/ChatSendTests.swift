import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

// MARK: - Fixtures

private func user(_ text: String, t: Int64) -> ChatMessage { ChatMessage(role: .user, text: text, t: t) }

private func assistant(_ text: String = "Done.", t: Int64) -> ChatMessage {
  ChatMessage(role: .assistant, text: text, t: t)
}

private func pending(
  _ text: String, after: ChatMessage? = nil, status: PendingChatMessage.Status = .accepted(.pasted)
) -> PendingChatMessage {
  PendingChatMessage(text: text, after: after, status: status)
}

private func unansweredIDs(_ pending: [PendingChatMessage], log: [ChatMessage]) -> [UUID] {
  PendingChatMessage.unanswered(pending, log: log).map(\.id)
}

// MARK: - Matching the log

@Suite struct PendingChatMessageMatching {
  @Test func aLaterUserMessageHoldingTheTextAnswersIt() {
    let message = pending("Rebase onto main")

    let left = unansweredIDs([message], log: [user("Rebase onto main", t: 1)])

    #expect(left.isEmpty)
  }

  @Test func aUserMessageThatAddsImageMarkersAroundTheTextAnswersIt() {
    let message = pending("look at this")

    let left = unansweredIDs([message], log: [user("[Image #1] look at this", t: 1)])

    #expect(left.isEmpty)
  }

  @Test func theMatchTrimsThePendingText() {
    let message = pending("  yes\n")

    let left = unansweredIDs([message], log: [user("yes", t: 1)])

    #expect(left.isEmpty)
  }

  @Test(arguments: [
    PendingChatMessage.Status.sending, .accepted(.pasted), .accepted(.resumed), .accepted(.queued), .accepted(nil),
  ])
  func aMessageThatHasNotFailedCanBeAnswered(_ status: PendingChatMessage.Status) {
    let message = pending("yes", status: status)

    let left = unansweredIDs([message], log: [user("yes", t: 1)])

    #expect(left.isEmpty)
  }

  @Test func anEmptyLogAnswersNothing() {
    let messages = [pending("a"), pending("b")]

    let left = unansweredIDs(messages, log: [])

    #expect(left == messages.map(\.id))
  }

  @Test func aUserMessageWithOtherTextDoesNotAnswerIt() {
    let message = pending("Rebase onto main")

    let left = unansweredIDs([message], log: [user("Merge it", t: 1)])

    #expect(left == [message.id])
  }

  @Test func anAssistantMessageHoldingTheTextDoesNotAnswerIt() {
    let message = pending("yes")

    let left = unansweredIDs([message], log: [assistant("yes", t: 1)])

    #expect(left == [message.id])
  }

  @Test(arguments: [
    "Switchboard: a is ready to merge.",
    "<local-command-stdout>a is ready to merge.</local-command-stdout>",
    "<local-command-stderr>a is ready to merge.</local-command-stderr>",
  ])
  func aNoticeOrCommandOutputAfterTheBaselineDoesNotAnswerIt(_ line: String) {
    let base = assistant(t: 1)
    let message = pending("a is ready to merge.", after: base)

    let left = unansweredIDs([message], log: [base, user(line, t: 2)])

    #expect(left == [message.id])
  }

  // MARK: Slash commands

  @Test(arguments: [
    "<command-name>/model</command-name><command-args>opus</command-args>",
    "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>",
    "<command-message>model</command-message>\n<command-args>opus</command-args>\n<command-name>/model</command-name>",
  ])
  func theSlashCommandsTranscriptLineAnswersIt(_ line: String) {
    let message = pending("/model opus")

    let left = unansweredIDs([message], log: [user(line, t: 1)])

    #expect(left.isEmpty)
  }

  @Test func aSlashCommandWithOtherArgumentsDoesNotAnswerIt() {
    let message = pending("/model opus")

    let left = unansweredIDs(
      [message], log: [user("<command-name>/model</command-name><command-args>sonnet</command-args>", t: 1)])

    #expect(left == [message.id])
  }

  @Test func aSlashCommandWithoutArgumentsAnswersIt() {
    let message = pending("/clear")

    let left = unansweredIDs(
      [message], log: [user("<command-name>/clear</command-name><command-args></command-args>", t: 1)])

    #expect(left.isEmpty)
  }

  // MARK: Images only

  @Test func anEmptyTextSendIsAnsweredByTheNextUserMessage() {
    let base = assistant(t: 1)
    let message = pending("", after: base)

    let left = unansweredIDs([message], log: [base, user("[Image #1]", t: 2)])

    #expect(left.isEmpty)
  }

  @Test func anEmptyTextSendIsNotAnsweredByTheBaselineItself() {
    let base = user("[Image #1]", t: 1)
    let message = pending("", after: base)

    let left = unansweredIDs([message], log: [base])

    #expect(left == [message.id])
  }

  @Test(arguments: [
    ChatMessage(role: .assistant, text: "Looking at it.", t: 2),
    ChatMessage(role: .user, text: "Switchboard: a is ready to merge.", t: 2),
    ChatMessage(role: .user, text: "<local-command-stdout>Set model to Sonnet</local-command-stdout>", t: 2),
  ])
  func anEmptyTextSendIsNotAnsweredByAReplyANoticeOrCommandOutput(_ later: ChatMessage) {
    let base = assistant(t: 1)
    let message = pending("", after: base)

    let left = unansweredIDs([message], log: [base, later])

    #expect(left == [message.id])
  }

  // MARK: The baseline

  @Test func aUserMessageBeforeTheBaselineDoesNotAnswerIt() {
    let base = assistant(t: 2)
    let message = pending("yes", after: base)

    let left = unansweredIDs([message], log: [user("yes", t: 1), base])

    #expect(left == [message.id])
  }

  @Test func theBaselineItselfDoesNotAnswerIt() {
    let base = user("yes", t: 1)
    let message = pending("yes", after: base)

    let left = unansweredIDs([message], log: [base])

    #expect(left == [message.id])
  }

  @Test func aUserMessageAfterTheBaselineAnswersIt() {
    let base = assistant(t: 2)
    let message = pending("yes", after: base)

    let left = unansweredIDs([message], log: [user("yes", t: 1), base, user("yes", t: 3)])

    #expect(left.isEmpty)
  }

  @Test(arguments: [
    ChatMessage(role: .assistant, text: "Done.", t: 99),
    ChatMessage(role: .assistant, text: "Something else.", t: 2),
    ChatMessage(role: .user, text: "yes", t: 99),
  ])
  func aBaselineTheLogNoLongerHoldsSearchesTheWholeLog(_ gone: ChatMessage) {
    let message = pending("yes", after: gone)

    let left = unansweredIDs([message], log: [user("yes", t: 1), assistant(t: 2)])

    #expect(left.isEmpty)
  }

  // MARK: Several pending messages

  @Test func oneLogMessageAnswersOnlyTheFirstOfTwoIdenticalMessages() {
    let first = pending("yes")
    let second = pending("yes")

    let left = unansweredIDs([first, second], log: [user("yes", t: 1)])

    #expect(left == [second.id])
  }

  @Test func twoLogMessagesAnswerTwoIdenticalMessages() {
    let first = pending("yes")
    let second = pending("yes")

    let left = unansweredIDs([first, second], log: [user("yes", t: 1), assistant(t: 2), user("yes", t: 3)])

    #expect(left.isEmpty)
  }

  @Test func aMessageMustComeAfterTheAnswerOfTheOneBeforeIt() {
    let first = pending("yes")
    let second = pending("no")

    let left = unansweredIDs([first, second], log: [user("no", t: 1), user("yes", t: 2)])

    #expect(left == [second.id])
  }

  @Test func anUnansweredMessageKeepsItsPlaceInOrder() {
    let a = pending("a")
    let b = pending("b")
    let c = pending("c")

    let left = unansweredIDs([a, b, c], log: [user("b", t: 1)])

    #expect(left == [a.id, c.id])
  }

  // MARK: Failed messages

  @Test func aFailedMessageIsNeverAnswered() {
    let message = pending("yes", status: .failed("the session is gone"))

    let left = unansweredIDs([message], log: [user("yes", t: 1)])

    #expect(left == [message.id])
  }

  @Test func aFailedMessageDoesNotUseUpTheLogMessage() {
    let failed = pending("yes", status: .failed("the session is gone"))
    let waiting = pending("yes", status: .accepted(.queued))

    let left = unansweredIDs([failed, waiting], log: [user("yes", t: 1)])

    #expect(left == [failed.id])
  }
}

// MARK: - Parity with the paste check

/// `unanswered` matches a plain pasted text the way `Transcript.hasUserMessage` does. Both read one transcript file.
/// The inputs leave out notices, command output and slash commands, where the two differ by design.
@Suite struct PendingChatMessageParity {
  struct Case: Sendable, CustomTestStringConvertible {
    let sent: String
    let written: String
    var testDescription: String { "\(sent.debugDescription) against \(written.debugDescription)" }
  }

  static let cases = [
    Case(sent: "Fix it.", written: "Fix it."),
    Case(sent: "  Fix it.\n", written: "Fix it."),
    Case(sent: "Fix it.", written: "Merge it."),
    Case(sent: "look at this", written: "[Image #1] look at this"),
    Case(sent: #"say "hi" in C:\temp\new"#, written: #"say "hi" in C:\temp\new"#),
    Case(sent: "line one\nline two", written: "line one\nline two"),
    Case(sent: "tab\there", written: "tab\there"),
    Case(sent: "caf\u{E9} na\u{EF}ve", written: "caf\u{E9} na\u{EF}ve"),
    Case(sent: "null", written: "null"),
    Case(sent: "42", written: "42"),
    Case(sent: "Fix it.", written: "fix it."),
  ]

  func transcript(holding text: String) throws -> String {
    let dir = NSTemporaryDirectory() + "chat-send-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let line: JSON = [
      "type": "user", "isSidechain": false, "timestamp": "2026-11-14T10:00:00.000Z",
      "message": ["role": "user", "content": .string(text)],
    ]
    let path = dir + "/transcript.jsonl"
    try (JSONCoding.encode(line) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  @Test(arguments: cases)
  func unansweredAgreesWithTheTranscriptsPasteCheck(_ c: Case) throws {
    let path = try transcript(holding: c.written)
    let log = Transcript.messages(path, limit: 50, on: LocalMachine())

    let pasted = Transcript.hasUserMessage(path, holding: c.sent, from: 0, on: LocalMachine())
    let answered = PendingChatMessage.unanswered([pending(c.sent)], log: log).isEmpty

    #expect(answered == pasted)
  }
}

// MARK: - The model

@MainActor
@Suite struct BoardModelChatSend {
  static let conversation = needsItem("m", manager: true)

  /// A model with chat `c`, Manager conversation `m`, and work session `a`.
  func model() -> BoardModel {
    appliedModel([chatItem("c", group: "g1"), Self.conversation, needsItem("a"), chatItem("c2", group: "g2")])
  }

  /// Answers `send` with `delivery` and `chat-log` with `log`, and every other request with null.
  func stub(_ model: BoardModel, delivery: Delivery = .pasted, log: [ChatMessage] = []) {
    model.send = { op, _ in
      switch op {
      case "send": return ["delivery": .string(delivery.rawValue)]
      case "chat-log": return try JSONCoding.convert(log, to: JSON.self)
      default: return .null
      }
    }
  }

  func pendingStatuses(_ model: BoardModel, _ session: String) -> [PendingChatMessage.Status] {
    (model.pendingChat[session] ?? []).map(\.status)
  }

  // MARK: Adding a pending message

  @Test(arguments: ["c", "m"])
  func sendAddsASendingMessageBeforeSbdAnswers(_ session: String) {
    let model = model()
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send(session, "Rebase onto main")

    #expect(pendingStatuses(model, session) == [.sending])
  }

  @Test(arguments: ["c", "m"])
  func thePendingMessageHoldsTheSentText(_ session: String) {
    let model = model()
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send(session, "Rebase onto main")

    #expect(model.pendingChat[session]?.map(\.text) == ["Rebase onto main"])
  }

  @Test func thePendingMessagesBaselineIsTheLogsLastMessage() {
    let model = model()
    let last = assistant("Which branch?", t: 2)
    model.chatLogs["c"] = [user("Rebase", t: 1), last]
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send("c", "main")

    #expect(model.pendingChat["c"]?.first?.after == last)
  }

  @Test func thePendingMessageHasNoBaselineBeforeTheLogLoads() {
    let model = model()
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send("c", "main")

    #expect(model.pendingChat["c"]?.count == 1)
    #expect(model.pendingChat["c"]?.first?.after == nil)
  }

  @Test func aSendToAWorkSessionAddsNoPendingMessage() async {
    let model = model()
    stub(model)

    model.send("a", "Rebase onto main")
    await settle { !model.sending.contains("a") }

    #expect((model.pendingChat["a"] ?? []).isEmpty)
  }

  @Test func aSecondSendWhileTheFirstIsInFlightAddsNoSecondMessage() {
    let model = model()
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }
    model.send("c", "first")

    model.send("c", "second")

    #expect(model.pendingChat["c"]?.map(\.text) == ["first"])
  }

  // MARK: sbd's answer

  @Test(arguments: [Delivery.pasted, .resumed, .queued])
  func anAcceptedSendRecordsTheDelivery(_ delivery: Delivery) async {
    let model = model()
    stub(model, delivery: delivery)

    model.send("c", "Rebase onto main")
    await settle { !model.sending.contains("c") }

    #expect(pendingStatuses(model, "c") == [.accepted(delivery)])
  }

  @Test func anAcceptedSendToAManagerConversationRecordsTheDelivery() async {
    let model = model()
    stub(model, delivery: .queued)

    model.send("m", "How is it going?")
    await settle { !model.sending.contains("m") }

    #expect(pendingStatuses(model, "m") == [.accepted(.queued)])
  }

  @Test(arguments: ["c", "m"])
  func aRefusedSendRecordsTheError(_ session: String) async {
    let model = model()
    model.send = { op, _ in
      if op == "send" { throw Refusal(description: "the session is gone") }
      return .null
    }

    model.send(session, "Rebase onto main")
    await settle { !model.sending.contains(session) }

    #expect(pendingStatuses(model, session) == [.failed("the session is gone")])
  }

  @Test func aRefusedChatSendLeavesTheErrorBannerEmpty() async {
    let model = model()
    model.send = { op, _ in
      if op == "send" { throw Refusal(description: "the session is gone") }
      return .null
    }

    model.send("c", "Rebase onto main")
    await settle { !model.sending.contains("c") }

    #expect(model.actionError == nil)
  }

  @Test func anAcceptedChatSendCallsSent() async {
    let model = model()
    stub(model)
    let sent = Counter()

    model.send("c", "Rebase onto main", sent: { sent.increment() })
    await settle { !model.sending.contains("c") }

    #expect(sent.value == 1)
  }

  @Test func aRefusedChatSendDoesNotCallSent() async {
    let model = model()
    model.send = { op, _ in
      if op == "send" { throw Refusal(description: "the session is gone") }
      return .null
    }
    let sent = Counter()

    model.send("c", "Rebase onto main", sent: { sent.increment() })
    await settle { !model.sending.contains("c") }

    #expect(sent.value == 0)
  }

  @Test func aRefusedWorkSessionSendStillShowsTheErrorBanner() async {
    let model = model()
    model.send = { op, _ in
      if op == "send" { throw Refusal(description: "the session is gone") }
      return .null
    }

    model.send("a", "Rebase onto main")
    await settle { !model.sending.contains("a") }

    #expect(model.actionError == "send: the session is gone")
  }

  // MARK: A new send

  @Test func aNewSendDropsTheSessionsFailedMessagesAndKeepsTheWaitingOnes() {
    let model = model()
    let failed = pending("first", status: .failed("the session is gone"))
    let waiting = pending("second", status: .accepted(.queued))
    model.pendingChat["c"] = [failed, waiting]
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send("c", "third")

    #expect(model.pendingChat["c"]?.map(\.text) == ["second", "third"])
    #expect(model.pendingChat["c"]?.first?.id == waiting.id)
  }

  @Test func aNewSendKeepsAnotherSessionsFailedMessages() {
    let model = model()
    let other = pending("first", status: .failed("the session is gone"))
    model.pendingChat["c2"] = [other]
    let release = DispatchSemaphore(value: 0)
    model.send = { _, _ in
      release.wait()
      return .null
    }
    defer { release.signal() }

    model.send("c", "third")

    #expect(model.pendingChat["c2"]?.map(\.id) == [other.id])
  }

  @Test func aSendAfterARefusalDropsTheRefusedMessage() async throws {
    let model = model()
    let refuse = Counter()
    model.send = { op, _ in
      if op == "send", refuse.increment() == 1 { throw Refusal(description: "the session is gone") }
      return op == "send" ? ["delivery": "pasted"] : .null
    }
    model.send("c", "first")
    await settle { !model.sending.contains("c") }
    try #require(pendingStatuses(model, "c") == [.failed("the session is gone")])

    model.send("c", "second")
    await settle { !model.sending.contains("c") }

    #expect(model.pendingChat["c"]?.map(\.text) == ["second"])
  }

  // MARK: Dismissing

  @Test func dismissPendingDropsThatMessageOnly() {
    let model = model()
    let failed = pending("first", status: .failed("the session is gone"))
    let waiting = pending("second")
    model.pendingChat["c"] = [failed, waiting]

    model.dismissPending(failed.id, in: "c")

    #expect(model.pendingChat["c"]?.map(\.id) == [waiting.id])
  }

  @Test func dismissPendingLeavesAnotherSessionAlone() {
    let model = model()
    let here = pending("first", status: .failed("the session is gone"))
    let there = pending("first", status: .failed("the session is gone"))
    model.pendingChat["c"] = [here]
    model.pendingChat["c2"] = [there]

    model.dismissPending(here.id, in: "c")

    #expect(model.pendingChat["c2"]?.map(\.id) == [there.id])
  }

  // MARK: Loading the log

  @Test func loadChatLogDropsThePendingMessagesTheLogAnswers() async {
    let model = model()
    let answered = pending("Rebase onto main")
    let waiting = pending("Then merge it", status: .accepted(.queued))
    model.pendingChat["c"] = [answered, waiting]
    stub(model, log: [user("Rebase onto main", t: 1)])

    model.loadChatLog("c")
    await settle { model.chatLogs["c"] != nil }

    #expect(model.pendingChat["c"]?.map(\.id) == [waiting.id])
  }

  @Test func loadChatLogLeavesAnotherSessionsPendingMessages() async {
    let model = model()
    let other = pending("Rebase onto main")
    model.pendingChat["c2"] = [other]
    stub(model, log: [user("Rebase onto main", t: 1)])

    model.loadChatLog("c")
    await settle { model.chatLogs["c"] != nil }

    #expect(model.pendingChat["c2"]?.map(\.id) == [other.id])
  }

  @Test func loadChatLogKeepsAMessageThatOnlyAnEarlierUserMessageHolds() async throws {
    let model = model()
    let earlier = user("yes", t: 1)
    let reply = assistant("Done.", t: 2)
    model.chatLogs["c"] = [earlier, reply]
    let release = DispatchSemaphore(value: 0)
    model.send = { op, _ in
      if op == "send" { release.wait() }
      return .null
    }
    model.send("c", "yes")
    let sent = try #require(model.pendingChat["c"]?.first)
    stub(model, log: [earlier, reply, assistant("Anything else?", t: 3)])
    release.signal()

    model.loadChatLog("c")
    await settle { model.chatLogs["c"]?.count == 3 }

    #expect(model.pendingChat["c"]?.map(\.id) == [sent.id])
  }

  @Test func loadChatLogKeepsAFailedMessage() async {
    let model = model()
    let failed = pending("Rebase onto main", status: .failed("the session is gone"))
    model.pendingChat["c"] = [failed]
    stub(model, log: [user("Rebase onto main", t: 1)])

    model.loadChatLog("c")
    await settle { model.chatLogs["c"] != nil }

    #expect(model.pendingChat["c"]?.map(\.id) == [failed.id])
  }

  @Test func aFailedLogReadKeepsThePendingMessages() async {
    let model = model()
    let waiting = pending("Rebase onto main")
    model.pendingChat["c"] = [waiting]
    model.chatLogs["c"] = [assistant(t: 1)]
    let read = Counter()
    model.send = { op, _ in
      if op == "chat-log" {
        read.increment()
        throw Boom()
      }
      return .null
    }

    model.loadChatLog("c")
    await settle { read.value > 0 }
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(model.pendingChat["c"]?.map(\.id) == [waiting.id])
  }
}
