import Testing

@testable import SwitchboardCore

/// `SessionSummary.reasonLine`, which `sb ls`, `sb get`, and the brief text line print.
@Suite struct ReasonLineTests {
  private static let until: Int64 = 1_795_000_000_000

  private func session(reason: String = "Needs a review") -> SessionSummary {
    SessionSummary(
      id: "s1", name: "fix-cache", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c1", state: .needsYou,
      reason: reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
      waits: [], notes: [])
  }

  @Test func aPlainSessionsReasonLineIsItsReason() {
    let s = session()

    #expect(s.reasonLine == "Needs a review")
  }

  @Test func anAcknowledgedSessionsReasonLineSaysSo() {
    var s = session()
    s.acknowledged = true

    #expect(s.reasonLine == "Needs a review (acknowledged)")
  }

  @Test func aSessionThatIsNotAcknowledgedHasNoMark() {
    var s = session()
    s.acknowledged = false

    #expect(s.reasonLine == "Needs a review")
  }

  @Test func aSnoozedSessionsReasonLineEndsWithTheSnoozeLabel() {
    var s = session()
    s.snoozedUntil = Self.until

    #expect(s.reasonLine == "Needs a review (\(Snooze.label(until: Self.until)))")
  }

  @Test func aSessionWhoseSnoozeEndedShowsTheSnoozeNote() {
    var s = session()
    s.snoozeNote = "snoozed until 2026-11-15 09:00"

    #expect(s.reasonLine == "Needs a review (snoozed until 2026-11-15 09:00)")
  }

  @Test func anAcknowledgedSnoozedSessionShowsBothMarksInOrder() {
    var s = session()
    s.acknowledged = true
    s.snoozedUntil = Self.until

    #expect(s.reasonLine == "Needs a review (acknowledged) (\(Snooze.label(until: Self.until)))")
  }
}
