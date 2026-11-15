import Foundation
import Testing

@testable import SwitchboardCore

private let readTheReply = "read its last reply and decide what's next"
private let snoozeAt: Int64 = 2
/// The end of the snooze in most tests. Every event of a test comes before it unless the test says otherwise.
private let snoozeUntil: Int64 = 1_000_000
/// A time while the snooze runs.
private let during: Int64 = 500_000
/// A time after the snooze ended.
private let after: Int64 = snoozeUntil + 1
private let acknowledgedMs = RecheckSettings().acknowledgedMs

private let newPrompt = "a new prompt"
private let ciFailed = "CI failed"
private let prMerged = "the PR merged"

private func snoozeEvent(_ t: Int64 = snoozeAt, until: Int64 = snoozeUntil) -> Event {
  event("snooze", t, ["until": .number(Double(until))])
}

/// The events of a turn that ended with `reply`.
private func turn(_ reply: String, start: Int64 = 0) -> [Event] {
  [
    event("UserPromptSubmit", start, ["prompt": "go"]),
    event("Stop", start + 1, ["last_assistant_message": .string(reply)]),
  ]
}

/// A PR that every ready-to-merge condition passes.
private func mergeablePR(
  headSha: String = samplePRHead, mergeable: Mergeable = .mergeable, checks: String? = "SUCCESS"
) -> PullRequest {
  var pr = samplePR(headSha: headSha, mergeable: mergeable, checks: checks)
  pr.trunkConfig = false
  pr.mergeQueue = false
  pr.reviewDecisionRead = true
  return pr
}

private func failedDepotRun(on head: String = samplePRHead) -> DepotRun {
  DepotRun(id: "run1", headSha: head, status: "failed", jobs: 3, failed: [DepotRun.Job(name: "tests")])
}

/// The PermissionRequest of `touch x`, as event `id`, so its card's id is `id`.
private func touchRequest(_ id: Int64, _ t: Int64) -> Event {
  Event(id: id, session: "s1", t: t, kind: "PermissionRequest", data: .object(touch))
}

private func verdict(_ facts: SessionFacts, _ s: Session = session(), at t: Int64) -> Verdict {
  Attention.shown(Attention.evaluate(s, facts, now: t), facts, now: t, acknowledgedMs: acknowledgedMs)
}

private func note(until: Int64 = snoozeUntil, wokeEarly why: String? = nil) -> String {
  "snoozed until \(Wait.formatTime(until))" + (why.map { ", woke early: \($0)" } ?? "")
}

/// Expects a snooze record that no early wake ended. A missing record fails too, so a fold that drops the record
/// can't pass a no-wake test.
private func expectNoWake(_ f: SessionFacts, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(f.snooze != nil, "the snooze record is gone", sourceLocation: sourceLocation)
  #expect(f.snooze?.wokeEarly == nil, sourceLocation: sourceLocation)
}

/// The suites nest under one name, so `--filter SnoozeTests` runs them all.
@Suite struct SnoozeTests {}

// MARK: The record

extension SnoozeTests {
  @Suite struct SnoozeRecord {
    @Test func isActiveAMillisecondBeforeItsEnd() {
      let s = Snooze(until: snoozeUntil, wokeEarly: nil)

      #expect(s.isActive(at: snoozeUntil - 1))
    }

    @Test func isNotActiveAtItsEnd() {
      let s = Snooze(until: snoozeUntil, wokeEarly: nil)

      #expect(!s.isActive(at: snoozeUntil))
    }

    @Test func isNotActiveAfterAnEarlyWake() {
      let s = Snooze(until: snoozeUntil, wokeEarly: newPrompt)

      #expect(!s.isActive(at: snoozeAt + 1))
    }

    @Test func defaultLastsAnHour() {
      #expect(Snooze.defaultMs == 3_600_000)
    }

    @Test(arguments: [nil, newPrompt, ciFailed, prMerged])
    func roundTripsThroughJSON(_ why: String?) throws {
      let s = Snooze(until: snoozeUntil, wokeEarly: why)

      #expect(try JSONCoding.convert(JSON(encoding: s), to: Snooze.self) == s)
    }

    /// sbd's snapshots encode the facts, so the snooze must survive the snapshot.
    @Test func factsWithASnoozeRoundTripThroughJSON() throws {
      let f = facts(turn("Done.") + [snoozeEvent()])

      let decoded = try JSONCoding.convert(JSON(encoding: f), to: SessionFacts.self)

      #expect(decoded == f)
      #expect(decoded.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func factsWithAWokenSnoozeRoundTripThroughJSON() throws {
      let f = facts(turn("Done.") + [snoozeEvent(), touchRequest(9, 3)])

      let decoded = try JSONCoding.convert(JSON(encoding: f), to: SessionFacts.self)

      #expect(decoded.snooze?.wokeEarly == newPrompt)
    }
  }
}

// MARK: Events that set and clear the record

extension SnoozeTests {
  @Suite struct SnoozeEvents {
    @Test func snoozeEventSetsTheRecord() {
      let f = facts(turn("Done.") + [snoozeEvent()])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func unsnoozeEventClearsTheRecord() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("unsnooze", 3)])

