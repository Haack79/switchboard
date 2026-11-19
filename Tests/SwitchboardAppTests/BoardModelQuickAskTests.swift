import AppKit
import Foundation
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

/// What sbd answers a quick ask with.
private func answered(_ text: String) -> JSON { ["answer": .string(text), "model": "sonnet"] }

/// A stand-in for the model's `ask`. It records each question and token. A held stub waits for `release` before it
/// answers, and it ignores a cancel, as a call whose cancel lost the race does.
private final class AskStub: Sendable {
  private let calls = OSAllocatedUnfairLock<[(question: String, token: CallCancel)]>(initialState: [])
  private let finished = Counter()
  private let release = DispatchSemaphore(value: 0)
  private let answer: @Sendable (String) throws -> JSON
  private let holds: @Sendable (Int) -> Bool

  /// `holds` gets the call's number, from 1, and says whether that call waits for `release`.
  init(
    holds: @escaping @Sendable (Int) -> Bool = { _ in false },
    answer: @escaping @Sendable (String) throws -> JSON = { answered("Answer to \($0)") }
  ) {
    self.holds = holds
    self.answer = answer
  }

  var questions: [String] { calls.withLock { $0.map(\.question) } }
  var tokens: [CallCancel] { calls.withLock { $0.map(\.token) } }
  /// How many calls have returned or thrown.
  var returned: Int { finished.value }

  /// Lets one held call answer.
  func releaseOne() { release.signal() }

  /// Lets every held call answer, so no queue thread stays blocked after a test.
  func releaseAll() { for _ in 0..<8 { release.signal() } }

  var call: @Sendable (String, CallCancel) throws -> JSON {
    { [self] question, token in
      let number = calls.withLock { calls in
        calls.append((question, token))
        return calls.count
      }
      defer { finished.increment() }
      if holds(number) { release.wait() }
      return try answer(question)
    }
  }
}

/// One request that the model sent to sbd.
private struct Sent: Sendable {
  var op: String
  var args: [String: JSON]
}

/// A `send` that records each request and answers `manager` with the id of a new conversation.
private final class SendRecorder: Sendable {
  private let sent = OSAllocatedUnfairLock<[Sent]>(initialState: [])

  var requests: [Sent] { sent.withLock { $0 } }
  var managerRequests: [Sent] { requests.filter { $0.op == "manager" } }

  var send: @Sendable (String, [String: JSON]) throws -> JSON {
    { [self] op, args in
      sent.withLock { $0.append(Sent(op: op, args: args)) }
      return op == "manager" ? ["id": "m-new"] : .null
    }
  }
}

/// A work session with no Inbox item.
private func workSession(_ id: String) -> SessionSummary {
  var s = needsItem(id, state: .working)
  s.triage = nil
  return s
}

/// Lets main-actor work that a finished call queued run. A result that should be dropped shows no change to wait
/// for, so these tests wait a fixed time.
@MainActor private func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

/// The quick ask panel: ⇧⌘K opens it, Return asks sbd, closing it discards the answer and cancels a running ask,
/// and Continue as chat starts a Manager conversation.
@MainActor
@Suite struct BoardModelQuickAskTests {
  /// A model whose `ask` is the stub and whose `send` records requests, with the panel open.
  private func model(_ stub: AskStub, recorder: SendRecorder = SendRecorder()) -> BoardModel {
    let model = offlineModel()
    model.ask = stub.call
    model.send = recorder.send
    model.openQuickAsk()
    return model
  }

  // MARK: Open

  @Test func openStartsEditingWithNothingAsked() {
    let model = offlineModel()

    model.openQuickAsk()

    #expect(model.quickAsk?.asked == nil)
    #expect(model.quickAsk?.phase == .editing)
  }

  @Test func thePanelStartsClosed() {
    #expect(offlineModel().quickAsk == nil)
  }

  @Test func theOpenPanelCountsAsASheet() throws {
    let model = offlineModel()
    try #require(!model.presentingSheet)

    model.openQuickAsk()

    #expect(model.presentingSheet)
  }

  @Test func theClosedPanelNoLongerCountsAsASheet() {
    let model = offlineModel()
    model.openQuickAsk()

    model.closeQuickAsk()

    #expect(!model.presentingSheet)
  }

  // MARK: Submit

  @Test(arguments: ["", "   ", "\n\t"])
  func anEmptyQuestionDoesNotAsk(_ question: String) async {
    let stub = AskStub()
    let model = model(stub)

    model.submitQuickAsk(question)
    await pause()

    #expect(stub.questions.isEmpty)
    #expect(model.quickAsk?.phase == .editing)
  }

