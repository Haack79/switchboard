import Foundation
import Testing

@testable import SwitchboardCore

/// A `sent` event for a message that sbd accepted, as this sbd records it.
private func sent(_ text: String, _ delivery: Delivery, _ t: Int64) -> Event {
  var data: [String: JSON] = ["text": .string(text), "delivery": .string(delivery.rawValue)]
  if delivery == .pasted { data[Delivery.awaitsDeliveredKey] = true }
  return event("sent", t, data)
}

/// A `sent` event for a direct paste, as an sbd from before `delivered`
/// followed direct pastes recorded it.
private func oldSent(_ text: String, _ t: Int64) -> Event {
  event("sent", t, ["text": .string(text), "delivery": .string(Delivery.pasted.rawValue)])
}

/// One of the events that follow a message after sbd accepted it.
private func after(_ kind: String, _ text: String, _ t: Int64) -> Event {
  event(kind, t, ["text": .string(text)])
}

private func replay(_ events: [Event]) -> SessionReplay {
  .replaying(events, session: session())
}

/// The deliveries whose message goes through the paste queue.
private let pasteDeliveries: [Delivery] = [.pasted, .queued]

/// What a restart of sbd rebuilds for the messages on their way: `pending`
/// holds the ones that sbd pastes again, and `uncertain` holds the ones whose
/// paste started and may or may not have reached claude.
@Suite struct ReplayDeliveryTests {
  @Test(arguments: pasteDeliveries)
  func anAcceptedMessageStaysPendingUntilDelivered(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1)])

    #expect(r.pending == ["fix it"])
  }

  @Test(arguments: pasteDeliveries)
  func deliveredTakesTheMessageOutOfPending(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1), after("pasting", "fix it", 2), after("delivered", "fix it", 3)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  @Test(arguments: pasteDeliveries)
  func pastingWithoutDeliveredMakesTheMessageUncertainRatherThanPending(_ delivery: Delivery) {
    let r = replay([sent("fix it", delivery, 1), after("pasting", "fix it", 2)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain == ["fix it"])
  }

  @Test func deliveryUnknownDropsTheUncertainMessage() {
    let r = replay([
      sent("fix it", .pasted, 1), after("pasting", "fix it", 2), after("delivery_unknown", "fix it", 3),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// A failed paste is known not to have arrived, so the message waits to be
  /// pasted again, once, whether sbd pasted it at once or from its queue.
  @Test(arguments: pasteDeliveries, [false, true])
  func aFailedPasteKeepsTheMessagePendingOnce(_ delivery: Delivery, _ started: Bool) {
    let r = replay(
      [sent("fix it", delivery, 1)] + (started ? [after("pasting", "fix it", 2)] : [])
        + [after("requeued", "fix it", 3)])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  /// A log from before `pasting` existed has `requeued` after a failed direct
  /// paste whose `sent` added nothing to `pending`.
  @Test func anOldFailedDirectPasteIsPendingOnce() {
    let r = replay([oldSent("fix it", 1), after("requeued", "fix it", 2)])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  /// A failed paste goes back to the front of the queue, ahead of the
  /// messages that came after it, as sbd puts it back.
  @Test func aFailedPasteGoesBackAheadOfLaterMessages() {
    let r = replay([
      sent("one", .queued, 1), sent("two", .queued, 2), after("pasting", "one", 3), after("requeued", "one", 4),
    ])

    #expect(r.pending == ["one", "two"])
    #expect(r.uncertain.isEmpty)
  }

  /// claude got the message as the prompt of its launch, so no paste follows.
  @Test func aMessageThatStartedClaudeIsNotPending() {
    let r = replay([sent("fix it", .resumed, 1)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// A resend after an unknown delivery is a new send that waits for its own `delivered`.
  @Test func aResendAfterAnUnknownDeliveryIsPendingUntilDelivered() {
    let r = replay([
      sent("fix it", .pasted, 1), after("pasting", "fix it", 2), after("delivery_unknown", "fix it", 3),
      sent("fix it", .pasted, 4),
    ])

    #expect(r.pending == ["fix it"])
    #expect(r.uncertain.isEmpty)
  }

  @Test func anUncertainMessageLeavesTheOthersPendingInOrder() {
    let r = replay([
      sent("one", .queued, 1), sent("two", .queued, 2), sent("three", .queued, 3), after("pasting", "one", 4),
    ])

    #expect(r.pending == ["two", "three"])
    #expect(r.uncertain == ["one"])
  }

  /// A log from an sbd that wrote no `awaitsDeliveredKey` holds a `sent` with
  /// delivery `pasted` and no `delivered` for every direct paste. A new build
  /// replays every log in full. sbd pastes restored messages on load. Only a
  /// `sent` that carries `awaitsDeliveredKey` waits for its `delivered`, so
  /// none of those old messages reaches its session again.
  @Test func anOldDirectPasteWhosePromptLandedIsNotPending() {
    let r = replay([
      oldSent("fix it", 1), event("UserPromptSubmit", 2, ["prompt": "fix it"]),
      event("Stop", 3, ["last_assistant_message": "Done."]),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// Nothing after the old `sent` shows that the paste arrived, and it still isn't pending.
  @Test func anOldDirectPasteWithoutAPromptIsNotPending() {
    let r = replay([oldSent("fix it", 1), oldSent("and this", 2)])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain.isEmpty)
  }

  /// The field must say true. Another value is not one that sbd writes.
  @Test func aDirectPasteWhoseFieldIsNotTrueIsNotPending() {
    let r = replay([
      event(
        "sent", 1,
        ["text": "fix it", "delivery": .string(Delivery.pasted.rawValue), Delivery.awaitsDeliveredKey: "yes"])
    ])

    #expect(r.pending.isEmpty)
  }

  /// A UserPromptSubmit doesn't settle a paste that sbd started. Only
  /// `delivered` or `delivery_unknown` does, and the check on load records
  /// one of them.
  @Test func aStartedPasteWhosePromptLandedStaysUncertain() {
    let r = replay([
      sent("fix it", .queued, 1), after("pasting", "fix it", 2), event("UserPromptSubmit", 3, ["prompt": "fix it"]),
    ])

    #expect(r.pending.isEmpty)
    #expect(r.uncertain == ["fix it"])
  }

  /// The replay is what a snapshot stores, so `uncertain` survives a snapshot.
  @Test func theUncertainMessagesSurviveEncoding() throws {
    let r = replay([sent("fix it", .pasted, 1), after("pasting", "fix it", 2)])

    let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(r))

    #expect(decoded.uncertain == ["fix it"])
  }
}

/// What a restart rebuilds after claude exited at the trust dialog. Live,
/// `Service.closeTrust` puts the launch's prompt at the front of `pending`,
/// and later messages go behind it. Replay must build the same queue.
@Suite struct ReplayTrustTests {
  /// A launch that carried `prompt` and stopped at the trust dialog, a
  /// message queued while the card was open, the exit, and a message queued after it.
  private func exitAtTheDialog(_ prompt: String) -> [Event] {
    [
      sent(prompt, .resumed, 1), event("started", 1, ["prompt": .string(prompt)]), event("running", 2),
      trustDialog(prompt: prompt), sent("queued before the exit", .queued, 4), trustClosed(5, prompt: prompt),
      sent("queued after the exit", .queued, 7),
    ]
  }

  @Test(arguments: ["hello", "null", "  42  ", "Say \"hi\"\nthen\tstop", "queued before the exit"])
  func trustClosedPutsThePromptFirst(_ prompt: String) {
    let r = replay(exitAtTheDialog(prompt))

    #expect(r.pending == [prompt, "queued before the exit", "queued after the exit"])
    #expect(r.uncertain.isEmpty)
  }

  @Test func trustClosedPutsThePromptAheadOfAFailedPaste() {
    let r = replay([
      sent("one", .queued, 1), after("pasting", "one", 2), after("requeued", "one", 3), trustDialog(t: 4),
      trustClosed(5, prompt: "hello"),
    ])

    #expect(r.pending == ["hello", "one"])
  }

  @Test(arguments: [nil, ""] as [String?])
  func trustClosedWithoutAPromptAddsNothing(_ prompt: String?) {
    let r = replay([
      event("started", 1, ["prompt": .null]), trustDialog(prompt: nil), sent("queued", .queued, 4),
      trustClosed(5, prompt: prompt),
    ])

    #expect(r.pending == ["queued"])
  }

  @Test func trustClosedWithANullPromptAddsNothing() {
    let closed = Event(id: 6, session: "s1", t: 5, kind: "trust_closed", data: ["card": 5, "prompt": .null])

    let r = replay([trustDialog(prompt: nil), closed])

    #expect(r.pending.isEmpty)
  }

  /// The kept prompt reaches claude by a paste after the next launch, so
  /// its `delivered` takes it out like any other message.
  @Test func theKeptPromptLeavesPendingWhenItsPasteIsDelivered() {
    let r = replay(
      exitAtTheDialog("hello") + [
        event("resumed", 8, ["prompt": .null]), event("SessionStart", 9), after("pasting", "hello", 10),
        after("delivered", "hello", 11),
      ])

    #expect(r.pending == ["queued before the exit", "queued after the exit"])
    #expect(r.uncertain.isEmpty)
  }

  @Test func theKeptPromptSurvivesEncoding() throws {
    let r = replay(exitAtTheDialog("hello"))

    let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(r))

    #expect(decoded.pending == r.pending)
  }
}

/// What a restart rebuilds for a paused session's held messages and the resume message that `unpause` puts
/// first. Live, `unpause` puts the resume message at the front of `pending`. Replay must build the same queue.
@Suite struct PauseReplayTests {
  /// A queued `sent` event, held while the session was paused when `held` is true, and put at the front when
  /// `first` is true.
  private func queued(_ text: String, _ t: Int64, held: Bool = false, first: Bool = false) -> Event {
    var data: [String: JSON] = ["text": .string(text), "delivery": .string(Delivery.queued.rawValue)]
    if held { data["held"] = true }
    if first { data["first"] = true }
    return event("sent", t, data)
  }

  @Test func aFirstMessageGoesAheadOfTheMessagesQueuedBeforeIt() {
    let r = replay([queued("A", 1), queued("B", 2), queued("C", 3, first: true)])

    #expect(r.pending == ["C", "A", "B"])
  }

  @Test func heldMessagesWaitInPendingInTheirOrder() {
    let r = replay([queued("A", 1, held: true), queued("B", 2, held: true)])

    #expect(r.pending == ["A", "B"])
  }

  @Test func theResumeMessageGoesAheadOfTheHeldMessagesAndLaterOnesFollow() {
    let r = replay([
      queued("A", 1, held: true), queued("B", 2, held: true), queued("go on", 3, first: true), queued("D", 4),
    ])

    #expect(r.pending == ["go on", "A", "B", "D"])
  }

  @Test(arguments: ["hello", "null", "", "  42  ", "Say \"hi\"\nthen\tstop"])
  func theFirstMessageKeepsItsTextExactly(_ text: String) {
    let r = replay([queued("A", 1), queued(text, 2, first: true)])

    #expect(r.pending == [text, "A"])
  }

  @Test func theFirstMessageLeavesPendingWhenItsPasteIsDelivered() {
    let r = replay([
      queued("A", 1, held: true), queued("go on", 2, first: true), after("pasting", "go on", 3),
      after("delivered", "go on", 4),
    ])

    #expect(r.pending == ["A"])
    #expect(r.uncertain.isEmpty)
  }

  @Test func aFirstMessageWithAFalseFlagQueuesAtTheBack() {
    var late = queued("C", 3)
    late.data = .object((late.data.object ?? [:]).merging(["first": false]) { $1 })

    let r = replay([queued("A", 1), queued("B", 2), late])

    #expect(r.pending == ["A", "B", "C"])
  }

  @Test func theRebuiltOrderSurvivesEncoding() throws {
    let r = replay([queued("A", 1, held: true), queued("go on", 2, first: true)])

    let decoded = try JSONCoding.decode(SessionReplay.self, from: try JSONCoding.encode(r))

    #expect(decoded.pending == ["go on", "A"])
  }
}