      #expect(f.snooze == nil)
    }

    @Test func laterSnoozeReplacesTheTime() {
      let f = facts(turn("Done.") + [snoozeEvent(), snoozeEvent(3, until: 2 * snoozeUntil)])

      #expect(f.snooze == Snooze(until: 2 * snoozeUntil, wokeEarly: nil))
    }

    @Test func laterSnoozeClearsAnEarlyWake() {
      let f = facts(turn("Done.") + [snoozeEvent(), touchRequest(9, 3), snoozeEvent(4, until: 2 * snoozeUntil)])

      #expect(f.snooze == Snooze(until: 2 * snoozeUntil, wokeEarly: nil))
    }

    @Test func laterSnoozeReplacesAnEndedRecord() {
      let f = facts(turn("Done.") + [snoozeEvent(), snoozeEvent(after, until: after + snoozeUntil)])

      #expect(f.snooze == Snooze(until: after + snoozeUntil, wokeEarly: nil))
    }

    @Test(arguments: ["snooze", "unsnooze"])
    func snoozeAndUnsnoozeLeaveTheLastActivity(_ kind: String) {
      let later: Int64 = 50
      let e = kind == "snooze" ? snoozeEvent(later) : event("unsnooze", later)

      let f = facts(turn("Done.") + [e])

      #expect(f.lastActivity == facts(turn("Done.")).lastActivity)
    }
  }
}

// MARK: The display layer

/// Each Inbox verdict that a snooze can hold, built from events.
enum SnoozableItem: String, CaseIterable, Sendable {
  case reply, question, offer, readyToMerge, permissionPrompt, prRule

  /// The facts of the item before any snooze.
  func itemFacts() throws -> SessionFacts {
    switch self {
    case .reply: return facts(turn("Done."))
    case .question: return facts(turn("Which database, Postgres or SQLite?"))
    case .offer: return facts(turn("Want me to push?"))
    case .readyToMerge: return try prFacts(mergeablePR())
    case .permissionPrompt: return facts(promptTurn(touchCall, touch))
    case .prRule: return try prFacts(mergeablePR(mergeable: .conflicting))
    }
  }

  func withSnooze(_ snooze: Snooze) throws -> SessionFacts {
    var f = try itemFacts()
    f.snooze = snooze
    return f
  }
}

private let nonInboxStates = AttentionState.allCases.filter { !AttentionState.inbox.contains($0) }
private let activeSnooze = Snooze(until: snoozeUntil, wokeEarly: nil)
private let wokenSnooze = Snooze(until: snoozeUntil, wokeEarly: newPrompt)

extension SnoozeTests {
  @Suite struct ActiveSnooze {
    @Test(arguments: SnoozableItem.allCases)
    func itemIsInTheInboxWithoutTheSnooze(_ item: SnoozableItem) throws {
      let f = try item.itemFacts()

      #expect(AttentionState.inbox.contains(verdict(f, at: during).state))
    }

    @Test(arguments: SnoozableItem.allCases)
    func activeSnoozeMovesTheItemToWaiting(_ item: SnoozableItem) throws {
      let v = verdict(try item.withSnooze(activeSnooze), at: during)

      #expect(v.state == .waiting)
    }

    @Test(arguments: SnoozableItem.allCases)
    func activeSnoozeMarksTheVerdictSnoozed(_ item: SnoozableItem) throws {
      let v = verdict(try item.withSnooze(activeSnooze), at: during)

      #expect(v.snoozed)
    }

    @Test(arguments: SnoozableItem.allCases)
    func activeSnoozeKeepsTheReason(_ item: SnoozableItem) throws {
      let f = try item.withSnooze(activeSnooze)

      #expect(verdict(f, at: during).reason == Attention.evaluate(session(), f, now: during).reason)
    }

    @Test(arguments: SnoozableItem.allCases)
    func activeSnoozeHasNoNote(_ item: SnoozableItem) throws {
      #expect(verdict(try item.withSnooze(activeSnooze), at: during).snoozeNote == nil)
    }

    /// `ack --undo` reads `acknowledged`, so a snooze must never set it.
    @Test(arguments: SnoozableItem.allCases)
    func activeSnoozeDoesNotMarkTheVerdictAcknowledged(_ item: SnoozableItem) throws {
      #expect(!verdict(try item.withSnooze(activeSnooze), at: during).acknowledged)
    }

    @Test func snoozeHoldsAMillisecondBeforeItsEnd() throws {
      let v = verdict(try SnoozableItem.reply.withSnooze(activeSnooze), at: snoozeUntil - 1)

      #expect(v.state == .waiting)
      #expect(v.snoozed)
    }

    @Test func noSnoozeLeavesTheVerdictUnmarked() throws {
      let v = verdict(try SnoozableItem.reply.itemFacts(), at: during)

      #expect(v == Verdict(state: .needsYou, reason: readTheReply))
      #expect(!v.snoozed)
      #expect(v.snoozeNote == nil)
    }
  }
}

extension SnoozeTests {
  @Suite struct EndedSnooze {
    @Test(arguments: SnoozableItem.allCases)
    func expiredSnoozeLeavesTheEvaluatedStateAndReason(_ item: SnoozableItem) throws {
      let f = try item.withSnooze(activeSnooze)

      let v = verdict(f, at: snoozeUntil)

      #expect(v.state == Attention.evaluate(session(), f, now: snoozeUntil).state)
      #expect(v.reason == Attention.evaluate(session(), f, now: snoozeUntil).reason)
      #expect(!v.snoozed)
    }

