import Testing

@testable import SwitchboardCore

private func summary(
  state: AttentionState = .working, cwd: String = "/tmp/w", mergeMethod: MergeMethod? = nil, hasPR: Bool = true,
  acknowledged: Bool? = nil, cleanup: CleanupStatus.State? = nil, kind: SessionKind = .work, markedDone: Bool = false,
  prState: PRState = .open
) -> SessionSummary {
  var pr = PRSummary(PullRequest(id: "PR_1", number: 1, url: "https://github.com/o/r/pull/1", repo: "o/r", title: ""))
  pr.mergeMethod = mergeMethod
  pr.state = prState
  var s = SessionSummary(
    id: "s1", name: "s1", cwd: cwd, repo: "o/r", branch: "b", claudeSessionId: "c1", state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
    pr: hasPR ? pr : nil, markedDone: markedDone)
  s.acknowledged = acknowledged
  s.kind = kind
  s.cleanup = cleanup.map { CleanupStatus(state: $0) }
  return s
}

private func usage(_ limits: [(String, Double)]) -> AccountUsage {
  AccountUsage(name: "a", folder: "~/.claude", limits: limits.map { UsageLimit(kind: $0, label: $0, percent: $1) })
}

@Suite struct SessionRulesTests {

  // MARK: canMerge

  @Test(arguments: [MergeMethod.merge, .mergeQueue, .trunk])
  func readyToMergeWithAKnownMethodCanMerge(_ method: MergeMethod) {
    #expect(summary(state: .readyToMerge, mergeMethod: method).canMerge)
  }

  @Test func readyToMergeWithAnUnknownMethodCannotMerge() {
    #expect(!summary(state: .readyToMerge, mergeMethod: .unknown).canMerge)
  }

  @Test func readyToMergeWithoutAMethodCannotMerge() {
    #expect(!summary(state: .readyToMerge, mergeMethod: nil).canMerge)
    #expect(!summary(state: .readyToMerge, hasPR: false).canMerge)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .readyToMerge })
  func otherStatesCannotMerge(_ state: AttentionState) {
    #expect(!summary(state: state, mergeMethod: .merge).canMerge)
  }

  // MARK: canAcknowledge

  @Test(arguments: AttentionState.allCases)
  func anUnacknowledgedSessionCanAcknowledgeOnlyInTheInbox(_ state: AttentionState) {
    let expected = AttentionState.inbox.contains(state)
    #expect(summary(state: state).canAcknowledge == expected)
    #expect(summary(state: state, acknowledged: false).canAcknowledge == expected)
  }

  @Test(arguments: AttentionState.allCases)
  func anAcknowledgedSessionCanUndoInAnyState(_ state: AttentionState) {
    #expect(summary(state: state, acknowledged: true).canAcknowledge)
  }

  // MARK: canHighlight

  @Test(arguments: AttentionState.allCases.filter { $0 != .done })
  func aWorkSessionCanBeHighlightedInEveryStateButDone(_ state: AttentionState) {
    #expect(summary(state: state).canHighlight)
  }

  /// Its state is Needs you, so it keeps its highlight although the Board shows it in the Done footer.
  @Test func aMergedPRWithUncommittedChangesCanBeHighlighted() {
    #expect(summary(state: .needsYou, prState: .merged).canHighlight)
  }

  @Test func aWorkSessionMarkedDoneCannotBeHighlighted() {
    #expect(!summary(state: .done, markedDone: true).canHighlight)
  }

  /// A merged or closed PR with a clean folder puts the session in Done without marking it done.
  @Test(arguments: [PRState.merged, .closed])
  func aWorkSessionDoneThroughItsPRCannotBeHighlighted(_ prState: PRState) {
    #expect(!summary(state: .done, markedDone: false, prState: prState).canHighlight)
  }

  @Test(arguments: [SessionKind.manager, .chat, .operator], AttentionState.allCases)
  func onlyAWorkSessionCanBeHighlighted(_ kind: SessionKind, _ state: AttentionState) {
    #expect(!summary(state: state, kind: kind).canHighlight)
  }

  // MARK: hasTerminals

  @Test(arguments: [nil, CleanupStatus.State.ready, .blocked])
  func aSessionWithAFolderHasTerminalsUntilCleanupRemovesIt(_ cleanup: CleanupStatus.State?) {
    #expect(summary(cleanup: cleanup).hasTerminals)
  }

  @Test func aSessionWhoseWorktreeCleanupRemovedHasNoTerminals() {
    #expect(!summary(cleanup: .removed).hasTerminals)
  }

  @Test func aSessionWithoutAFolderHasNoTerminals() {
    #expect(!summary(cwd: "").hasTerminals)
  }

  // MARK: AccountUsage percents

  @Test func percentsAreMissingOrZeroWithoutLimits() {
    #expect(usage([]).sessionPercent == nil)
    #expect(usage([]).weeklyPercent == 0)
  }

  @Test func sessionPercentReadsTheSessionLimit() {
    #expect(usage([("weekly_all", 70), ("session", 12)]).sessionPercent == 12)
  }

  @Test func sessionPercentIsNilWithoutASessionLimit() {
    #expect(usage([("weekly_all", 70)]).sessionPercent == nil)
  }

  @Test func weeklyPercentIsTheHighestNonSessionLimit() {
    let u = usage([("session", 95), ("weekly_all", 40), ("weekly_scoped", 65), ("future_kind", 50)])
    #expect(u.weeklyPercent == 65)
  }

  @Test func weeklyPercentIsZeroWithOnlyASessionLimit() {
    #expect(usage([("session", 95)]).weeklyPercent == 0)
  }
}
