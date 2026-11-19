import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelRead {
  @Test func readsTheFollowupsBeforeTheSessions() {
    var order: [String] = []
    _ = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      },
      followups: {
        order.append("followup-ls")
        return []
      })
    #expect(order == ["followup-ls", "ls"])
  }

  @Test func readsOnlyTheSessionsWithoutAFollowupRead() {
    var order: [String] = []
    let (_, more) = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      }, followups: nil)
    #expect(order == ["ls"])
    #expect(more == nil)
  }
}

private func replied(_ lastReply: String?, id: String = "s1") -> SessionSummary {
  var s = needsItem(id)
  s.lastReply = lastReply
  return s
}

// MARK: The reply cache

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelReadReplyCache {
  @Test func aReadForTheCurrentReplyGivesTheTranscriptText() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")

    #expect(model.reply(for: replied("Ship it?")) == "Done. Ship it?")
  }

  /// Two replies of the same length in one state used to keep the first one's text.
  @Test func aReadForAnEarlierReplyOfTheSameLengthGivesTheNewReply() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")

    #expect(model.reply(for: replied("Fix it?!")) == "Fix it?!")
  }

  @Test func withoutAReadTheReplyIsTheHookText() {
    #expect(offlineModel().reply(for: replied("Ship it?")) == "Ship it?")
  }

  @Test func aSessionWithoutAReplyHasNone() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")

    #expect(model.reply(for: replied(nil)) == nil)
  }

  @Test func aReadForAnotherSessionIsIgnored() {
    let model = offlineModel()
    model.replies["s2"] = (hook: "Ship it?", text: "Done. Ship it?")

    #expect(model.reply(for: replied("Ship it?", id: "s1")) == "Ship it?")
  }

  /// `firstRequest` waits for ever when nothing is sent, so this waits at most 3 seconds for the request.
  @Test func loadReplyAsksSbdForTheSessionsReply() async throws {
    let (model, sent) = recordingModel()

    model.loadReply(replied("Ship it?"))
    await sent.wait(for: "reply")

    let request = try #require(sent.value.first { $0.op == "reply" })
    #expect(request.args == ["session": "s1"])
  }

  @Test func loadReplyStoresTheTextForTheReplyItWasReadFor() async {
    let model = offlineModel()
    model.send = { _, _ in .object(["reply": "Done. Ship it?"]) }
    let session = replied("Ship it?")

    model.loadReply(session)
    await settle { model.reply(for: session) == "Done. Ship it?" }

    #expect(model.reply(for: session) == "Done. Ship it?")
  }

  /// A read that answers after the next reply arrived belongs to the earlier reply.
  @Test func aReadThatAnswersAfterANewReplyOfTheSameLengthGivesTheNewReply() async {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .object(["reply": "Done. Ship it?"])
    }

    model.loadReply(replied("Ship it?"))
    await settle { sent.value == 1 }
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.reply(for: replied("Fix it?!")) == "Fix it?!")
  }

  /// A failed read used to leave the old text in place for good.
  @Test func aFailedReadAfterANewReplyGivesTheNewReply() async {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      throw Refusal(description: "no transcript")
    }
    let current = replied("Fix it?!")

    model.loadReply(current)
    await settle { sent.value == 1 }
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.reply(for: current) == "Fix it?!")
  }
}

// MARK: When the Inbox reads the reply again

@Suite struct TriageDetailReplyKey {
  @Test func twoRepliesOfTheSameLengthReadAgain() {
    #expect(TriageDetail.replyKey(replied("Ship it?")) != TriageDetail.replyKey(replied("Fix it?!")))
  }

  @Test func theSameReplyKeepsItsKey() {
    #expect(TriageDetail.replyKey(replied("Ship it?")) == TriageDetail.replyKey(replied("Ship it?")))
  }

  @Test func anotherSessionWithTheSameReplyHasItsOwnKey() {
    let first = TriageDetail.replyKey(replied("Ship it?", id: "s1"))

    #expect(first != TriageDetail.replyKey(replied("Ship it?", id: "s2")))
  }

  @Test func aNewReplyAfterNoneReadsAgain() {
    #expect(TriageDetail.replyKey(replied(nil)) != TriageDetail.replyKey(replied("Ship it?")))
  }
}
