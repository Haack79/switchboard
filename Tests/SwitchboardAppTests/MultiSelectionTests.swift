import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Four sessions in the Inbox and the sidebar.
@MainActor
private func fourSessions() -> BoardModel { appliedModel(["a", "b", "c", "d"].map { needsItem($0) }) }

/// The sidebar's `List(selection:)` binding. It shows `multiSelection` while that holds two or more ids, and the
/// set of `selection` otherwise.
@MainActor
@Suite struct MultiSelectionBinding {
  @Test func oneIDSetsTheSelection() {
    let model = fourSessions()

    model.sidebarSelection.wrappedValue = ["b"]

    #expect(model.selection == "b")
  }

  @Test func oneIDClearsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["c"]

    #expect(model.multiSelection.isEmpty)
  }

  /// The selection does not change, so a clear that runs only when `selection` changes misses this case.
  @Test func theSelectedIDAloneClearsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["a"]

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "a")
  }

  @Test func noIDClearsTheMultiSelectionAndTheSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = []

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == nil)
  }

  @Test func twoIDsSetTheMultiSelection() {
    let model = fourSessions()

    model.sidebarSelection.wrappedValue = ["a", "b"]

    #expect(model.multiSelection == ["a", "b"])
  }

  @Test func twoIDsLeaveTheSelectionAlone() {
    let model = fourSessions()
    model.selection = "a"

    model.sidebarSelection.wrappedValue = ["a", "b"]

    #expect(model.selection == "a")
  }

  @Test func threeIDsReplaceAnEarlierMultiSelection() {
    let model = fourSessions()
    model.multiSelection = ["a", "b"]

    model.sidebarSelection.wrappedValue = ["b", "c", "d"]

    #expect(model.multiSelection == ["b", "c", "d"])
  }

  @Test func theBindingShowsTheMultiSelection() {
    let model = fourSessions()
    model.selection = "a"
    model.multiSelection = ["a", "b", "c"]

    #expect(model.sidebarSelection.wrappedValue == ["a", "b", "c"])
  }

  @Test func theBindingShowsTheSelectionWithoutAMultiSelection() {
    let model = fourSessions()
    model.selection = "a"

    #expect(model.sidebarSelection.wrappedValue == ["a"])
  }

  @Test func theBindingIsEmptyWithNothingSelected() {
    #expect(fourSessions().sidebarSelection.wrappedValue.isEmpty)
  }

  /// Navigation history records only `selection`.
  @Test func multiSelectingAddsNoHistoryEntry() throws {
    let model = fourSessions()
    model.selection = "a"
    let before = model.history.entries.count

    model.sidebarSelection.wrappedValue = ["a", "b"]

    try #require(model.multiSelection == ["a", "b"])
    #expect(model.history.entries.count == before)
    #expect(model.history.current == NavLocation(place: .session("a"), terminal: false))
  }
}

/// Every path that changes `selection`, other than the sidebar binding, ends a multi-selection.
@MainActor
@Suite struct MultiSelectionSources {
  enum Source: String, CaseIterable, Sendable {
    case plainSelection, search, notification, keyboardStep, back, mainView, boardCard, createdSession

    /// Arranges `model` with `a` selected and a multi-selection of `a` and `b`, then changes the selection.
    @MainActor func run(_ model: BoardModel) {
      if self == .back {
        model.selection = "c"
      }
      model.selection = "a"
      model.multiSelection = ["a", "b"]
      switch self {
      case .plainSelection: model.selection = "c"
      case .search: model.openFromSearch("c")
      case .notification: model.reveal("c")
      case .keyboardStep: model.selectAdjacentSession(by: 1)
      case .back: model.goBack()
      case .mainView: model.show(.board)
      case .boardCard: model.openFromBoard("c")
      case .createdSession: model.selectUnlisted("new")
      }
    }
  }

  @Test(arguments: Source.allCases)
  func aSelectionChangeClearsTheMultiSelection(_ source: Source) {
    let model = fourSessions()

    source.run(model)

    #expect(model.multiSelection.isEmpty, "\(source.rawValue)")
  }
}

/// sbd's removal job holds a session that the refresh lists with a queued or running removal. The app hides a
/// held session, so it leaves the multi-selection.
@MainActor
@Suite struct MultiSelectionRemovalJob {
  func refresh(_ model: BoardModel, holding held: [String: Removal.State]) {
    model.apply(.success(["a", "b", "c", "d"].map { removalSession($0, held[$0]) }), followups: nil)
  }

  func model(selection: String, multi: Set<String>) -> BoardModel {
    let model = appliedModel(["a", "b", "c", "d"].map { removalSession($0, nil) })
    model.selection = selection
    model.multiSelection = multi
    return model
  }

  @Test(arguments: [Removal.State.queued, .running])
  func aHeldSessionLeavesTheMultiSelection(_ state: Removal.State) {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["b": state])

