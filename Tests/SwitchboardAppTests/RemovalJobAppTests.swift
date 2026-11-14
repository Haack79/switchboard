import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A session in `state` whose removal sbd's job holds as `removal`, or with no removal when `removal` is nil.
func removalSession(_ id: String, _ removal: Removal.State?, state: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.removal = removal.map { removal in
    var value = Removal(requested: 1, worktree: true, branch: false, remoteBranch: false, resolve: [])
    value.state = removal
    if removal == .failed {
      value.error = "/tmp has uncommitted files (1)."
      s.reason = "Delete failed: /tmp has uncommitted files (1)."
    }
    return value
  }
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
}
