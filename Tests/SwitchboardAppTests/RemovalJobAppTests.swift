import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A session in `state` with a removal in the state `removal`, or with no removal when `removal` is nil.
func removalSession(_ id: String, _ removal: Removal.State?, state: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.removal = removal.map { removal in
    var value = Removal(requested: 1, notBefore: 1, worktree: true, branch: false, remoteBranch: false, resolve: [])
    value.state = removal
    if removal == .failed {
      value.error = "/tmp has uncommitted files (1)."
      s.reason = "Delete failed: /tmp has uncommitted files (1)."
    }
    return value
  }
  return s
}

/// A session whose removal is `state` and does not start before `notBefore`, in ms on sbd's clock.
func undoSession(_ id: String, _ state: Removal.State = .queued, notBefore: Int64) -> SessionSummary {
  var s = removalSession(id, state)
  s.removal?.notBefore = notBefore
  return s
}

/// The sidebar, the Inbox, and the Board leave out a session while sbd's removal job holds it.
@MainActor
@Suite struct BoardModelRemovalFilter {
  /// A plain session, a queued one that needs you, a running one that works, and a failed one.
  /// The held sessions are in states that the Inbox and the sidebar would otherwise show.
  static let list = [
    removalSession("p", nil), removalSession("q", .queued), removalSession("r", .running, state: .working),
    removalSession("f", .failed),
  ]
  static let held: Set<String> = ["q", "r"]

  @Test(arguments: BoardModelOrgFilterTests.Shown.allCases)
  func aListWithHeldSessionsShowsWhatTheListWithoutThemShows(_ shown: BoardModelOrgFilterTests.Shown) {
    let withHeld = shown.ids(appliedModel(Self.list))
    let without = shown.ids(appliedModel(Self.list.filter { !Self.held.contains($0.id) }))

    #expect(withHeld == without, "\(shown.rawValue)")
  }

  @Test(arguments: BoardModelOrgFilterTests.Shown.allCases)
  func noListShowsAHeldSession(_ shown: BoardModelOrgFilterTests.Shown) {
    #expect(shown.ids(appliedModel(Self.list)).isDisjoint(with: Self.held), "\(shown.rawValue)")
  }

  @Test func aFailedRemovalStaysInTheInbox() {
    #expect(appliedModel(Self.list).triage.contains { $0.id == "f" })
  }

  @Test func aFailedRemovalStaysInTheSidebar() {
    let rows = appliedModel(Self.list).sidebarGroups.flatMap { $0.rows.map(\.id) }

    #expect(rows.contains("f"))
  }

  /// The org filter's "N hidden" count names sessions that the filter hides, not sessions being deleted.
  @Test func theHiddenCountLeavesOutHeldSessions() {
    #expect(appliedModel(Self.list).hiddenCount == 0)
  }

  @Test func allSessionsStillHoldsTheHeldSessions() {
    #expect(Set(appliedModel(Self.list).allSessions.map(\.id)).isSuperset(of: Self.held))
  }

  @Test(arguments: [Removal.State.queued, .running])
  func aSelectedSessionThatTheJobHoldsLosesTheSelection(_ state: Removal.State) {
    let model = appliedModel([removalSession("a", nil), removalSession("b", nil)])
    model.selection = "a"

    model.apply(.success([removalSession("a", state), removalSession("b", nil)]), followups: nil)

    #expect(model.selection == nil)
  }

  @Test func aSelectedSessionWhoseRemovalFailedKeepsTheSelection() {
    let model = appliedModel([removalSession("a", nil), removalSession("b", nil)])
    model.selection = "a"

    model.apply(.success([removalSession("a", .failed), removalSession("b", nil)]), followups: nil)

    #expect(model.selection == "a")
  }
}

/// Stopping a held session's claude can move it to Needs you, and the delete should not notify for it.
@MainActor
@Suite struct RemovalNotifications {
  @Test func aHeldSessionThatStartsNeedingYouDoesNotNotify() {
    let model = appliedModel([removalSession("q", nil, state: .working)])

    #expect(model.sessionsToNotify([removalSession("q", .queued, state: .needsYou)]).isEmpty)
    #expect(model.sessionsToNotify([removalSession("q", nil, state: .needsYou)]).map(\.id) == ["q"])
  }
}

/// The "Removing N sessions…" row at the bottom of the sidebar.
@MainActor
@Suite struct RemovalStatusRow {
  static let notice = RemovalNotice(id: 7, session: "gone", name: "gone", message: "the branch feat stayed")

  @Test func noRemovalAndNoNoticeShowsNoRow() {
    #expect(appliedModel([removalSession("p", nil)]).removalStatus == nil)
  }

  /// A failed session shows in the Inbox with Retry and Keep, so the row does not count it.
  @Test func aFailedRemovalAloneShowsNoRow() {
    #expect(appliedModel([removalSession("f", .failed)]).removalStatus == nil)
  }