    @Test(arguments: SnoozableItem.allCases)
    func expiredSnoozeNotesTheEndTime(_ item: SnoozableItem) throws {
      let v = verdict(try item.withSnooze(activeSnooze), at: snoozeUntil)

      #expect(v.snoozeNote == note())
    }

    @Test(arguments: SnoozableItem.allCases)
    func wokenSnoozeLeavesTheEvaluatedStateAndReason(_ item: SnoozableItem) throws {
      let f = try item.withSnooze(wokenSnooze)

      let v = verdict(f, at: during)

      #expect(v.state == Attention.evaluate(session(), f, now: during).state)
      #expect(v.reason == Attention.evaluate(session(), f, now: during).reason)
      #expect(!v.snoozed)
    }

    @Test(arguments: SnoozableItem.allCases)
    func wokenSnoozeNotesTheEndTimeAndWhy(_ item: SnoozableItem) throws {
      let v = verdict(try item.withSnooze(wokenSnooze), at: during)

      #expect(v.snoozeNote == note(wokeEarly: newPrompt))
    }

    @Test(arguments: [newPrompt, ciFailed, prMerged])
    func wokenNoteNamesEachReason(_ why: String) throws {
      let f = try SnoozableItem.reply.withSnooze(Snooze(until: snoozeUntil, wokeEarly: why))

      #expect(verdict(f, at: during).snoozeNote == "snoozed until \(Wait.formatTime(snoozeUntil)), woke early: \(why)")
    }

    /// The note is a field of its own. The reason that a rule item's title and ref come from stays the same.
    @Test(arguments: SnoozableItem.allCases)
    func endedSnoozeKeepsTheTriageTitleAndRef(_ item: SnoozableItem) throws {
      let plain = try item.itemFacts()
      let snoozed = try item.withSnooze(wokenSnooze)

      let without = try #require(Triage.item(plain, verdict(plain, at: during), kind: .work))
      let with = try #require(Triage.item(snoozed, verdict(snoozed, at: during), kind: .work))

      #expect(with.title == without.title)
      #expect(with.ref == without.ref)
    }

    @Test(arguments: SnoozableItem.allCases)
    func endedSnoozeKeepsTheReasonOfTheUnsnoozedItem(_ item: SnoozableItem) throws {
      let plain = try item.itemFacts()

      #expect(verdict(try item.withSnooze(wokenSnooze), at: during).reason == verdict(plain, at: during).reason)
    }
  }
}

extension SnoozeTests {
  @Suite struct OutsideTheInbox {
    @Test(arguments: nonInboxStates, [activeSnooze, wokenSnooze, Snooze(until: 10, wokeEarly: nil)])
    func nonInboxVerdictIsUnchanged(_ state: AttentionState, _ snooze: Snooze) {
      var f = SessionFacts()
      f.snooze = snooze

      let v = Attention.snoozed(Verdict(state: state, reason: "r"), f, now: during)

      #expect(v == Verdict(state: state, reason: "r"))
      #expect(!v.snoozed)
      #expect(v.snoozeNote == nil)
    }

    @Test func doneSessionWithAnActiveSnoozeIsDone() throws {
      var f = facts(turn("Done."))
      f.snooze = activeSnooze

      let v = verdict(f, session(done: true), at: during)

      #expect(v == Verdict(state: .done, reason: "marked done"))
      #expect(!v.snoozed)
    }

    @Test func workingSessionWithAnActiveSnoozeIsWorking() {
      let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), snoozeEvent(1)])

      let v = verdict(f, at: during)

      #expect(v.state == .working)
      #expect(!v.snoozed)
    }

    @Test func waitingSessionWithAnEndedSnoozeHasNoNote() {
      let f = facts(turn("Done.") + [snoozeEvent()])

      let v = verdict(f, session(wait: "the deploy of #42"), at: after)

      #expect(v == Verdict(state: .waiting, reason: "the deploy of #42"))
      #expect(v.snoozeNote == nil)
    }
  }
}

// MARK: The Acknowledge layer runs first

extension SnoozeTests {
  @Suite struct WithAnAcknowledgment {
    func acknowledgedFacts(snooze: Snooze?) -> SessionFacts {
      var f = facts(turn("Done.") + [event("ack", 2, ["state": "needs_you", "reason": .string(readTheReply)])])
      f.snooze = snooze
      return f
    }

    @Test func activeAcknowledgmentAndActiveSnoozeIsWaitingAndAcknowledged() {
      let v = verdict(acknowledgedFacts(snooze: Snooze(until: snoozeUntil, wokeEarly: nil)), at: during)

      #expect(v == Verdict(state: .waiting, reason: readTheReply))
      #expect(v.acknowledged)
    }

    /// The Acknowledge layer already moved the verdict out of the Inbox, so the snooze layer leaves it alone.
    @Test func activeAcknowledgmentAndActiveSnoozeIsNotMarkedSnoozed() {
      let v = verdict(acknowledgedFacts(snooze: Snooze(until: snoozeUntil, wokeEarly: nil)), at: during)

      #expect(!v.snoozed)
    }

