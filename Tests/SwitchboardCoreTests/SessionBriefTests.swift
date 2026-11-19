import Foundation
import Testing

@testable import SwitchboardCore

/// The keys that a brief may hold, and the keys of its `pr` object.
private let briefKeys: Set<String> = [
  "id", "name", "url", "state", "reason", "acknowledged", "snoozedUntil", "pr", "waitLine",
]
private let briefPRKeys: Set<String> = ["number", "repo", "state", "status", "checks"]

/// The keys that the brief and the full JSON share with the same meaning, outside `pr`.
private let sharedKeys = ["id", "name", "url", "state", "acknowledged", "snoozedUntil"]

private let until: Int64 = 1_795_000_000_000

private func sessionSummary(
  id: String = "s1", name: String = "fix-cache", state: AttentionState = .needsYou, reason: String = "Needs a review",
  waits: [Wait] = [], pr: PRSummary? = nil
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: name, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: "c-\(id)", state: state,
    reason: reason, since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
    waits: waits, notes: [], pr: pr)
  s.url = SessionLink.url(for: id).absoluteString
  return s
}

private func briefPR(
  _ number: Int = 18303, repo: String = "PostHog/charts", state: PRState = .open,
  reviewDecision: ReviewDecision? = .approved, checks: String? = "SUCCESS"
) -> PRSummary {
  PRSummary(
    PullRequest(
      id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo,
      title: "Fix the cache", state: state, reviewDecision: reviewDecision, checks: checks))
}

private func ciWait(
  _ number: Int, repository: String? = nil, note: String? = nil, then: Wait.Then = .resume, id: String? = nil
)
  -> Wait
{
  Wait(
    id: id ?? "w\(number)", kind: .ci, pr: Wait.PullRequest(repository: repository, number: number), note: note,
    created: 0, then: then)
}

private func manualWait(_ note: String) -> Wait {
  Wait(id: "wm", kind: .manual, note: note, created: 0, then: .notify)
}

private func targetWait(_ name: String, reaching state: AttentionState = .done) -> Wait {
  Wait(id: "ws", kind: .session, session: Wait.SessionTarget(id: "s9", name: name), state: state, created: 0)
}

private func brief(_ s: SessionSummary) throws -> JSON { try JSON(encoding: SessionBrief(s)) }