    #expect(model.multiSelection == ["a", "c"])
  }

  /// The refresh clears a held `selection`. That clear must not empty the rest of the multi-selection.
  @Test func aHeldSelectedSessionLeavesTheOthersSelected() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued])

    #expect(model.multiSelection == ["b", "c"])
    #expect(model.selection != "a")
  }

  @Test func aSessionWhoseRemovalFailedStaysInTheMultiSelection() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["b": .failed])

    #expect(model.multiSelection == ["a", "b", "c"])
  }

  /// One id left is a single selection, as the binding's set with one id makes it.
  @Test func aMultiSelectionThatDropsToOneIDEnds() {
    let model = model(selection: "a", multi: ["a", "b"])

    refresh(model, holding: ["b": .queued])

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "a")
    #expect(model.sidebarSelection.wrappedValue == ["a"])
  }

  /// The detail pane shows the multi-selection, and history and the Session menu still have a session.
  @Test func aHeldSelectedSessionPassesTheSelectionToARemainingID() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued])

    #expect(model.selection == "b")
    #expect(model.multiSelection == ["b", "c"])
    #expect(model.visibleView == nil)
  }

  @Test func theRemainingIDBecomesTheSelectionWhenTheSelectedSessionIsHeld() {
    let model = model(selection: "a", multi: ["a", "b"])

    refresh(model, holding: ["a": .queued])

    #expect(model.multiSelection.isEmpty)
    #expect(model.selection == "b")
  }

  @Test func theBindingNeverShowsAHeldSession() {
    let model = model(selection: "a", multi: ["a", "b", "c"])

    refresh(model, holding: ["a": .queued, "b": .running])

    #expect(model.sidebarSelection.wrappedValue.isDisjoint(with: ["a", "b"]))
  }

  /// A session that the org filter hides can't be in the selection.
  @Test func aSessionThatTheOrgFilterHidesLeavesTheMultiSelection() {
    let model = orgFilterModel(OrgFilter())
    model.apply(
      .success([
        orgSession("ph1", "PostHog/posthog"), orgSession("hk", "haacked/switchboard"),
        orgSession("ph2", "PostHog/posthog-js"),
      ]), followups: nil)
    model.selection = "ph1"
    model.multiSelection = ["ph1", "hk", "ph2"]

    model.orgFilter = posthogOnly

    #expect(model.multiSelection == ["ph1", "ph2"])
  }
}

/// Delete N Sessions…, which MultiSelectionView's button, the selected row's context menu, and ⌘⌫ in the sidebar
/// all call as `checkSelectionRemoval()`. It asks sbd for a work-scope plan and shows it in the Delete All sheet.
@MainActor
@Suite struct MultiSelectionDelete {
  /// A Waiting session, a working one, and a Done one.
  nonisolated static let list = [
    needsItem("w", state: .waiting), needsItem("k", state: .working), needsItem("d", state: .done),
  ]
  nonisolated static let plan = RemovalPlan(remove: ["w", "k", "d"].map(removalItem), skip: [])

  func multiSelected(_ sent: SentRequests, _ list: [SessionSummary] = list, plan: RemovalPlan = plan) -> BoardModel {
    let model = appliedModel(list)
    model.send = recordingSend(sent, plan: plan)
    model.selection = list[0].id
    model.multiSelection = Set(list.map(\.id))
    return model
  }

  func confirming(_ model: BoardModel) async -> RemovalPlan? {
    await settle { if case .confirming = model.doneRemoval { true } else { false } }
    guard case .confirming(let shown, _) = model.doneRemoval else { return nil }
    return shown
  }

  // MARK: The plan

  @Test func asksSbdForAPlanWithRmPlan() async {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    #expect(sent.ops.first == "rm-plan")
  }

  @Test func thePlanTakesTheWorkScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(args["scope"] == .string("work"))
  }

  @Test func thePlanTargetsTheSelectedSessions() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(Set(args["targets"]?.array?.compactMap(\.string) ?? []) == ["w", "k", "d"])
  }

  /// The same `rm` arguments as the Done delete icon and Delete All: the worktree, and sbd adds the branch and
  /// the remote branch when the PR merged.
  @Test func thePlanAsksForTheWorktreeAndTheRemoteBranch() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    await settle { !sent.value.isEmpty }

    let args = try #require(sent.value.first?.args)
    #expect(args["worktree"] == .bool(true))
    #expect(args["remote_branch"] == .bool(true))
  }

  @Test func thePlanShowsInTheDeleteAllConfirmation() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)

    model.checkSelectionRemoval()
    let shown = await confirming(model)

    #expect(shown == Self.plan)
    #expect(model.showingDoneRemoval)
  }

  // MARK: The confirmation

  @Test func confirmingSendsOneRmQueueWithThePlannedIDs() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    #expect(sent.queues.count == 1)
    #expect(Set(sent.queues.first?["targets"]?.array?.compactMap(\.string) ?? []) == ["w", "k", "d"])
  }

  /// `rm-queue` mirrors the plan's scope. With `done`, sbd would skip the Waiting and working sessions.
  @Test func confirmingQueuesWithTheWorkScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    let args = try #require(sent.queues.first)
    #expect(args["scope"] == .string("work"))
    #expect(args["worktree"] == .bool(true))
    #expect(args["remote_branch"] == .bool(true))
  }

  /// The work scope belongs to the multi-select confirmation alone.
  @Test func aLaterDeleteAllQueuesWithTheDoneScope() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let first = try #require(await confirming(model))
    model.removeDone(first)
    await settle { !sent.queues.isEmpty }

    model.checkDoneRemoval()
    let second = try #require(await confirming(model))
    model.removeDone(second)
    await settle { sent.queues.count >= 2 }

    #expect(sent.queues.count == 2)
    #expect(sent.queues.last?["scope"] == .string("done"))
  }

  @Test func confirmingAfterAFilterChangeThatHidesAPlannedIDNeverQueuesIt() async throws {
    let sent = SentRequests()
    let list = [orgSession("ph", "PostHog/posthog"), orgSession("hk", "haacked/switchboard")]
    let model = orgFilterModel(OrgFilter())
    model.apply(.success(list), followups: nil)
    model.send = recordingSend(sent, plan: RemovalPlan(remove: [removalItem("ph"), removalItem("hk")], skip: []))
    model.selection = "ph"
    model.multiSelection = ["ph", "hk"]
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.orgFilter = posthogOnly
    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }

    #expect(sent.queues.first?["targets"]?.array?.compactMap(\.string) == ["ph"])
    #expect(sent.queues.first?["scope"] == .string("work"))
  }

  /// sbd answers on a serial queue, so the reply to a cancelled check can arrive while a later check waits.
  @Test func aReplyToACancelledCheckNeverFillsTheNextOne() async throws {
    let sent = SentRequests()
    let gate = DispatchSemaphore(value: 0)
    let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0) })
    model.send = { op, args in
      sent.append(op, args)
      if sent.value.count == 1 { gate.wait() }
      let targets = args["targets"]?.array?.compactMap(\.string) ?? []
      return try JSON(encoding: RemovalPlan(remove: targets.map(removalItem), skip: []))
    }
    model.selection = "a"
    model.multiSelection = ["a", "b"]
    model.checkSelectionRemoval()
    await settle { sent.value.count == 1 }

    model.doneRemoval = nil
    model.sidebarSelection.wrappedValue = ["c", "d"]
    model.checkSelectionRemoval()
    gate.signal()
    let shown = try #require(await confirming(model))

    #expect(Set(shown.remove.map(\.id)) == ["c", "d"])
  }

  @Test func confirmingClosesTheSheet() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))

    model.removeDone(shown)

    #expect(model.doneRemoval == nil)
  }

  /// The queued sessions leave the lists, and the multi-selection ends.
  @Test func theRefreshAfterTheQueueEndsTheMultiSelection() async throws {
    let sent = SentRequests()
    let model = multiSelected(sent)
    model.checkSelectionRemoval()
    let shown = try #require(await confirming(model))
    try #require(model.multiSelection == ["w", "k", "d"])

    model.removeDone(shown)
    await settle { !sent.queues.isEmpty }
    model.apply(
      .success(
        Self.list.map { s in
          var held = s
          held.removal = Removal(
            requested: 1, notBefore: 1, worktree: true, branch: false, remoteBranch: false, resolve: [])
          return held
        }), followups: nil)

    #expect(model.multiSelection.isEmpty)
  }
}

@Suite struct MultiSelectionText {
  @Test(arguments: [(2, "2 sessions selected"), (5, "5 sessions selected")])
  func theDetailPaneNamesHowManySessionsAreSelected(_ count: Int, _ expected: String) {
    #expect(DoneRemovalText.selected(count) == expected)
  }

  @Test(arguments: [(2, "Delete 2 Sessions…"), (5, "Delete 5 Sessions…")])
  func theDeleteButtonNamesHowManySessionsItDeletes(_ count: Int, _ expected: String) {
    #expect(DoneRemovalText.deleteSessions(count) == expected)
  }

  @Test func theDeleteButtonEndsWithAnEllipsisCharacter() {
    let text = DoneRemovalText.deleteSessions(2)

    #expect(text.hasSuffix("\u{2026}"))
    #expect(!text.contains("..."))
  }

  @Test func aWorkingSessionSaysItsClaudeStops() {
    #expect(DoneRemovalText.working(needsItem("k", state: .working)) == "claude is working and stops")
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .working })
  func aSessionThatIsNotWorkingSaysNothingAboutItsClaude(_ state: AttentionState) {
    #expect(DoneRemovalText.working(needsItem("s", state: state)) == nil)
  }

  /// A plan item whose session the board no longer lists.
  @Test func anUnlistedSessionSaysNothingAboutItsClaude() {
    #expect(DoneRemovalText.working(nil) == nil)
  }
}
