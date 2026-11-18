import Testing

@testable import SwitchboardCore

/// The highlight in Core: the Inbox order and sections, the wire format, and the MCP tool.
@Suite struct HighlightTests {
  static func summary(
    _ id: String, _ state: AttentionState, since: Int64 = 0, _ source: TriageSource? = .summary,
    _ kind: TriageKind = .decision, highlighted: Bool? = nil, sessionKind: SessionKind = .work
  ) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "", since: since,
      lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.triage = source.map { TriageItem(title: id, kind: kind, summary: "", source: $0) }
    s.highlighted = highlighted
    s.kind = sessionKind
    return s
  }

  /// One item of every rank, a tie on `since` that the id breaks, Ready to merge
  /// items between Needs you items, an operator report, and sessions that have no item.
  static let everyRank: [SessionSummary] = [
    summary("continue-old", .canContinue, since: 1),
    summary("merge-new", .readyToMerge, since: 9, .rule, .approval),
    summary("info", .needsYou, since: 2, .rule, .info),
    summary("merge-old", .readyToMerge, since: 3, .rule, .approval),
    summary("decision", .needsYou, since: 6, .summary, .decision),
    summary("card", .needsYou, since: 8, .card, .approval),
    summary("action", .needsYou, since: 4, .rule, .action),
    summary("review", .needsYou, since: 10, .summary, .review),
    summary("continue-new", .canContinue, since: 7),
    summary("tie-b", .needsYou, since: 5, .summary, .question),
    summary("tie-a", .needsYou, since: 5, .summary, .question),
    summary("report", .needsYou, since: 11, .report, .decision, sessionKind: .operator),
    summary("working", .working, since: 0, nil),
    summary("snoozed", .waiting, since: 0, nil),
  ]

  static func highlighting(_ ids: Set<String>, in list: [SessionSummary]) -> [SessionSummary] {
    list.map {
      var s = $0
      s.highlighted = ids.contains(s.id) ? true : nil
      return s
    }
  }

  /// The ids to highlight in `everyRank`: none, all, one per rank, and mixes across ranks.
  static let highlightSets: [Set<String>] = [
    [],
    Set(everyRank.map(\.id)),
    ["card"],
    ["decision"],
    ["merge-new"],
    ["action"],
    ["review"],
    ["info"],
    ["continue-new"],
    ["report"],
    ["tie-b"],
    ["tie-a", "tie-b"],
    ["continue-old", "card", "review"],
    ["merge-old", "info", "continue-new", "action"],
    ["working", "snoozed"],
    ["working", "continue-new"],
  ]

  // MARK: Order

  @Test func orderPutsHighlightedItemsFirst() {
    let list = [
      Self.summary("old", .needsYou, since: 1),
      Self.summary("new", .needsYou, since: 2, highlighted: true),
    ]

    #expect(Triage.order(list).map(\.id) == ["new", "old"])
  }

  @Test func aHighlightedItemOfALowerRankComesBeforeACard() {
    let list = [
      Self.summary("card", .needsYou, since: 1, .card, .approval),
      Self.summary("continue", .canContinue, since: 2, highlighted: true),
    ]

    #expect(Triage.order(list).map(\.id) == ["continue", "card"])
  }

  @Test func orderKeepsRankAndAgeAmongHighlightedItems() {
    let list = [
      Self.summary("continue", .canContinue, since: 1, highlighted: true),
      Self.summary("review", .needsYou, since: 2, .summary, .review, highlighted: true),
      Self.summary("decision-new", .needsYou, since: 9, .summary, .decision, highlighted: true),
      Self.summary("decision-old", .needsYou, since: 3, .summary, .decision, highlighted: true),
      Self.summary("tie-b", .needsYou, since: 5, .summary, .question, highlighted: true),
      Self.summary("tie-a", .needsYou, since: 5, .summary, .question, highlighted: true),
      Self.summary("card", .needsYou, since: 8, .card, .approval, highlighted: true),
    ]

    #expect(
      Triage.order(list).map(\.id) == [
        "card", "decision-old", "tie-a", "tie-b", "decision-new", "review", "continue",
      ])
  }

  /// The order of `everyRank` before the highlight existed: rank, then `since`, then id.
  @Test func orderIsUnchangedWithoutHighlights() {
    #expect(
      Triage.order(Self.everyRank).map(\.id) == [
        "card", "merge-old", "tie-a", "tie-b", "decision", "merge-new", "report", "action", "info", "review",
        "continue-old", "continue-new",
      ])
  }

  @Test func anExplicitFalseSortsAsNotHighlighted() {
    let withFalse = Self.everyRank.map {
      var s = $0
      s.highlighted = false
      return s
    }

    #expect(Triage.order(withFalse).map(\.id) == Triage.order(Self.everyRank).map(\.id))
  }

  /// Risk 2: the new order is the old order filtered to the highlighted items, then the old order filtered to the
  /// rest. The old order is the order of the same list with no highlight.
  @Test(arguments: HighlightTests.highlightSets)
  func orderIsAStablePartition(_ ids: Set<String>) {
    let list = Self.highlighting(ids, in: Self.everyRank)
    let base = Triage.order(Self.highlighting([], in: Self.everyRank)).map(\.id)

    let ordered = Triage.order(list).map(\.id)

    #expect(ordered == base.filter { ids.contains($0) } + base.filter { !ids.contains($0) })
  }

  @Test func orderLeavesOutASnoozedHighlightedSession() {
    var snoozed = Self.summary("snoozed", .waiting, since: 1, nil, highlighted: true)
    snoozed.snoozedUntil = 9_999_999
    let list = [snoozed, Self.summary("other", .needsYou, since: 2)]

    #expect(Triage.order(list).map(\.id) == ["other"])
  }

  @Test func orderLeavesOutAnAcknowledgedHighlightedSession() {
    var acknowledged = Self.summary("acked", .waiting, since: 1, nil, highlighted: true)
    acknowledged.acknowledged = true
    let list = [acknowledged, Self.summary("other", .needsYou, since: 2)]

    #expect(Triage.order(list).map(\.id) == ["other"])
  }

  @Test(arguments: [AttentionState.working, .waiting, .done, .readyForReview, .stale, .notStarted])
  func orderLeavesOutAHighlightedSessionWithNoItem(_ state: AttentionState) {
    let list = [Self.summary("h", state, since: 1, nil, highlighted: true), Self.summary("other", .needsYou, since: 2)]

    #expect(Triage.order(list).map(\.id) == ["other"])
  }

  /// A conversation's summary item never reaches the Inbox, highlighted or not.
  @Test func orderLeavesOutAHighlightedManagerSummaryItem() {
    let list = [
      Self.summary("manager", .needsYou, since: 1, highlighted: true, sessionKind: .manager),
      Self.summary("other", .needsYou, since: 2),
    ]

    #expect(Triage.order(list).map(\.id) == ["other"])
  }

  // MARK: Sections

  func layout(_ sections: [Triage.Section]) -> [String] {
    sections.map { "\($0.id) \($0.title): \($0.sessions.map(\.id).joined(separator: ","))" }
  }

  @Test func sectionsPutHighlightedFirstWhenAny() {
    let ordered = [
      Self.summary("c1", .canContinue, highlighted: true),
      Self.summary("n2", .needsYou, highlighted: true),
      Self.summary("n1", .needsYou),
      Self.summary("r1", .readyToMerge),
      Self.summary("c2", .canContinue),
    ]

    #expect(
      layout(Triage.sections(ordered)) == [
        "highlighted Highlighted: c1,n2",
        "needs_you Needs you: n1",
        "ready_to_merge Ready to merge: r1",
        "can_continue Claude can continue: c2",
      ])
  }

  @Test func sectionsHaveNoHighlightedSectionWithoutHighlights() {
    let ordered = [Self.summary("n1", .needsYou), Self.summary("c1", .canContinue)]

    #expect(!Triage.sections(ordered).contains { $0.id == "highlighted" })
  }

  @Test func sectionsDoNotRepeatAHighlightedItemInItsStateSection() {
    let ordered = [
      Self.summary("n2", .needsYou, highlighted: true),
      Self.summary("n1", .needsYou),
      Self.summary("c1", .canContinue, highlighted: true),
    ]

    let ids = Triage.sections(ordered).flatMap { $0.sessions.map(\.id) }

    #expect(ids.sorted() == ["c1", "n1", "n2"])
  }

  @Test func aStateSectionThatOnlyHadHighlightedItemsDisappears() {
    let ordered = [
      Self.summary("r1", .readyToMerge, highlighted: true),
      Self.summary("n1", .needsYou),
    ]

    #expect(layout(Triage.sections(ordered)) == ["highlighted Highlighted: r1", "needs_you Needs you: n1"])
  }

  @Test func allHighlightedGivesOnlyTheHighlightedSection() {
    let ordered = [
      Self.summary("n1", .needsYou, highlighted: true),
      Self.summary("c1", .canContinue, highlighted: true),
    ]

    #expect(layout(Triage.sections(ordered)) == ["highlighted Highlighted: n1,c1"])
  }

  /// Risk 2: the first section is exactly the highlighted prefix of `Triage.order`, and the other sections are the
  /// Inbox's grouping of the rest by `AttentionState.inbox`, as before the highlight. With no highlight, the sections
  /// are that grouping of the whole order.
  @Test(arguments: HighlightTests.highlightSets)
  func sectionsAreTheHighlightedPrefixThenTheOldGroupingOfTheRest(_ ids: Set<String>) {
    let ordered = Triage.order(Self.highlighting(ids, in: Self.everyRank))
    let prefix = ordered.prefix { $0.highlighted == true }.map(\.id)
    let rest = ordered.filter { $0.highlighted != true }
    var expected = prefix.isEmpty ? [] : ["highlighted Highlighted: \(prefix.joined(separator: ","))"]
    for state in AttentionState.inbox {
      let group = rest.filter { $0.state == state }.map(\.id)
      if !group.isEmpty { expected.append("\(state.rawValue) \(state.title): \(group.joined(separator: ","))") }
    }

    #expect(layout(Triage.sections(ordered)) == expected)
  }

  // MARK: Wire format

  @Test func aSummaryWithoutTheKeyDecodesAsNotHighlighted() throws {
    var object = try #require(try JSON(encoding: Self.summary("s1", .needsYou, highlighted: true)).object)
    object["highlighted"] = nil

    let decoded = try JSONCoding.decode(SessionSummary.self, from: JSON.object(object).text)

    #expect(decoded.highlighted == nil)
  }

  @Test func aHighlightedSummaryRoundTrips() throws {
    let s = Self.summary("s1", .needsYou, highlighted: true)

    let decoded = try JSONCoding.decode(SessionSummary.self, from: try JSONCoding.encode(s))

    #expect(decoded.highlighted == true)
  }

  /// sbd reads the rows that an older sbd stored. Their JSON has no `highlighted` key.
  @Test func aStoredSessionWithoutTheKeyDecodes() throws {
    let row = """
      {"claudeSessionId": "u1", "created": 5, "cwd": "/tmp/a", "done": false, "id": "s1", "name": "one",
       "started": true, "waits": [], "notes": []}
      """

    let decoded = try JSONCoding.decode(Session.self, from: row)

    #expect(decoded.highlighted == nil)
    #expect(decoded.id == "s1")
  }

  @Test func aHighlightedStoredSessionRoundTrips() throws {
    var s = Session(id: "s1", name: "one", cwd: "/a", claudeSessionId: "u1", created: 5)
    s.highlighted = true

    let decoded = try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s))

    #expect(decoded == s)
  }

  @Test func aSummaryEncodesHighlightedOnlyWhenTrue() throws {
    let plain = try JSON(encoding: Self.summary("s1", .needsYou))
    let highlighted = try JSON(encoding: Self.summary("s1", .needsYou, highlighted: true))

    #expect(plain.object?.keys.contains("highlighted") == false)
    #expect(highlighted["highlighted"] == .bool(true))
  }

  @Test func aStoredSessionEncodesNoKeyWithoutAHighlight() throws {
    let s = Session(id: "s1", name: "one", cwd: "/a", claudeSessionId: "u1", created: 5)

    #expect(try JSON(encoding: s).object?.keys.contains("highlighted") == false)
  }

  // MARK: MCP tool

  @Test func theHighlightToolIsListed() throws {
    let tool = try #require(MCPToolServer.allTools.first { $0.name == "highlight" })

    #expect(tool.required == ["session"])
    #expect(Set(tool.properties.keys) == ["session", "clear"])
    #expect(tool.properties["session"] == MCPToolServer.session)
    #expect(tool.properties["clear"]?["type"] == .string("boolean"))
  }

  @Test func theHighlightToolSaysThatDoneClearsItAndThatASessionCantHighlightItself() throws {
    let tool = try #require(MCPToolServer.allTools.first { $0.name == "highlight" })

    #expect(tool.description.contains("Done"), "\(tool.description)")
    #expect(tool.description.contains("can't highlight itself"), "\(tool.description)")
  }
}