private func keys(_ json: JSON?) throws -> Set<String> { Set(try #require(json?.object).keys) }

private func waitLine(_ s: SessionSummary) throws -> String? { try brief(s)["waitLine"]?.string }

/// The wait line, built from `waits` alone so that the parity test does not read it from the code
/// under test. It keeps distinct summaries and cuts each to 80 characters. It adds them while the
/// line, with its "and N more" ending, fits in 200 characters.
private func expectedWaitLine(_ waits: [Wait]) -> String? {
  var texts: [String] = []
  for wait in waits where !texts.contains(wait.summary) { texts.append(wait.summary) }
  texts = texts.map { oneLine($0, max: 80) }
  guard !texts.isEmpty else { return nil }
  for shown in stride(from: texts.count, through: 1, by: -1) {
    let more = texts.count - shown
    let line = texts.prefix(shown).joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "")
    if line.count <= 200 || shown == 1 { return line }
  }
  return nil
}

/// A CI wait whose summary, `CI on org/xxx…#N`, is 46 characters long, so three fit in the line.
private func longCIWait(_ number: Int, id: String? = nil) -> Wait {
  ciWait(number, repository: "org/" + String(repeating: "x", count: 34), id: id)
}

@Suite struct SessionBriefTests {

  // MARK: Keys

  @Test func aSessionWithNoPRAndNoWaitsHasOnlyTheCoreKeys() throws {
    let s = sessionSummary()

    #expect(try keys(brief(s)) == ["id", "name", "url", "state", "reason"])
  }

  @Test func theCoreKeysCopyTheSessionsValues() throws {
    let s = sessionSummary(id: "s7", name: "fix-cache", state: .readyToMerge, reason: "#18303 is ready to merge")

    let json = try brief(s)

    #expect(json["id"] == "s7")
    #expect(json["name"] == "fix-cache")
    #expect(json["url"] == .string(SessionLink.url(for: "s7").absoluteString))
    #expect(json["state"] == "ready_to_merge")
    #expect(json["reason"] == "#18303 is ready to merge")
  }

  @Test func aSessionWithoutAURLHasNoURLKey() throws {
    var s = sessionSummary()
    s.url = nil

    #expect(try !keys(brief(s)).contains("url"))
  }

  @Test func anAcknowledgedSessionCarriesAcknowledged() throws {
    var s = sessionSummary()
    s.acknowledged = true

    #expect(try brief(s)["acknowledged"] == .bool(true))
  }

  @Test func aSnoozedSessionCarriesSnoozedUntil() throws {
    var s = sessionSummary()
    s.snoozedUntil = until

    #expect(try brief(s)["snoozedUntil"] == .number(Double(until)))
  }

  /// The ended-snooze note shows only in the text line, through `reasonLine`.
  @Test func theEndedSnoozeNoteStaysOutOfTheJSON() throws {
    var s = sessionSummary()
    s.snoozeNote = "snoozed until 2026-11-15 09:00"

    #expect(try !keys(brief(s)).contains("snoozeNote"))
  }

  @Test func aBriefRoundTripsThroughJSON() throws {
    var s = sessionSummary(waits: [ciWait(422), manualWait("ask Alex")], pr: briefPR())
    s.acknowledged = true
    s.snoozedUntil = until
    let original = SessionBrief(s)

    let decoded = try JSONCoding.decode(SessionBrief.self, from: try JSONCoding.encode(original))

    #expect(decoded == original)
  }

  // MARK: PR

  struct PRCase: Sendable, CustomTestStringConvertible {
    var state: PRState
    var status: String
    var testDescription: String { state.rawValue }
  }

  @Test(arguments: [
    PRCase(state: .open, status: "Approved"), PRCase(state: .merged, status: "Merged"),
    PRCase(state: .closed, status: "Closed"),
  ])
  func aPRBecomesAnObjectWithItsNumberRepoStateStatusAndChecks(_ c: PRCase) throws {
    let s = sessionSummary(pr: briefPR(18303, repo: "PostHog/charts", state: c.state, checks: "SUCCESS"))

    let got = try #require(try brief(s)["pr"])

    #expect(try keys(got) == briefPRKeys)
    #expect(got["number"] == .number(18303))
    #expect(got["repo"] == "PostHog/charts")
    #expect(got["state"] == .string(c.state.rawValue))
    #expect(got["status"] == .string(c.status))
    #expect(got["checks"] == "SUCCESS")
  }

  @Test func aPRWithoutChecksLeavesOutTheChecksKey() throws {
    let s = sessionSummary(pr: briefPR(checks: nil))

    #expect(try keys(brief(s)["pr"]) == ["number", "repo", "state", "status"])
  }

  // MARK: Waits

  @Test func oneWaitBecomesItsSummary() throws {
    let s = sessionSummary(waits: [ciWait(422, repository: "haacked/switchboard")])

    #expect(try waitLine(s) == "CI on haacked/switchboard#422")
  }

  @Test func twoIdenticalWaitsShowOnce() throws {
    let s = sessionSummary(waits: [ciWait(422, id: "w1"), ciWait(422, id: "w2")])

    #expect(try waitLine(s) == "CI on #422")
  }

  @Test func sevenShortWaitsAllFitInTheLine() throws {
    let s = sessionSummary(waits: (1...7).map { ciWait($0) })

    #expect(try waitLine(s) == "CI on #1; CI on #2; CI on #3; CI on #4; CI on #5; CI on #6; CI on #7")
  }

  @Test func sevenLongWaitsShowWhatFitsIn200CharactersAndCountTheRest() throws {
    let waits = (1...7).map { longCIWait($0) }
    let s = sessionSummary(waits: waits)

    let line = try #require(try waitLine(s))

    #expect(line == waits.prefix(3).map(\.summary).joined(separator: "; ") + "; and 4 more")
    #expect(line.count <= 200)
  }

  /// N counts the distinct texts left after duplicates collapse, not the waits.
  @Test func theMoreCountCountsDistinctTextsOnly() throws {
    let numbers = [1, 1, 2, 3, 4, 5, 6, 6]
    let s = sessionSummary(waits: numbers.enumerated().map { longCIWait($0.element, id: "w\($0.offset)") })

    #expect(try waitLine(s) == (1...3).map { longCIWait($0).summary }.joined(separator: "; ") + "; and 3 more")
  }

  /// Two notes that match in their first 80 characters still count as two waits.
  @Test func repeatsCollapseBeforeTheCut() throws {
    let start = String(repeating: "a", count: 90)
    let s = sessionSummary(waits: [manualWait(start + "1"), manualWait(start + "2")])

    let line = try #require(try waitLine(s))

    #expect(line == [oneLine(start, max: 80), oneLine(start, max: 80)].joined(separator: "; "))
  }

  @Test func aManualWaitsLongMultiLineNoteBecomesOneShortLine() throws {
    let note = "Ask Alex about the cache.\n" + String(repeating: "a", count: 500)
    let s = sessionSummary(waits: [manualWait(note)])

    let line = try #require(try waitLine(s))

    #expect(line == oneLine(note, max: 80))
    #expect(line.count <= 80)
    #expect(!line.contains { $0.isNewline })
    #expect(line.hasPrefix("Ask Alex about the cache. a"))
  }

  /// The brief reads `Wait.summary`, so the note of a wait other than a manual one never appears.
  @Test func aNonManualWaitsNoteStaysOut() throws {
    let s = sessionSummary(waits: [ciWait(422, note: "the operator's long handoff note")])

    #expect(try waitLine(s) == "CI on #422")
  }

  @Test func aSessionWaitReadsTheNameAndTheState() throws {
    let s = sessionSummary(waits: [targetWait("fix-cache", reaching: .done)])

    #expect(try waitLine(s) == "fix-cache to reach Done")
  }

  @Test func aCallerWaitStillShows() throws {
    let s = sessionSummary(waits: [ciWait(422, then: .caller)])

    #expect(try waitLine(s) == "CI on #422")
  }

  @Test func aDateWaitShowsItsTime() throws {
    let s = sessionSummary(waits: [Wait(id: "wd", kind: .date, until: until, created: 0)])

    #expect(try waitLine(s) == "until \(Wait.formatTime(until))")
  }

  // MARK: Reason

  @Test func aLineBreakInTheReasonBecomesASpace() throws {
    let s = sessionSummary(reason: "Needs a review\nfrom Alex")

    #expect(try brief(s)["reason"] == "Needs a review from Alex")
  }

  @Test func aReasonOver200CharactersIsCutTo200EndingInAnEllipsis() throws {
    let s = sessionSummary(reason: String(repeating: "a", count: 250))

    let reason = try #require(try brief(s)["reason"]?.string)

    #expect(reason.count == 200)
    #expect(reason == String(repeating: "a", count: 199) + "…")
  }

  @Test func aReasonOfExactly200CharactersIsUnchanged() throws {
    let text = String(repeating: "a", count: 200)
    let s = sessionSummary(reason: text)

    #expect(try brief(s)["reason"] == .string(text))
  }

  // MARK: Size

  /// The longest reason, many long distinct waits, a long name, and text outside ASCII still give
  /// a reason and a wait line of at most 200 characters each, and a brief under 1,600 bytes.
  @Test func theWorstCaseBriefStaysBounded() throws {
    let waits = (1...20).map { manualWait("\($0) " + String(repeating: "待", count: 200)) }
    var s = sessionSummary(reason: String(repeating: "理", count: 300), waits: waits, pr: briefPR())
    s.name = String(repeating: "n", count: 40)
    s.lastReply = String(repeating: "x", count: 5_000)
    s.acknowledged = true
    s.snoozedUntil = until

    let brief = SessionBrief(s)
    let bytes = try JSONCoding.encode(brief).utf8.count

    #expect(brief.reason.count <= 200)
    #expect(try #require(brief.waitLine).count <= 200)
    #expect(bytes < 1_600, "\(bytes) bytes")
  }

  // MARK: Parity with the full JSON

  /// The session shapes that store or read a brief field differently.
  enum Shape: String, CaseIterable, Sendable {
    case plain, noURL, acknowledged, notAcknowledged, snoozed, snoozeNote
    case openPR, mergedPR, closedPR, prWithoutChecks
    case oneWait, duplicateWaits, sevenWaits, sessionWait, callerWait, manualLongNote, dateWait
    case multiLineReason, longReason, emptyReason
    case chat, manager, `operator`, docketRow, notStarted

    var summary: SessionSummary {
      var s = sessionSummary()
      switch self {
      case .plain: break
      case .noURL: s.url = nil
      case .acknowledged: s.acknowledged = true
      case .notAcknowledged: s.acknowledged = false
      case .snoozed: s.snoozedUntil = until
      case .snoozeNote: s.snoozeNote = "snoozed until 2026-11-15 09:00"
      case .openPR: s.pr = briefPR(state: .open)
      case .mergedPR: s.pr = briefPR(state: .merged)
      case .closedPR: s.pr = briefPR(state: .closed)
      case .prWithoutChecks: s.pr = briefPR(reviewDecision: nil, checks: nil)
      case .oneWait: s.waits = [ciWait(422, repository: "haacked/switchboard")]
      case .duplicateWaits: s.waits = [ciWait(422, id: "w1"), ciWait(422, id: "w2")]
      case .sevenWaits: s.waits = (1...7).map { ciWait($0) }
      case .sessionWait: s.waits = [targetWait("fix-cache", reaching: .readyToMerge)]
      case .callerWait: s.waits = [ciWait(422, then: .caller)]
      case .manualLongNote: s.waits = [manualWait("Ask Alex\n" + String(repeating: "a", count: 500))]
      case .dateWait: s.waits = [Wait(id: "wd", kind: .date, until: until, created: 0)]
      case .multiLineReason: s.reason = "Needs a review\r\nfrom Alex"
      case .longReason: s.reason = String(repeating: "é", count: 300)
      case .emptyReason: s.reason = ""
      case .chat:
        s.kind = .chat
        s.chat = "g1"
      case .manager:
        s.kind = .manager
        s.manager = true
      case .operator: s.kind = .operator
      case .docketRow:
        s.docket = DocketSummary(
          DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())
      case .notStarted: s.state = .notStarted
      }
      return s
    }
  }

  @Test(arguments: Shape.allCases)
  func theBriefHoldsOnlyDecision4Keys(_ shape: Shape) throws {
    let b = try brief(shape.summary)

    #expect(try keys(b).isSubset(of: briefKeys), "\(b.text)")
    if let pr = b["pr"] { #expect(try keys(pr).isSubset(of: briefPRKeys), "\(b.text)") }
  }

  @Test(arguments: Shape.allCases)
  func eachSharedKeyEqualsTheFullJSONsKey(_ shape: Shape) throws {
    let s = shape.summary
    let full = try JSON(encoding: s)

    let b = try brief(s)

    for key in sharedKeys {
      #expect(b[key] == full[key], "\(key): \(b.text)")
    }
  }

  @Test(arguments: Shape.allCases)
  func eachPRKeyEqualsTheFullPRsKey(_ shape: Shape) throws {
    let s = shape.summary
    let full = try JSON(encoding: s)

    let b = try brief(s)

    #expect((b["pr"] == nil) == (full["pr"] == nil), "\(b.text)")
    for key in briefPRKeys {
      #expect(b["pr"]?[key] == full["pr"]?[key], "pr.\(key): \(b.text)")
    }
  }

  @Test(arguments: Shape.allCases)
  func theReasonIsTheFullReasonOnOneLine(_ shape: Shape) throws {
    let s = shape.summary

    #expect(try brief(s)["reason"] == .string(oneLine(s.reason, max: 200)))
  }

  @Test(arguments: Shape.allCases)
  func theWaitLineComesFromExactlyTheFullWaits(_ shape: Shape) throws {
    let s = shape.summary

    #expect(try waitLine(s) == expectedWaitLine(s.waits))
  }

  // MARK: briefLine

  @Test func aSessionWithoutPROrWaitsPrintsIdNameStateReasonAndURL() {
    let s = sessionSummary(id: "s1", name: "fix-cache", state: .needsYou, reason: "Needs a review")

    #expect(s.briefLine == "s1  fix-cache  Needs you: Needs a review  \(SessionLink.url(for: "s1").absoluteString)")
  }

  @Test func aSessionWithAPRAndAWaitPrintsEveryPartInOrder() {
    let p = briefPR(7, repo: "o/r", reviewDecision: nil, checks: nil)
    let s = sessionSummary(id: "s1", name: "fix-cache", state: .waiting, reason: "CI runs", waits: [ciWait(7)], pr: p)
    let url = SessionLink.url(for: "s1").absoluteString

    #expect(s.briefLine == "s1  fix-cache  Waiting: CI runs  PR o/r\(p.line)  waits: CI on #7  \(url)")
  }

  @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}", "\u{85}"])
  func theLineHasNoLineBreakWhenTheNameAndReasonHaveOne(_ separator: String) {
    let s = sessionSummary(
      name: "fix\(separator)cache", reason: "Needs\(separator)a review", waits: [manualWait("a\(separator)b")])

    #expect(!s.briefLine.contains { $0.isNewline }, "\(s.briefLine)")
  }

  @Test func theLineEscapesControlCharacters() {
    let s = sessionSummary(name: "fix\u{1b}[2Jcache")

    #expect(!s.briefLine.contains("\u{1b}"))
  }

  @Test func anAcknowledgedSessionsLineSaysAcknowledged() {
    var s = sessionSummary()
    s.acknowledged = true

    #expect(s.briefLine.contains("Needs a review (acknowledged)"))
  }

  @Test func aSnoozedSessionsLineCarriesTheSnoozeLabel() {
    var s = sessionSummary()
    s.snoozedUntil = until

    #expect(s.briefLine.contains(Snooze.label(until: until)))
  }

  @Test func aSessionWhoseSnoozeEndedShowsTheNoteInItsLine() {
    var s = sessionSummary()
    s.snoozeNote = "snoozed until 2026-11-15 09:00"

    #expect(s.briefLine.contains("(snoozed until 2026-11-15 09:00)"))
  }

  @Test func aSessionWithAPRNamesTheRepoAndNumber() {
    let s = sessionSummary(pr: briefPR(18303, repo: "PostHog/charts"))

    #expect(s.briefLine.contains("  PR PostHog/charts#18303 Approved"), "\(s.briefLine)")
  }

  @Test func aSessionWithoutAPRHasNoPRPart() {
    let s = sessionSummary()

    #expect(!s.briefLine.contains("  PR "), "\(s.briefLine)")
  }

  @Test func aSessionWithWaitsShowsTheWaitLine() throws {
    let s = sessionSummary(waits: (1...7).map { ciWait($0) })

    let line = try #require(try waitLine(s))

    #expect(s.briefLine.contains("  waits: \(line)"), "\(s.briefLine)")
  }

  @Test func aSessionWithoutWaitsHasNoWaitsPart() {
    let s = sessionSummary()

    #expect(!s.briefLine.contains("waits:"), "\(s.briefLine)")
  }

  @Test func theLineEndsWithTheSessionsURL() {
    let s = sessionSummary(id: "s5")

    #expect(s.briefLine.hasSuffix("  \(SessionLink.url(for: "s5").absoluteString)"), "\(s.briefLine)")
  }

  @Test func aLongReasonIsCutTo200InTheLine() {
    let reason = String(repeating: "a", count: 500)
    let s = sessionSummary(reason: reason)

    #expect(s.briefLine.contains(oneLine(reason, max: 200)), "\(s.briefLine)")
    #expect(!s.briefLine.contains(reason), "\(s.briefLine)")
  }
}