  @Test func submitAsksOnceWithTheTrimmedQuestion() async {
    let stub = AskStub()
    let model = model(stub)

    model.submitQuickAsk("  what needs me?\n")
    await settle { model.quickAsk?.phase != .asking && model.quickAsk?.phase != .editing }

    #expect(stub.questions == ["what needs me?"])
  }

  @Test func submitShowsTheAnswer() async {
    let stub = AskStub(answer: { _ in answered("Two sessions need you.") })
    let model = model(stub)

    model.submitQuickAsk("what needs me?")
    await settle { model.quickAsk?.phase == .answered("Two sessions need you.") }

    #expect(model.quickAsk?.phase == .answered("Two sessions need you."))
  }

  @Test func theRunShowsAskingUntilTheAnswerArrives() async {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let model = model(stub)

    model.submitQuickAsk("what needs me?")
    await settle { stub.questions.count == 1 }

    #expect(model.quickAsk?.phase == .asking)
  }

  @Test func aThrownErrorShowsItsText() async {
    let stub = AskStub(answer: { _ in throw Refusal(description: "claude exited with status 1") })
    let model = model(stub)

    model.submitQuickAsk("what needs me?")
    await settle {
      if case .failed = model.quickAsk?.phase { return true }
      return false
    }

    guard case .failed(let text) = model.quickAsk?.phase else {
      Issue.record("phase is \(String(describing: model.quickAsk?.phase))")
      return
    }
    #expect(text.contains("claude exited with status 1"))
  }

  @Test func submitRecordsTheTrimmedQuestionAsAsked() async {
    let stub = AskStub()
    let model = model(stub)

    model.submitQuickAsk("  what needs me?\n")
    await settle { model.quickAsk?.phase == .answered("Answer to what needs me?") }

    #expect(model.quickAsk?.asked == "what needs me?")
  }

  @Test func anEditedQuestionAfterAnAnswerAsksAgain() async {
    let stub = AskStub()
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { model.quickAsk?.phase == .answered("Answer to what needs me?") }

    model.submitQuickAsk("which account is active?")
    await settle { model.quickAsk?.phase == .answered("Answer to which account is active?") }

    #expect(stub.questions == ["what needs me?", "which account is active?"])
    #expect(model.quickAsk?.phase == .answered("Answer to which account is active?"))
  }

  // MARK: Close

  @Test func closeClearsThePanel() {
    let model = model(AskStub())

    model.closeQuickAsk()

    #expect(model.quickAsk == nil)
  }

  @Test func closeCancelsTheRunningAsk() async throws {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    let token = try #require(stub.tokens.first)

    model.closeQuickAsk()

    #expect(token.isCancelled)
  }

  @Test func closeTwiceAndCloseWithoutAPanelChangeNothing() {
    let model = offlineModel()
    model.closeQuickAsk()
    model.openQuickAsk()

    model.closeQuickAsk()
    model.closeQuickAsk()

    #expect(model.quickAsk == nil)
  }

  @Test func anAnswerThatArrivesAfterCloseIsDropped() async {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    model.closeQuickAsk()

    stub.releaseOne()
    await settle { stub.returned == 1 }
    await pause()

    #expect(model.quickAsk == nil)
  }

  @Test func anAnswerThatArrivesAfterCloseAndReopenLeavesTheNewPanelEditing() async {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    model.closeQuickAsk()
    model.openQuickAsk()

    stub.releaseOne()
    await settle { stub.returned == 1 }
    await pause()

    #expect(model.quickAsk?.phase == .editing)
    #expect(model.quickAsk?.asked == nil)
  }

  /// The ask queue runs one call at a time, so the first call's late answer reaches the main actor before the
  /// second's. The second answer shows, and nothing replaces it later.
  @Test func anAnswerThatArrivesAfterCloseAndReopenLosesToTheNewAsk() async {
    let stub = AskStub(holds: { $0 == 1 })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("first")
    await settle { stub.tokens.count == 1 }
    model.closeQuickAsk()
    model.openQuickAsk()
    model.submitQuickAsk("second")

    stub.releaseOne()
    await settle { model.quickAsk?.phase == .answered("Answer to second") }
    await settle { stub.returned == 2 }
    await pause()

    #expect(model.quickAsk?.phase == .answered("Answer to second"))
  }

  @Test func aSecondSubmitDuringARunCancelsTheFirst() async throws {
    let stub = AskStub(holds: { $0 == 1 })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("first")
    await settle { stub.tokens.count == 1 }
    let first = try #require(stub.tokens.first)

    model.submitQuickAsk("second")

    #expect(first.isCancelled)
  }