    @Test func activeAcknowledgmentAndEndedSnoozeHasNoNote() {
      let v = verdict(acknowledgedFacts(snooze: Snooze(until: snoozeUntil, wokeEarly: newPrompt)), at: during)

      #expect(v.acknowledged)
      #expect(v.snoozeNote == nil)
    }

    @Test func expiredAcknowledgmentAndActiveSnoozeIsSnoozedWithTheRecheckReason() {
      let t = 2 + acknowledgedMs
      let f = acknowledgedFacts(snooze: Snooze(until: 10 * acknowledgedMs, wokeEarly: nil))

      let v = verdict(f, at: t)

      #expect(v.state == .waiting)
      #expect(v.snoozed)
      #expect(!v.acknowledged)
      #expect(v.reason == "\(readTheReply) (acknowledged \(Wait.formatTime(2)), time to recheck)")
    }

    @Test func expiredAcknowledgmentAndEndedSnoozeIsInTheInboxWithTheRecheckReasonAndTheNote() {
      let t = 2 + acknowledgedMs
      let f = acknowledgedFacts(snooze: Snooze(until: snoozeUntil, wokeEarly: nil))

      let v = verdict(f, at: t)

      #expect(v.state == .needsYou)
      #expect(v.reason == "\(readTheReply) (acknowledged \(Wait.formatTime(2)), time to recheck)")
      #expect(v.snoozeNote == note())
    }
  }
}

// MARK: Early wake (Risk 1)

/// Every early-wake shape, folded through `SessionFacts.apply`.
extension SnoozeTests {
  @Suite struct EarlyWake {
    // A new prompt