  @Test func queuedAndRunningSessionsShowTheRowWithTheirCount() throws {
    let model = appliedModel([
      removalSession("p", nil), removalSession("q", .queued), removalSession("r", .running, state: .working),
      removalSession("f", .failed),
    ])

    let status = try #require(model.removalStatus)

    #expect(status.count == 2)
    #expect(Set(status.sessions.map(\.id)) == ["q", "r"])
  }

  @Test func heldSessionsWithoutANoticeShowNoWarning() throws {
    let model = appliedModel([removalSession("q", .queued)])

    let status = try #require(model.removalStatus)

    #expect(!status.warning)
  }

  @Test func aNoticeAloneShowsTheRowWithAWarning() throws {
    let model = appliedModel([removalSession("p", nil)])
    model.removalNotices = [Self.notice]

    let status = try #require(model.removalStatus)

    #expect(status.warning)
    #expect(status.notices == [Self.notice])
    #expect(status.title == "1 delete notice")
  }

  @Test func heldSessionsAndANoticeShowTheCountAndTheWarning() throws {
    let model = appliedModel([removalSession("q", .queued)])
    model.removalNotices = [Self.notice]

    let status = try #require(model.removalStatus)

    #expect(status.count == 1)
    #expect(status.warning)
  }

  @Test(arguments: [(1, "Removing 1 session…"), (3, "Removing 3 sessions…")])
  func theRowNamesHowManySessionsTheJobHolds(_ count: Int, _ expected: String) {
    #expect(DoneRemovalText.removing(count) == expected)
  }

  @Test func theRowTitleEndsWithAnEllipsisCharacter() {
    let text = DoneRemovalText.removing(3)

    #expect(text.hasSuffix("\u{2026}"))
    #expect(!text.contains("..."))
  }

  // MARK: Undo

  /// Only a queued session whose `notBefore` is still ahead can come back. A running one already stopped claude,
  /// and a queued one past its `notBefore` may start at any moment.
  @Test func undoableListsOnlyTheQueuedSessionsBeforeTheirNotBefore() throws {
    let model = appliedModel([
      undoSession("ahead", notBefore: 10_000), undoSession("ahead2", notBefore: 12_000),
      undoSession("running", .running, notBefore: 10_000), undoSession("past", notBefore: 4_000),
      undoSession("failed", .failed, notBefore: 10_000),
    ])

    let status = try #require(model.removalStatus)

    #expect(Set(status.undoable(now: 5_000)) == ["ahead", "ahead2"])
  }

  /// The worker may start the session at `notBefore`, so Undo goes at that moment, not a moment later.
  @Test(arguments: [(9_999, ["q"]), (10_000, []), (10_001, [])] as [(Int64, [String])])
  func aQueuedSessionIsUndoableOnlyStrictlyBeforeItsNotBefore(_ now: Int64, _ expected: [String]) throws {
    let model = appliedModel([undoSession("q", notBefore: 10_000)])

    let status = try #require(model.removalStatus)

    #expect(status.undoable(now: now) == expected)
  }

  /// The row redraws at each deadline, so Undo goes when the first undoable session reaches its `notBefore`.
  @Test func undoDeadlinesAreTheNotBeforesOfTheUndoableSessionsInOrder() throws {
    let model = appliedModel([
      undoSession("later", notBefore: 12_000), undoSession("ahead", notBefore: 10_000),
      undoSession("running", .running, notBefore: 11_000), undoSession("past", notBefore: 4_000),
    ])

    let status = try #require(model.removalStatus)

    #expect(status.undoDeadlines(now: 5_000) == [10_000, 12_000].map { Date(timeIntervalSince1970: $0 / 1000) })
  }

  /// The row shows Undo while `undoable` is not empty. Once every session has started, the row stays and Undo goes.
  @Test func theRowStaysWithoutUndoOnceEverySessionIsPastItsNotBefore() throws {
    let model = appliedModel([undoSession("q", notBefore: 10_000), undoSession("r", .running, notBefore: 9_000)])

    let status = try #require(model.removalStatus)

    #expect(status.undoable(now: 10_000).isEmpty)
    #expect(status.count == 2)
  }
}

/// Retry and Keep on a failed session, and Dismiss on a removal notice.
@MainActor
@Suite struct RemovalActions {
  @Test func retrySendsRmRetryForTheSession() async {
    let request = await firstRequest { $0.retryRemoval("f") }

    #expect(request.op == "rm-retry")
    #expect(request.args == ["session": "f"])
  }

  @Test func keepSendsRmKeepForTheSession() async {
    let request = await firstRequest { $0.keepRemoval("f") }

    #expect(request.op == "rm-keep")
    #expect(request.args == ["session": "f"])
  }

  /// sbd reads the notice's id as a number and refuses a string.
  @Test func dismissSendsRemovalNoticeDismissWithTheNoticesNumericID() async {
    let request = await firstRequest { $0.dismissRemovalNotice(7) }

    #expect(request.op == "removal-notice-dismiss")
    #expect(request.args["id"]?.int == 7)
  }

