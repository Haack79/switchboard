import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// 2026-11-15 17:00 UTC.
private let snoozeEnd = Date(timeIntervalSince1970: 1_794_762_000)
private let snoozeNote = "snoozed until 2026-11-15 09:00"

/// A session whose Inbox item an active snooze holds in Waiting, as sbd shows it.
private func snoozedItem(_ id: String) -> SessionSummary {
  var s = needsItem(id, state: .waiting)
  s.snoozedUntil = Int64(snoozeEnd.timeIntervalSince1970 * 1000)
  return s
}

/// A session whose item came back to the Inbox after its snooze ended.
private func wokenItem(_ id: String) -> SessionSummary {
  var s = needsItem(id)
  s.snoozeNote = snoozeNote
  return s
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelSnooze {
  @Test func snoozeSendsSnoozeWithTheSessionAndAnISOTime() async {
    let sent = await firstRequest { $0.snooze("a", until: snoozeEnd) }

    #expect(sent.op == "snooze")
    #expect(sent.args == ["session": "a", "until": "2026-11-15T17:00:00Z"])
  }

  /// sbd reads `until` with `Wait.parseTime`, which refuses fractional seconds.
  @Test func snoozeUntilADateWithFractionalSecondsSendsATimeSbdReads() async throws {
    let end = snoozeEnd.addingTimeInterval(0.25)

    let sent = await firstRequest { $0.snooze("a", until: end) }

    let text = try #require(sent.args["until"]?.string)
    let parsed = try #require(Wait.parseTime(text, now: 0))
    #expect(abs(Double(parsed) / 1000 - end.timeIntervalSince1970) < 1)
  }

  @Test func unsnoozeSendsUnsnoozeWithTheSession() async {
    let sent = await firstRequest { $0.unsnooze("a") }

    #expect(sent.op == "unsnooze")
    #expect(sent.args == ["session": "a"])
  }

  @Test func ignoresAnUnsnoozeWhileASnoozeOfTheSameSessionRuns() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.snooze("a", until: snoozeEnd)
    model.unsnooze("a")
    #expect(model.snoozing == ["a"])
    for _ in 0..<100 where sent.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 1)
  }

  @Test func ignoresASecondSnoozeWhileTheFirstRuns() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.snooze("a", until: snoozeEnd)
    model.snooze("a", until: snoozeEnd.addingTimeInterval(3600))
    #expect(model.snoozing == ["a"])
    for _ in 0..<100 where sent.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 1)
  }

  @Test func snoozingOneSessionLeavesAnotherFree() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.snooze("a", until: snoozeEnd)
    model.unsnooze("b")
    #expect(model.snoozing == ["a", "b"])
    for _ in 0..<100 where sent.value < 2 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 2)
  }

  @Test func theSnoozingSetEmptiesWhenTheRequestFinishes() async throws {
    let model = offlineModel()
    model.send = { _, _ in .null }

    model.snooze("a", until: snoozeEnd)
    for _ in 0..<100 where !model.snoozing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.snoozing.isEmpty)
  }

  @Test func theSnoozingSetEmptiesWhenTheRequestFails() async throws {
    struct Refused: Error {}
    let model = offlineModel()
    model.send = { _, _ in throw Refused() }

    model.unsnooze("a")
    for _ in 0..<100 where !model.snoozing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.snoozing.isEmpty)
  }

  private func inboxModel(focus: String) -> BoardModel {
    let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c")])
    model.send = { _, _ in .null }
    model.show(.inbox)
    model.inboxFocus = focus
    return model
  }

  @Test func theOpenSnoozePickerCountsAsASheet() throws {
    let model = offlineModel()
    try #require(!model.presentingSheet)
    model.pickingSnoozeTime = "a"
    #expect(model.presentingSheet)
    model.pickingSnoozeTime = nil
    #expect(!model.presentingSheet)
  }

  @Test func snoozingTheCurrentItemFocusesTheNextOne() {
    let model = inboxModel(focus: "b")
    model.snooze("b", until: snoozeEnd)
    #expect(model.inboxFocus == "c")
  }

  @Test func snoozingAnotherItemLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.snooze("c", until: snoozeEnd)
    #expect(model.inboxFocus == "b")
  }

  @Test func unsnoozeLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.unsnooze("b")
    #expect(model.inboxFocus == "b")
  }

  @Test func unsnoozeDoesNotNotifyAboutTheRestoredItem() async throws {
    let model = appliedModel([snoozedItem("a")])
    let restored = try JSON(encoding: needsItem("a"))
    model.send = { _, _ in restored }

    model.unsnooze("a")
    for _ in 0..<100 where !model.snoozing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.sessionsToNotify([needsItem("a")]).isEmpty)
  }
}

/// How the app reads a summary that a snooze holds or that came back when it ended.
@MainActor
@Suite struct SnoozedSummaries {
  @Test func snoozedSummaryDoesNotNeedYou() {
    #expect(!Triage.needsYou(snoozedItem("a")))
  }

  @Test func snoozedSummaryLeavesTheNeedsYouCount() {
    let model = appliedModel([snoozedItem("a"), needsItem("b")])

    #expect(model.needsUser.map(\.id) == ["b"])
  }

  @Test func wokenSummaryNeedsYou() {
    #expect(Triage.needsYou(wokenItem("a")))
  }

  @Test func wokenSummaryNotifies() {
    let model = appliedModel([snoozedItem("a")])

    #expect(model.sessionsToNotify([wokenItem("a")]).map(\.id) == ["a"])
  }

  @Test func snoozingAnItemDoesNotNotify() {
    let model = appliedModel([needsItem("a")])

    #expect(model.sessionsToNotify([snoozedItem("a")]).isEmpty)
  }

  @Test func itemThatStaysSnoozedDoesNotNotify() {
    let model = appliedModel([snoozedItem("a")])

    #expect(model.sessionsToNotify([snoozedItem("a")]).isEmpty)
  }

  /// The menu bar and the notification body show this line.
  @Test(arguments: [TriageSource.summary, .card, .session, .rule, .fallback, .report])
  func inboxLineAddsTheNoteOfASnoozeThatEnded(_ source: TriageSource) {
    var s = wokenItem("a")
    s.triage?.source = source

    #expect(offlineModel().inboxLine(s) == "Pick one (\(snoozeNote))")
  }

  @Test func inboxLineAddsTheNoteToTheReasonOfASessionWithoutAnItem() {
    var s = wokenItem("a")
    s.triage = nil
    s.reason = "waiting on a review"

    #expect(offlineModel().inboxLine(s) == "waiting on a review (\(snoozeNote))")
  }

  @Test func inboxLineWithoutANoteIsTheTitle() {
    #expect(offlineModel().inboxLine(needsItem("a")) == "Pick one")
  }
}

/// sbd snoozes only a work session that isn't marked done, so the menus offer Snooze only for one.
@Suite struct SnoozeMenuEligibility {
  @Test func workSessionCanSnooze() {
    #expect(needsItem("a").canSnooze)
  }

  @Test func sessionMarkedDoneCannotSnooze() {
    var s = needsItem("a")
    s.markedDone = true

    #expect(!s.canSnooze)
  }

  @Test func managerCannotSnooze() {
    #expect(!needsItem("m", manager: true).canSnooze)
  }

  @Test func groupChatCannotSnooze() {
    #expect(!chatItem("c", group: "g").canSnooze)
  }

  @Test func operatorCannotSnooze() {
    var s = needsItem("o")
    s.kind = .operator

    #expect(!s.canSnooze)
  }
}