    @Test func permissionPromptThatOpensWhileSnoozedWakesIt() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "touch x"]), event("PreToolUse", 4, touchCall),
          touchRequest(5, 5),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test func questionThatOpensWhileSnoozedWakesIt() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "pick"]), event("PreToolUse", 4, ask()),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test func questionRequestThatOpensWhileSnoozedWakesIt() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), Event(id: 9, session: "s1", t: 3, kind: "PermissionRequest", data: .object(ask(id: nil))),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    /// A send card opens no permission prompt or question.
    @Test func cardThatOpensWhileSnoozedWakesIt() throws {
      let f = facts(turn("Done.") + [snoozeEvent(), sendPending()])

      try #require(!f.cards.isEmpty)
      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    /// A prompt that only a Notification reported has no card and no PermissionRequest.
    @Test func notificationPromptThatOpensWhileSnoozedWakesIt() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "go"]),
          event("PreToolUse", 4, tool("Bash", ["command": "ls"], id: "b1")),
          event(
            "Notification", 5, ["notification_type": "permission_prompt", "message": "Claude needs your permission"]),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test func promptThatWasOpenAtSnoozeTimeDoesNotWakeIt() {
      let f = facts(
        promptTurn(touchCall, touch) + [
          snoozeEvent(3), event("PreToolUse", 4, tool("Read", ["file_path": "/a"], id: "r1")),
          event("Notification", 5, ["notification_type": "sb_test"]),
        ])

      expectNoWake(f)
      #expect(f.snooze?.isActive(at: during) == true)
    }

    @Test func questionThatWasOpenAtSnoozeTimeDoesNotWakeIt() {
      let f = facts(
        [event("UserPromptSubmit", 0, ["prompt": "pick"]), event("PreToolUse", 1, ask())] + [
          snoozeEvent(2), event("PreToolUse", 3, tool("Read", ["file_path": "/a"], id: "r1")),
        ])

      expectNoWake(f)
    }

    @Test func sameToolAskingAgainAfterItsPromptClosedWakesIt() {
      let f = facts(
        promptTurn(touchCall, touch) + [
          snoozeEvent(3), event("PostToolUse", 4, touchCall),
          event("PreToolUse", 5, tool("Bash", ["command": "touch x"], id: "b2")), touchRequest(7, 6),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test func sameQuestionAskedAgainWakesIt() {
      let f = facts(
        [event("UserPromptSubmit", 0, ["prompt": "pick"]), event("PreToolUse", 1, ask())] + [
          snoozeEvent(2), event("PostToolUse", 3, ask()), event("PreToolUse", 4, ask(id: "q2")),
        ])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test func subagentPermissionRequestDoesNotWakeIt() {
      var request = touch
      request["agent_id"] = "a1"

      let f = facts(
        [event("UserPromptSubmit", 0, ["prompt": "go"]), snoozeEvent(1)] + [
          Event(id: 9, session: "s1", t: 3, kind: "PermissionRequest", data: .object(request))
        ])

      expectNoWake(f)
    }

    // A failed CI run

    @Test(arguments: ["PENDING", "SUCCESS"])
    func checksThatFailAfterPendingOrPassingWakeIt(_ before: String) throws {
      let f = try prFacts(
        mergeablePR(checks: before), then: [snoozeEvent(3), try prEvent(4, mergeablePR(checks: "FAILURE"))])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func checksThatErrorWakeIt() throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, mergeablePR(checks: "ERROR"))])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func depotFailureOnTheHeadWithoutARollupFailureWakesIt() throws {
      var failing = mergeablePR(checks: "PENDING")
      failing.depot = failedDepotRun()

      let f = try prFacts(mergeablePR(checks: "PENDING"), then: [snoozeEvent(3), try prEvent(4, failing)])

      try #require(f.pr?.checksFailed == false)
      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func depotFailureOnAnOlderHeadDoesNotWakeIt() throws {
      var pr = mergeablePR(checks: "PENDING")
      pr.depot = failedDepotRun(on: "older")

      let f = try prFacts(mergeablePR(checks: "PENDING"), then: [snoozeEvent(3), try prEvent(4, pr)])

      expectNoWake(f)
    }

    @Test func checksThatWereFailingAtSnoozeTimeDoNotWakeItWhenReadAgain() throws {
      var retitled = mergeablePR(checks: "FAILURE")
      retitled.title = "a new title"

      let f = try prFacts(
        mergeablePR(checks: "FAILURE"),
        then: [snoozeEvent(3), try prEvent(4, mergeablePR(checks: "FAILURE")), try prEvent(5, retitled)])

      expectNoWake(f)
      #expect(f.snooze?.isActive(at: during) == true)
    }

    @Test func checksThatFailAgainAfterPassingWakeIt() throws {
      let f = try prFacts(
        mergeablePR(checks: "FAILURE"),
        then: [
          snoozeEvent(3), try prEvent(4, mergeablePR(checks: "SUCCESS")),
          try prEvent(5, mergeablePR(checks: "FAILURE")),
        ])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func pushWhoseNewHeadFailsAfterRunningWakesIt() throws {
      let f = try prFacts(
        mergeablePR(checks: "FAILURE"),
        then: [
          snoozeEvent(3), try prEvent(4, mergeablePR(headSha: "pushed", checks: "PENDING")),
          try prEvent(5, mergeablePR(headSha: "pushed", checks: "FAILURE")),
        ])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func pushWhoseNewHeadFailsAfterPassingWakesIt() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [snoozeEvent(3), try prEvent(4, mergeablePR(headSha: "pushed", checks: "FAILURE"))])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    /// `ciFailed` never went from false to true, so the guard's property says no wake.
    @Test func pushThatReadsFailingWithoutARunBetweenDoesNotWakeIt() throws {
      let f = try prFacts(
        mergeablePR(checks: "FAILURE"),
        then: [snoozeEvent(3), try prEvent(4, mergeablePR(headSha: "pushed", checks: "FAILURE"))])

      expectNoWake(f)
    }

    @Test func checksThatPassDoNotWakeIt() throws {
      let f = try prFacts(
        mergeablePR(checks: "PENDING"), then: [snoozeEvent(3), try prEvent(4, mergeablePR(checks: "SUCCESS"))])

      expectNoWake(f)
    }

    // The PR merging

    @Test func prThatMergesWakesIt() throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, samplePR(state: .merged))])

      #expect(f.snooze?.wokeEarly == prMerged)
    }

    @Test func prThatWasMergedAtSnoozeTimeDoesNotWakeItWhenReadAgain() throws {
      var retitled = samplePR(state: .merged)
      retitled.title = "a new title"

      let f = try prFacts(
        samplePR(state: .merged),
        then: [snoozeEvent(3), try prEvent(4, samplePR(state: .merged)), try prEvent(5, retitled)])

      expectNoWake(f)
    }

    @Test func prThatClosesWithoutAMergeDoesNotWakeIt() throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, samplePR(state: .closed))])

      expectNoWake(f)
    }

    @Test func firstPREventAfterTheSnoozeThatShowsAMergedPRWakesIt() throws {
      let f = facts(turn("Done.") + [snoozeEvent(), try prEvent(3, samplePR(state: .merged))])

      #expect(f.snooze?.wokeEarly == prMerged)
    }

    @Test func prEventThatDropsThePRDoesNotWakeIt() throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, nil)])

      expectNoWake(f)
    }

    /// The order of the rules names the wake when two hold on one event.
    @Test func eventThatFailsTheChecksAndMergesNamesTheFailure() throws {
      let f = try prFacts(
        mergeablePR(), then: [snoozeEvent(3), try prEvent(4, samplePR(state: .merged, checks: "FAILURE"))])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    // Not a break

    @Test func replyThatAsksAQuestionInItsTextDoesNotWakeIt() {
      let f = facts(turn("Done.") + [snoozeEvent()] + turn("Which database, Postgres or SQLite?", start: 3))

      expectNoWake(f)
      #expect(f.snooze?.isActive(at: during) == true)
    }

    @Test func newTurnDoesNotWakeIt() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "more"])])

      expectNoWake(f)
      #expect(f.snooze?.isActive(at: during) == true)
    }

    @Test func waitThatResolvesWithNotifyDoesNotWakeIt() throws {
      let wait = waitOn(.manual, note: "ask Alex", then: .notify)
      let f = facts(turn("Done.") + [snoozeEvent(), try resolved(wait, "time to recheck", 3)])

      expectNoWake(f)
    }

    @Test func waitThatResolvesWithNotifyStaysHeld() throws {
      let wait = waitOn(.manual, note: "ask Alex", then: .notify)
      let f = facts(turn("Done.") + [snoozeEvent(), try resolved(wait, "time to recheck", 3)])
      try #require(AttentionState.inbox.contains(Attention.evaluate(session(), f, now: during).state))

      let v = verdict(f, at: during)

      #expect(v.state == .waiting)
      #expect(v.snoozed)
    }

    /// No event marks a wait going overdue, so only the time moves.
    @Test func overdueWaitStaysHeld() throws {
      let recheck: Int64 = 2 * 3_600_000
      var wait = waitOn(.ci, pr: Wait.PullRequest(number: 1))
      wait.recheck = recheck
      let s = withWaits([wait])
      let f = facts(turn("Done.") + [snoozeEvent(until: 10 * recheck)])
      try #require(Attention.evaluate(s, f, now: recheck).state == .needsYou)

      let v = verdict(f, s, at: recheck)

      #expect(v.state == .waiting)
      #expect(v.snoozed)
    }

    @Test func conflictDoesNotWakeIt() throws {
      let f = try prFacts(
        mergeablePR(), then: [snoozeEvent(3), try prEvent(4, mergeablePR(mergeable: .conflicting))])

      expectNoWake(f)
    }

    @Test func requestedChangesDoNotWakeIt() throws {
      var reviewed = mergeablePR()
      reviewed.reviewDecision = .changesRequested
      reviewed.verdicts = [sampleVerdict("alice", "CHANGES_REQUESTED")]

      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, reviewed)])

      expectNoWake(f)
    }

    @Test func reviewCommentDoesNotWakeIt() throws {
      let comment = PRComment(id: "IC_1", author: "alice", createdAt: "2026-10-25T00:00:00Z", body: "Looks off.")

      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(4, mergeablePR(), comments: [comment])])

      expectNoWake(f)
    }

    @Test func prThatBecomesReadyToMergeDoesNotWakeIt() throws {
      let f = try prFacts(
        mergeablePR(mergeable: .conflicting), then: [snoozeEvent(3), try prEvent(4, mergeablePR())])

      expectNoWake(f)
    }

    @Test func doneEventDoesNotWakeIt() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("done", 3)])

      expectNoWake(f)
    }

    // Only while the snooze is active at the event's time

    @Test(arguments: [snoozeUntil, snoozeUntil + 1])
    func promptAtOrAfterTheEndDoesNotWakeIt(_ t: Int64) {
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "go"]), touchRequest(9, t)])

      expectNoWake(f)
    }

    @Test func promptAMillisecondBeforeTheEndWakesIt() {
      let t = snoozeUntil - 1
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("UserPromptSubmit", 3, ["prompt": "go"]), touchRequest(9, t)])

      #expect(f.snooze?.wokeEarly == newPrompt)
    }

    @Test(arguments: [snoozeUntil, snoozeUntil + 1])
    func ciFailureAtOrAfterTheEndDoesNotWakeIt(_ t: Int64) throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(t, mergeablePR(checks: "FAILURE"))])

      expectNoWake(f)
    }

    @Test(arguments: [snoozeUntil, snoozeUntil + 1])
    func mergeAtOrAfterTheEndDoesNotWakeIt(_ t: Int64) throws {
      let f = try prFacts(mergeablePR(), then: [snoozeEvent(3), try prEvent(t, samplePR(state: .merged))])

      expectNoWake(f)
    }

    @Test func promptAfterTheEndNotesOnlyTheEndTime() throws {
      let t = snoozeUntil + 10
      let f = facts(turn("Done.") + [snoozeEvent(), touchRequest(9, t)])

      #expect(verdict(f, at: t + 1).snoozeNote == note())
    }

    /// The wake happened before the end, so the note says why even after the end time passes.
    @Test func wakeBeforeTheEndKeepsItsReasonPastTheEnd() {
      let f = facts(turn("Done.") + [snoozeEvent(), touchRequest(9, 3)])

      #expect(verdict(f, at: after).snoozeNote == note(wokeEarly: newPrompt))
    }

    @Test func promptAfterUnsnoozeLeavesNoRecord() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("unsnooze", 3), touchRequest(9, 4)])

      #expect(f.snooze == nil)
    }

    @Test func ciFailureAfterUnsnoozeLeavesNoRecord() throws {
      let f = try prFacts(
        mergeablePR(), then: [snoozeEvent(3), event("unsnooze", 4), try prEvent(5, mergeablePR(checks: "FAILURE"))])

      #expect(f.snooze == nil)
    }

    @Test func secondWakeKeepsTheFirstReason() throws {
      let f = try prFacts(
        mergeablePR(),
        then: [
          snoozeEvent(3), try prEvent(4, mergeablePR(checks: "FAILURE")), try prEvent(5, samplePR(state: .merged)),
        ])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    @Test func promptAfterACIWakeKeepsTheCIReason() throws {
      let f = try prFacts(
        mergeablePR(), then: [snoozeEvent(3), try prEvent(4, mergeablePR(checks: "FAILURE")), touchRequest(9, 5)])

      #expect(f.snooze?.wokeEarly == ciFailed)
    }

    // Replay

    @Test func replayingTheSameEventsGivesTheSameRecord() throws {
      let events = [
        event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
        try prEvent(2, mergeablePR()), snoozeEvent(3), try prEvent(4, mergeablePR(checks: "FAILURE")),
      ]

      #expect(facts(events).snooze == facts(events).snooze)
      #expect(facts(events).snooze?.wokeEarly == ciFailed)
    }

    /// sbd restores a snapshot and then applies the events after it.
    @Test func snapshotThenTheRemainingEventsGivesTheSameRecordAsAFullReplay() throws {
      let head = turn("Done.") + [snoozeEvent()]
      let tail = [
        event("UserPromptSubmit", 3, ["prompt": "touch x"]), event("PreToolUse", 4, touchCall), touchRequest(5, 5),
      ]
      var restored = try JSONCoding.convert(JSON(encoding: facts(head)), to: SessionFacts.self)

      for e in tail { restored.apply(e) }

      #expect(restored.snooze == facts(head + tail).snooze)
      #expect(restored.snooze?.wokeEarly == newPrompt)
    }
  }
}