  // MARK: Undo

  /// The model as the row's Undo finds it: two sessions before their `notBefore`, one past it, and one running.
  func undoModel(_ sent: SentRequests, reply: JSON = ["cancelled": [], "refused": []]) -> BoardModel {
    let model = appliedModel([
      undoSession("a", notBefore: 10_000), undoSession("b", notBefore: 11_000), undoSession("past", notBefore: 4_000),
      undoSession("running", .running, notBefore: 10_000),
    ])
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-cancel" ? reply : .null
    }
    return model
  }

  @Test func undoSendsOneRmCancelWithEveryUndoableID() async throws {
    let sent = SentRequests()
    let model = undoModel(sent)

    model.undoRemovals(now: 5_000)
    await settle { sent.ops.contains("rm-cancel") }

    let cancels = sent.value.filter { $0.op == "rm-cancel" }
    #expect(cancels.count == 1)
    let ids = try #require(cancels.first?.args["sessions"]?.array, "\(cancels)")
    #expect(Set(ids.compactMap(\.string)) == ["a", "b"])
    #expect(ids.count == 2)
  }

  /// The request after Undo, on Undo's serial queue, marks the point by which Undo's own request would have
  /// reached sbd.
  @Test func undoWithNothingBeforeItsNotBeforeSendsNothing() async {
    let sent = SentRequests()
    let model = undoModel(sent)

    model.undoRemovals(now: 20_000)
    model.perform("after", [:], on: model.undos)
    await settle { sent.ops.contains("after") }

    #expect(!sent.ops.contains("rm-cancel"))
  }

  /// The header's `rm --worktree` can hold `worker` for minutes, and Undo must reach sbd before `notBefore`.
  @Test func undoIsSentWhileWorkerIsBusy() async {
    let sent = SentRequests()
    let model = undoModel(sent)
    let gate = DispatchSemaphore(value: 0)
    let send = model.send
    model.send = { op, args in
      if op == "hold" { gate.wait() }
      return try send(op, args)
    }
    model.perform("hold", [:])

    model.undoRemovals(now: 5_000)
    await settle { sent.ops.contains("rm-cancel") }
    let sentWhileHeld = sent.ops.contains("rm-cancel")

    gate.signal()
    #expect(sentWhileHeld)
  }

  /// sbd refuses a session that started between the click and the request. The user learns that it stays deleted.
  @Test func aRefusedUndoShowsTheReasonInTheBanner() async {
    let reply: JSON = [
      "cancelled": ["b"],
      "refused": [["id": "a", "name": "a", "reason": "a is being deleted"]],
    ]
    let model = undoModel(SentRequests(), reply: reply)

    model.undoRemovals(now: 5_000)
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains("a is being deleted") == true, "\(model.actionError ?? "nil")")
  }

  /// The refresh after the reply comes later, so the cancelled sessions are no longer undoable in the meantime, and
  /// a second click does not send them again.
  @Test func undoClearsTheCancelledRemovalsBeforeTheRefresh() async {
    let sent = SentRequests()
    let model = undoModel(sent, reply: ["cancelled": ["a", "b"], "refused": []])

    model.undoRemovals(now: 5_000)
    await settle { sent.ops.contains("rm-cancel") && model.answeringRemovals.isEmpty }

    #expect(model.removalStatus?.undoable(now: 5_000) ?? [] == [])
    #expect(model.allSessions.first { $0.id == "a" }?.removal == nil)
  }

  @Test func keepClearsTheRemovalBeforeTheRefresh() async {
    let model = appliedModel([removalSession("f", .failed)])
    model.send = { _, _ in .null }

    model.keepRemoval("f")
    await settle { model.allSessions.first?.removal == nil }

    #expect(model.allSessions.first?.removal == nil)
  }

  /// A retried session is held again, so the Inbox drops it and its Retry button with it.
  @Test func retryQueuesTheRemovalBeforeTheRefresh() async {
    let model = appliedModel([removalSession("f", .failed)])
    model.send = { _, _ in .null }

    model.retryRemoval("f")
    await settle { model.allSessions.first?.removal?.state == .queued }

    #expect(model.allSessions.first?.isBeingRemoved == true)
  }

  /// A cancelled session returns to the lists unselected.
  @Test func aSessionThatUndoBringsBackReturnsToTheListsUnselected() {
    let model = appliedModel([removalSession("a", nil), removalSession("b", nil)])
    model.selection = "a"
    model.apply(.success([undoSession("a", notBefore: 10_000), removalSession("b", nil)]), followups: nil)

    model.apply(.success([removalSession("a", nil), removalSession("b", nil)]), followups: nil)

    #expect(model.sessions.contains { $0.id == "a" })
    #expect(model.selection == nil)
  }
}