  @Test func aSecondSubmitDuringARunShowsOnlyTheSecondAnswer() async {
    let stub = AskStub(holds: { $0 == 1 })
    defer { stub.releaseAll() }
    let model = model(stub)
    model.submitQuickAsk("first")
    await settle { stub.tokens.count == 1 }
    model.submitQuickAsk("second")

    stub.releaseOne()
    await settle { stub.returned == 2 }
    await settle { model.quickAsk?.phase == .answered("Answer to second") }
    await pause()

    #expect(stub.questions == ["first", "second"])
    #expect(model.quickAsk?.phase == .answered("Answer to second"))
  }

  // MARK: Continue as chat

  @Test func continueAfterAnAnswerSendsANewManagerConversationWithTheChatPrompt() async throws {
    let stub = AskStub(answer: { _ in answered("Two sessions need you.") })
    let recorder = SendRecorder()
    let model = model(stub, recorder: recorder)
    model.submitQuickAsk("what needs me?")
    await settle { model.quickAsk?.phase == .answered("Two sessions need you.") }

    model.continueQuickAskAsChat()
    await settle { !recorder.managerRequests.isEmpty }

    let sent = try #require(recorder.managerRequests.first)
    #expect(recorder.managerRequests.count == 1)
    #expect(sent.args["new"] == true)
    #expect(
      sent.args["text"] == .string(QuickAsk.chatPrompt(question: "what needs me?", answer: "Two sessions need you.")))
  }

  @Test func continueSelectsTheNewConversation() async {
    let stub = AskStub()
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { model.quickAsk?.phase == .answered("Answer to what needs me?") }

    model.continueQuickAskAsChat()
    await settle { model.selection == "m-new" }

    #expect(model.selection == "m-new")
  }

  @Test func continueClosesThePanel() async {
    let stub = AskStub()
    let model = model(stub)
    model.submitQuickAsk("what needs me?")
    await settle { model.quickAsk?.phase == .answered("Answer to what needs me?") }

    model.continueQuickAskAsChat()
    await settle { model.quickAsk == nil }

    #expect(model.quickAsk == nil)
  }

  @Test func continueDuringARunCancelsItAndSendsTheQuestionAlone() async throws {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let recorder = SendRecorder()
    let model = model(stub, recorder: recorder)
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    let token = try #require(stub.tokens.first)

    model.continueQuickAskAsChat()
    await settle { !recorder.managerRequests.isEmpty }

    #expect(token.isCancelled)
    let sent = try #require(recorder.managerRequests.first)
    #expect(sent.args["new"] == true)
    #expect(sent.args["text"] == .string(QuickAsk.chatPrompt(question: "what needs me?", answer: nil)))
    #expect(sent.args["text"] == "what needs me?")
  }

  @Test func anAnswerThatArrivesAfterContinueDoesNotReopenThePanel() async {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let recorder = SendRecorder()
    let model = model(stub, recorder: recorder)
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    model.continueQuickAskAsChat()
    await settle { !recorder.managerRequests.isEmpty }

    stub.releaseOne()
    await settle { stub.returned == 1 }
    await pause()

    #expect(model.quickAsk == nil)
  }

  @Test func continueAfterAFailureSendsTheQuestionAlone() async throws {
    let stub = AskStub(answer: { _ in throw Refusal(description: "timed out after 90 s") })
    let recorder = SendRecorder()
    let model = model(stub, recorder: recorder)
    model.submitQuickAsk("what needs me?")
    await settle {
      if case .failed = model.quickAsk?.phase { return true }
      return false
    }

    model.continueQuickAskAsChat()
    await settle { !recorder.managerRequests.isEmpty }

    let sent = try #require(recorder.managerRequests.first)
    #expect(sent.args["text"] == "what needs me?")
  }

  // MARK: Focus

  @Test func focusClosesThePanel() {
    let model = appliedModel([workSession("s1")])
    model.ask = AskStub().call
    model.openQuickAsk()

    model.focus(.id("s1"))

    #expect(model.quickAsk == nil)
  }

  @Test func focusCancelsTheRunningAsk() async throws {
    let stub = AskStub(holds: { _ in true })
    defer { stub.releaseAll() }
    let model = appliedModel([workSession("s1")])
    model.ask = stub.call
    model.openQuickAsk()
    model.submitQuickAsk("what needs me?")
    await settle { stub.tokens.count == 1 }
    let token = try #require(stub.tokens.first)

    model.focus(.id("s1"))

    #expect(token.isCancelled)
  }
}