// MARK: When the record ends (Decision 7)

extension SnoozeTests {
  @Suite struct RecordClearing {
    /// A working session whose snooze a permission prompt woke, as card 3.
    func wokenMidTurn() -> [Event] {
      [
        event("UserPromptSubmit", 0, ["prompt": "go"]), snoozeEvent(1), event("PreToolUse", 2, touchCall),
        touchRequest(3, 3),
      ]
    }

    @Test func wokenMidTurnPreconditionHasTheWake() {
      #expect(facts(wokenMidTurn()).snooze?.wokeEarly == newPrompt)
    }

    @Test func answeringTheWokenPromptInThePaneClearsTheRecord() {
      let f = facts(
        wokenMidTurn() + [
          event("dialog_closed", 4, ["card": 3, "allowed": true]), event("PostToolUse", 5, touchCall),
          event("Stop", 6, ["last_assistant_message": "Ran touch x"]),
        ])

      #expect(f.snooze == nil)
    }

    @Test func replyAfterThePaneAnswerHasNoNote() {
      let f = facts(
        wokenMidTurn() + [
          event("dialog_closed", 4, ["card": 3, "allowed": true]), event("PostToolUse", 5, touchCall),
          event("Stop", 6, ["last_assistant_message": "Ran touch x"]),
        ])

      let v = verdict(f, at: 7)

      #expect(v.state == .needsYou)
      #expect(v.snoozeNote == nil)
    }

