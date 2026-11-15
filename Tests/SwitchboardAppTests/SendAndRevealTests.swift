import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSend {

  @Test func doesNotReportASendThatFailed() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    await settle { model.actionError != nil }
    #expect(model.actionError != nil)
    #expect(sent.value == 0)
  }

  @Test func reportsASendThatSucceeded() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    await settle { sent.value > 0 }
    #expect(sent.value == 1)
  }

  @Test func ignoresASecondSendWhileTheFirstIsPending() async {
    let model = offlineModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      Thread.sleep(forTimeInterval: 0.2)
      return .null
    }
    let sent = Counter()
    model.send("a", "hello") { sent.increment() }
    model.send("a", "hello") { sent.increment() }
    #expect(model.sending == ["a"])
    await settle { sent.value > 0 }
    await settle { model.sending.isEmpty }
    #expect(requests.value == 1)
    #expect(sent.value == 1)
    #expect(model.sending.isEmpty)
  }

  @Test func allowsASendAfterAFailedOne() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    model.send("a", "hello")
    await settle { model.actionError != nil }
    await settle { model.sending.isEmpty }
    #expect(model.sending.isEmpty)
  }
}

@MainActor
@Suite struct MessageDraft {
  @Test func clearsAnUnchangedDraft() {
    let draft = MessageField.Draft()
    draft.text = "hello"
    draft.clear(ifStill: "hello")
    #expect(draft.text.isEmpty)
  }

  @Test func clearsADraftThatOnlyGainedTrailingWhitespace() {
    let draft = MessageField.Draft()
    draft.text = "hello \n"
    draft.clear(ifStill: "hello")
    #expect(draft.text.isEmpty)
  }

  @Test func keepsTextTypedAfterTheSend() {
    let draft = MessageField.Draft()
    draft.text = "hello again"
    draft.clear(ifStill: "hello")
    #expect(draft.text == "hello again")
  }

  @Test func keepsTheTextWhenTheSendFails() async {
    let model = offlineModel()
    model.send = { _, _ in throw Boom() }
    let draft = MessageField.Draft()
    draft.text = "hello"
    draft.submit("a", to: model)
    for _ in 0..<300 where model.actionError == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.actionError != nil)
    #expect(draft.text == "hello")
  }

  @Test func clearsTheTextWhenTheSendSucceeds() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let draft = MessageField.Draft()
    draft.text = "hello"
    draft.submit("a", to: model)
    for _ in 0..<300 where !draft.text.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
    #expect(draft.text.isEmpty)
  }

  // MARK: submit(then:)

  /// Work session `a` and chat `c`. A chat's send takes a different path, which marks a pending message.
  static let targets = [needsItem("a"), chatItem("c", group: "g1")]

  @Test(arguments: ["a", "c"])
  func submitRunsThenOnceWhenSbdAcceptsTheSend(_ session: String) async {
    let model = appliedModel(Self.targets)
    model.send = { _, _ in .null }
    let draft = MessageField.Draft()
    draft.text = "hello"
    let ran = Counter()

    draft.submit(session, to: model) { ran.increment() }
    await settle { !model.sending.contains(session) }

    #expect(ran.value == 1)
  }

  /// The terminal view hides the field in `then`. An empty draft lets it hide.
  @Test func submitRunsThenAfterTheDraftClears() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    let draft = MessageField.Draft()
    draft.text = "hello"
    let seen = Field("unset")

    draft.submit("a", to: model) { seen.text = draft.text }
    await settle { seen.text != "unset" }

    #expect(seen.text.isEmpty)
  }

  @Test func submitDoesNotRunThenBeforeSbdAnswers() async {
    let (model, release, requests) = heldModel()
    let draft = MessageField.Draft()
    draft.text = "hello"
    let ran = Counter()

    draft.submit("a", to: model) { ran.increment() }
    await settle { requests.value == 1 }
    let early = ran.value
    release.signal()
    await settle { ran.value > 0 }

    #expect(early == 0)
    #expect(ran.value == 1)
  }

  @Test(arguments: ["a", "c"])
  func submitDoesNotRunThenWhenTheSendFails(_ session: String) async {
    let model = appliedModel(Self.targets)
    model.send = { _, _ in throw Boom() }
    let draft = MessageField.Draft()
    draft.text = "hello"
    let ran = Counter()

    draft.submit(session, to: model) { ran.increment() }
    await settle { !model.sending.contains(session) }

    #expect(ran.value == 0)
  }

  @Test func submitOfAnEmptyDraftDoesNotRunThen() async {
    let model = offlineModel()
    let requests = Counter()
    model.send = { _, _ in
      requests.increment()
      return .null
    }
    let draft = MessageField.Draft()
    let ran = Counter()

    draft.submit("a", to: model) { ran.increment() }
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(requests.value == 0)
    #expect(ran.value == 0)
  }
}

@MainActor
@Suite struct BoardModelReveal {
  @Test func selectsTheSessionAndOpensTheWindow() {
    let model = appliedModel([needsItem("a"), needsItem("b")])
    let opened = Counter()
    model.showWindow = { opened.increment() }
    model.reveal("b")
    #expect(model.selection == "b")
    #expect(opened.value == 1)
  }
}
