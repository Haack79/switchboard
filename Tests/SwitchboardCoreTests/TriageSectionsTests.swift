import Testing

@testable import SwitchboardCore

@Suite struct TriageSections {
  func summary(
    _ id: String, _ state: AttentionState, since: Int64 = 0, _ source: TriageSource = .summary,
    _ kind: TriageKind = .decision
  ) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "", since: since,
      lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.triage = TriageItem(title: id, kind: kind, summary: "", source: source)
    return s
  }

  func layout(_ items: [SessionSummary]) -> [String] {
    Triage.sections(items).map { "\($0.id) \($0.title): \($0.sessions.map(\.id).joined(separator: ","))" }
  }

  @Test func sectionsFollowTheInboxStates() {
    let items = [
      summary("c", .canContinue),
      summary("w", .working),
      summary("r", .readyToMerge),
      summary("s", .stale),
      summary("n", .needsYou),
    ]

    let sections = Triage.sections(items)

    #expect(sections.map(\.id) == AttentionState.inbox.map(\.rawValue))
    #expect(sections.map(\.title) == AttentionState.inbox.map(\.title))
    #expect(sections.map { $0.sessions.map(\.id) } == [["n"], ["r"], ["c"]])
  }

  @Test func sectionsSkipEmptyStates() {
    let items = [summary("c", .canContinue), summary("n", .needsYou)]

    #expect(layout(items) == ["needs_you Needs you: n", "can_continue Claude can continue: c"])
  }

  @Test func sectionsKeepTheInputOrderWithinAState() {
    let items = [
      summary("n3", .needsYou, since: 9),
      summary("c2", .canContinue, since: 7),
      summary("n1", .needsYou, since: 1),
      summary("r2", .readyToMerge, since: 8),
      summary("c1", .canContinue, since: 2),
      summary("n2", .needsYou, since: 5),
      summary("r1", .readyToMerge, since: 3),
    ]

    #expect(
      layout(items) == [
        "needs_you Needs you: n3,n1,n2",
        "ready_to_merge Ready to merge: r2,r1",
        "can_continue Claude can continue: c2,c1",
      ])
  }

  @Test func noItemsGivesNoSections() {
    #expect(Triage.sections([]).isEmpty)
  }

  @Test(arguments: [AttentionState.readyForReview, .waiting, .working, .done, .stale, .notStarted])
  func aStateOutsideTheInboxGivesNoSection(_ state: AttentionState) {
    #expect(Triage.sections([summary("x", state)]).isEmpty)
  }

  /// The Inbox showed `Triage.order`'s items grouped by `AttentionState.inbox`
  /// before `Triage.sections` existed. This list puts Ready to merge items
  /// between Needs you items, because both rank as approvals.
  @Test func sectionsMatchTheInboxGroupingOfTriageOrder() {
    let list = [
      summary("continue-old", .canContinue, since: 1),
      summary("merge-new", .readyToMerge, since: 9, .rule, .approval),
      summary("info", .needsYou, since: 2, .rule, .info),
      summary("merge-old", .readyToMerge, since: 3, .rule, .approval),
      summary("decision", .needsYou, since: 6, .summary, .decision),
      summary("card", .needsYou, since: 8, .card, .approval),
      summary("action", .needsYou, since: 4, .rule, .action),
      summary("continue-new", .canContinue, since: 7),
      summary("working", .working, since: 0),
      summary("tie-b", .needsYou, since: 5, .summary, .question),
      summary("tie-a", .needsYou, since: 5, .summary, .question),
    ]
    let ordered = Triage.order(list)
    let grouped = AttentionState.inbox.compactMap { state -> (String, String, [String])? in
      let group = ordered.filter { $0.state == state }
      return group.isEmpty ? nil : (state.rawValue, state.title, group.map(\.id))
    }

    let sections = Triage.sections(ordered)

    #expect(sections.map(\.id) == grouped.map(\.0))
    #expect(sections.map(\.title) == grouped.map(\.1))
    #expect(sections.map { $0.sessions.map(\.id) } == grouped.map(\.2))
  }
}