    @Test func answeringTheWokenPromptThroughItsCardClearsTheRecord() {
      let f = facts(
        wokenMidTurn() + [
          event("answered", 4, ["card": 3, "behavior": "allow"]), event("card_closed", 5, ["card": 3]),
          event("PostToolUse", 6, touchCall), event("Stop", 7, ["last_assistant_message": "Ran touch x"]),
        ])

      #expect(f.snooze == nil)
      #expect(verdict(f, at: 8).snoozeNote == nil)
    }

    @Test(arguments: [
      event("answered", 4, ["card": 3, "behavior": "allow"]), event("card_closed", 4, ["card": 3]),
      event("dialog_closed", 4, ["card": 3, "allowed": true]),
    ])
    func eachAnswerEventAloneClearsTheWokenRecord(_ answer: Event) {
      #expect(facts(wokenMidTurn() + [answer]).snooze == nil)
    }

    @Test func snoozeThatEndsByTimeMidTurnKeepsItsNoteOnTheReply() {
      let f = facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]), snoozeEvent(1, until: 100),
        event("Stop", 200, ["last_assistant_message": "Done."]),
      ])

      let v = verdict(f, at: 300)

      #expect(v.state == .needsYou)
      #expect(v.snoozeNote == note(until: 100))
    }

    @Test func userMessageAfterTheItemCameBackClearsTheNote() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("sent", after, ["text": "again"]),
          event("UserPromptSubmit", after + 1, ["prompt": "again"]),
        ])

      #expect(f.snooze == nil)
    }

    @Test func userSentEventAloneClearsTheEndedRecord() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("sent", after, ["text": "again"])])

      #expect(f.snooze == nil)
    }

    @Test func sbdMessageAloneLeavesTheEndedRecord() {
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("sent", after, ["text": "Switchboard: go on", "by": "sbd"])])

      #expect(f.snooze != nil)
    }

    @Test func turnThatSbdsMessageStartsClearsTheEndedRecord() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("sent", after, ["text": "Switchboard: go on", "by": "sbd"]),
          event("UserPromptSubmit", after + 1, ["prompt": "Switchboard: go on"]),
        ])

      #expect(f.snooze == nil)
    }

    @Test func acknowledgingTheItemThatCameBackClearsTheNote() {
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("ack", after, ["state": "needs_you", "reason": .string(readTheReply)])])

      #expect(f.snooze == nil)
    }

    @Test(arguments: [
      event("Stop", after, ["last_assistant_message": "Done again."]), event("unack", after),
      event("wait", after, ["wait": ["id": "w1", "kind": "manual", "created": 0, "then": "notify"]]),
      event("done", after), event("Notification", after, ["notification_type": "sb_test"]),
    ])
    func otherEventsLeaveTheEndedRecord(_ e: Event) {
      let f = facts(turn("Done.") + [snoozeEvent(), e])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func replyAfterTheItemCameBackKeepsTheNote() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("Stop", after, ["last_assistant_message": "Done again."])])

      #expect(verdict(f, at: after + 1).snoozeNote == note())
    }

    // An active record

    @Test func userMessageLeavesTheActiveRecord() {
      let f = facts(
        turn("Done.") + [
          snoozeEvent(), event("sent", 3, ["text": "more"]), event("UserPromptSubmit", 4, ["prompt": "more"]),
        ])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func newTurnLeavesTheActiveRecord() {
      let f = facts(turn("Done.") + [snoozeEvent(), event("PreToolUse", 3, tool("Bash", ["command": "ls"], id: "t1"))])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    /// The prompt was open before the snooze, so it didn't wake it, and its answer must not clear it.
    @Test(arguments: [
      event("answered", 4, ["card": 3, "behavior": "allow"]), event("card_closed", 4, ["card": 3]),
      event("dialog_closed", 4, ["card": 3, "allowed": true]),
    ])
    func answeringAPromptLeavesTheActiveRecord(_ answer: Event) {
      let f = facts(promptTurn(touchCall, touch) + [snoozeEvent(3), answer])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func acknowledgingLeavesTheActiveRecord() {
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("ack", 3, ["state": "needs_you", "reason": .string(readTheReply)])])

      #expect(f.snooze == Snooze(until: snoozeUntil, wokeEarly: nil))
    }

    @Test func activeRecordStillHoldsAfterTheUserMessagesTheSession() {
      let f = facts(
        turn("Done.") + [snoozeEvent(), event("sent", 3, ["text": "more"])] + turn("Done: more", start: 4))

      let v = verdict(f, at: during)

      #expect(v.state == .waiting)
      #expect(v.snoozed)
    }
  }
}

// MARK: sbd's own rules ignore the snooze (Risk 3)

extension SnoozeTests {
  @Suite struct DisplayOnly {
    @Test(arguments: SnoozableItem.allCases)
    func evaluateGivesTheSameVerdictWithAndWithoutTheSnooze(_ item: SnoozableItem) throws {
      let plain = try item.itemFacts()
      let snoozed = try item.withSnooze(activeSnooze)

      let a = Attention.evaluate(session(), plain, now: during)
      let b = Attention.evaluate(session(), snoozed, now: during)

      #expect(a == b)
      #expect(!b.snoozed)
      #expect(b.snoozeNote == nil)
    }

    @Test(arguments: SnoozableItem.allCases)
    func trackKeepsTheRulesState(_ item: SnoozableItem) throws {
      var snoozed = try item.withSnooze(activeSnooze)

      let v = Attention.track(session(), &snoozed, now: during)

      #expect(AttentionState.inbox.contains(v.state))
      #expect(snoozed.lastState == v.state)
    }

    @Test(arguments: ["snooze", "unsnooze"])
    func aSnoozeEventLeavesAStaleSessionStale(_ kind: String) {
      let late = 3 * Attention.staleAfterMs
      let e = kind == "snooze" ? snoozeEvent(late, until: late + snoozeUntil) : event("unsnooze", late)
      let plain = facts(turn("Done."))

      let v = Attention.evaluate(session(), facts(turn("Done.") + [e]), now: late + 1)

      #expect(v.state == .stale)
      #expect(v == Attention.evaluate(session(), plain, now: late + 1))
    }

    @Test func evaluateOfAWorkingSessionIgnoresTheSnooze() {
      let plain = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
      var snoozed = plain
      snoozed.snooze = activeSnooze

      #expect(Attention.evaluate(session(), snoozed, now: during) == Attention.evaluate(session(), plain, now: during))
    }
  }
}

// MARK: The summary's line

extension SnoozeTests {
  @Suite struct InboxTitle {
    func summary(reason: String = readTheReply, triage: TriageItem? = nil, note: String? = nil) -> SessionSummary {
      var s = SessionSummary(
        id: "s1", name: "t", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "uuid", state: .needsYou,
        reason: reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
        waits: [], notes: [])
      s.triage = triage
      s.snoozeNote = note
      return s
    }

    func conflictItem() throws -> TriageItem {
      let f = try prFacts(mergeablePR(mergeable: .conflicting))
      return try #require(Triage.item(f, Attention.evaluate(session(), f, now: during), kind: .work))
    }

    @Test func lineWithoutATriageItemOrNoteIsTheReason() {
      #expect(summary().inboxTitle == readTheReply)
    }

    @Test func lineWithoutATriageItemAddsTheNoteToTheReason() {
      #expect(summary(note: note()).inboxTitle == "\(readTheReply) (\(note()))")
    }

    @Test func lineWithATriageItemIsItsTitle() throws {
      let item = try conflictItem()

      #expect(summary(triage: item).inboxTitle == item.title)
    }

    @Test func lineWithATriageItemAddsTheNoteToItsTitle() throws {
      let item = try conflictItem()
      let woke = note(wokeEarly: ciFailed)

      #expect(summary(triage: item, note: woke).inboxTitle == "\(item.title) (\(woke))")
    }

    @Test func noteIsNotCutWithALongTitle() {
      let long = String(repeating: "x", count: 3 * Triage.titleLength)

      #expect(summary(reason: long, note: note()).inboxTitle.hasSuffix("(\(note()))"))
    }
  }
}
