import AppKit
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let targetID = "seb4ec"
private let otherID = "s3k9ap"
private let goneID = "sgcctv"
private let thirdID = "s23456"

/// A work session with no Inbox item.
private func workSession(_ id: String, state: AttentionState = .working) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.triage = nil
  return s
}

/// A Manager conversation, archived when `archived` is true.
private func conversation(_ id: String, lastActivity: Int64, archived: Bool? = nil) -> SessionSummary {
  var s = needsItem(id, manager: true)
  s.triage = nil
  s.lastActivity = lastActivity
  s.lastReply = "Done."
  s.activity = ChatActivity(replies: 1, unread: 0, lastMessageAt: lastActivity, archived: archived)
  return s
}

/// `switchboard:` URLs that `url(for:)` does not build. A URL that names a session names `targetID`, which each
/// test lists. Only the parser can then refuse it.
private let malformedLinks = [
  "SWITCHBOARD://session/seb4ec",
  "switchboard://session/seb4ec?x=1",
  "switchboard://session/seb4ec/",
  "switchboard://other/seb4ec",
  "switchboard:seb4ec",
  "switchboard://session/seb4e",
  "switchboard://",
]

private func tombstone(_ id: String) -> RemovedSession {
  RemovedSession(id: id, name: "old-flag-cleanup", removed: 1_794_377_400_000)
}

/// `focus(id)` is the path that `sb focus` and a `switchboard://session/<id>` URL reach. It shows the session
/// as a sidebar click does.
@MainActor
@Suite struct BoardModelFocusTests {
  // MARK: A listed session

  @Test func focusOnAListedSessionSelectsIt() {
    let model = appliedModel([workSession(targetID), workSession(otherID)])

    model.focus(targetID)

    #expect(model.selection == targetID)
  }

  @Test func focusOnAListedSessionShowsTheWindowOnce() {
    let model = appliedModel([workSession(targetID)])
    let shown = Counter()
    model.showWindow = { shown.increment() }

    model.focus(targetID)

    #expect(shown.value == 1)
  }

  @Test func focusClosesTheSearchPanel() {
    let model = appliedModel([workSession(targetID)])
    model.showingSearch = true

    model.focus(targetID)

    #expect(!model.showingSearch)
  }

  @Test func focusClosesRecentPlaces() {
    let model = appliedModel([workSession(targetID)])
    model.showingRecentPlaces = true

    model.focus(targetID)

    #expect(!model.showingRecentPlaces)
  }

  @Test func focusOnAListedSessionLeavesNoError() {
    let model = appliedModel([workSession(targetID)])

    model.focus(targetID)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test func focusOnAFollowupThatHasNotStartedOpensItsSection() throws {
    let model = appliedModel([workSession(otherID)], followups: [unstartedFollowup(targetID)])
    try #require(!model.sidebarOrder.contains(targetID))

    model.focus(targetID)

    #expect(model.selection == targetID)
    #expect(model.sidebarOrder.contains(targetID))
  }

  @Test func focusOnAnArchivedConversationOpensTheArchive() throws {
    let model = appliedModel([
      conversation(otherID, lastActivity: 30), conversation(targetID, lastActivity: 2, archived: true),
      workSession(thirdID),
    ])
    try #require(!model.sidebarOrder.contains(targetID))

    model.focus(targetID)

    #expect(model.selection == targetID)
    #expect(model.showingArchive)
    #expect(model.sidebarOrder.contains(targetID))
  }

  @Test func focusOnASessionThatTheOrgFilterHidesShowsItsOrg() throws {
    let model = orgFilterModel(posthogOnly)
    model.apply(
      .success([orgSession("sph234", "PostHog/posthog"), orgSession(targetID, "haacked/switchboard")]),
      followups: nil)
    try #require(!model.sessions.contains { $0.id == targetID })

    model.focus(targetID)

    #expect(model.selection == targetID)
    #expect(model.sessions.contains { $0.id == targetID })
  }

  @Test func focusRequestsListFocus() {
    let model = appliedModel([workSession(targetID)])
    let before = model.listFocusRequests

    model.focus(targetID)

    #expect(model.listFocusRequests > before)
  }

  // MARK: History

  @Test func focusFromTheInboxAddsOneHistoryEntry() throws {
    let model = appliedModel([needsItem(targetID), needsItem(otherID), needsItem(thirdID)])
    try #require(model.selection == nil)
    let before = model.history.entries.count

    model.focus(otherID)

    #expect(model.history.entries.count == before + 1)
  }

  @Test func backAfterFocusFromTheInboxReturnsToTheInbox() throws {
    let model = appliedModel([needsItem(targetID), needsItem(otherID), needsItem(thirdID)])
    try #require(model.selection == nil)
    let start = model.history.current

    model.focus(otherID)
    model.goBack()

    #expect(model.selection == nil)
    #expect(model.mainView == .inbox)
    #expect(model.history.current == start)
  }

  // MARK: Sheets

  enum Sheet: String, CaseIterable {
    case newSession, importSessions, issueSetup

    @MainActor func open(on model: BoardModel) {
      switch self {
      case .newSession: model.openNewSession()
      case .importSessions: model.showingImport = true
      case .issueSetup: model.showingIssueSetup = true
      }
    }

    @MainActor func isOpen(on model: BoardModel) -> Bool {
      switch self {
      case .newSession: model.newSession != nil
      case .importSessions: model.showingImport
      case .issueSetup: model.showingIssueSetup
      }
    }
  }

  @Test(arguments: Sheet.allCases)
  func focusLeavesAnOpenSheetOpen(_ sheet: Sheet) {
    let model = appliedModel([workSession(targetID)])
    sheet.open(on: model)

    model.focus(targetID)

    #expect(sheet.isOpen(on: model))
  }

  @Test(arguments: Sheet.allCases)
  func focusWithAnOpenSheetChangesTheSelection(_ sheet: Sheet) {
    let model = appliedModel([workSession(targetID)])
    sheet.open(on: model)

    model.focus(targetID)

    #expect(model.selection == targetID)
  }

  // MARK: A session that no refresh has listed yet

  @Test func focusBeforeTheFirstApplySelectsNothingYet() {
    let model = offlineModel()

    model.focus(targetID)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == targetID)
  }

  @Test func focusBeforeTheFirstApplySelectsTheSessionAtTheApplyThatListsIt() {
    let model = offlineModel()
    model.focus(targetID)

    model.apply(.success([workSession(targetID)]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.actionError == nil)
    #expect(model.pendingFocus == nil)
  }

  @Test func aPendingFocusOnASessionListedOnlyAtTheSecondApplyWaitsForIt() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == targetID)
    #expect(model.actionError == nil)
  }

  @Test func aPendingFocusOnASessionListedOnlyAtTheSecondApplySelectsItThen() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)
    model.apply(.success([workSession(otherID)]), followups: nil)

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == targetID)
    #expect(model.pendingFocus == nil)
    #expect(model.actionError == nil)
  }

  /// A follow-up that `sb new` or a plan just made shows first in `followup-ls`, not in `ls`.
  @Test func aPendingFocusOnAFollowupSelectsItAndOpensItsSection() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    model.apply(.success([workSession(otherID)]), followups: [unstartedFollowup(targetID)])

    #expect(model.selection == targetID)
    #expect(model.sidebarOrder.contains(targetID))
    #expect(model.pendingFocus == nil)
  }

  @Test func aPendingFocusOnASessionThatTheOrgFilterHidesSelectsItAndShowsItsOrg() {
    let model = orgFilterModel(posthogOnly)
    model.apply(.success([orgSession("sph234", "PostHog/posthog")]), followups: nil)
    model.focus(targetID)

    model.apply(
      .success([orgSession("sph234", "PostHog/posthog"), orgSession(targetID, "haacked/switchboard")]),
      followups: nil)

    #expect(model.selection == targetID)
    #expect(model.sessions.contains { $0.id == targetID })
  }

  // MARK: A session that no refresh lists

  @Test func aPendingFocusSetsNoErrorAfterTwoSuccessfulApplies() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == targetID)
  }

  @Test func aPendingFocusOnASessionThatARefreshReportsRemovedSetsTheRemovedError() {
    let model = appliedModel([workSession(otherID)])
    model.focus(goneID)

    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    #expect(model.actionError?.contains("removed") == true)
    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  /// A session that the user selects while a focus waits stays selected when the focused session appears.
  @Test func aSelectionMadeWhileAFocusWaitsEndsTheWait() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)
    model.selection = otherID

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
    #expect(model.actionError == nil)
  }

  @Test func aPendingFocusGivesUpAtTheThirdSuccessfulApply() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    for _ in 0..<3 { model.apply(.success([workSession(otherID)]), followups: nil) }

    #expect(model.actionError == "Switchboard has no session \(targetID)")
    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  @Test func aFailedApplyDoesNotCountTowardGivingUp() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.failure(Boom()), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == nil)
    #expect(model.pendingFocus == targetID)
  }

  @Test func aFailedApplyBetweenSuccessesStillGivesUpAtTheThirdSuccess() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)

    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.failure(Boom()), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)
    model.apply(.success([workSession(otherID)]), followups: nil)

    #expect(model.actionError == "Switchboard has no session \(targetID)")
    #expect(model.pendingFocus == nil)
  }

  /// After giving up, a later refresh that lists the id must not select it.
  @Test func aSessionListedAfterThePendingFocusGaveUpIsNotSelected() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)
    for _ in 0..<3 { model.apply(.success([workSession(otherID)]), followups: nil) }

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == nil)
  }

  // MARK: A removed session

  @Test func focusOnARemovedSessionSetsTheRemovedErrorAtOnce() {
    let model = offlineModel()
    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    model.focus(goneID)

    #expect(model.actionError?.contains("removed") == true)
  }

  @Test func focusOnARemovedSessionLeavesNoPendingFocusAndSelectsNothing() {
    let model = offlineModel()
    model.apply(.success([workSession(otherID)]), followups: nil, removed: [tombstone(goneID)])

    model.focus(goneID)

    #expect(model.pendingFocus == nil)
    #expect(model.selection == nil)
  }

  // MARK: A newer focus replaces the pending one

  @Test func aSecondFocusBeforeTheFirstResolvesSelectsOnlyTheSecond() {
    let model = appliedModel([workSession(thirdID)])
    model.focus(targetID)
    model.focus(otherID)

    model.apply(.success([workSession(thirdID), workSession(targetID), workSession(otherID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
  }

  @Test func anApplyThatListsOnlyTheReplacedIdSelectsNothing() {
    let model = appliedModel([workSession(thirdID)])
    model.focus(targetID)
    model.focus(otherID)

    model.apply(.success([workSession(thirdID), workSession(targetID)]), followups: nil)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == otherID)
  }

  /// A focus on a listed session drops a pending focus, so a later refresh can't move the selection away.
  @Test func aFocusOnAListedSessionDropsAPendingFocus() {
    let model = appliedModel([workSession(otherID)])
    model.focus(targetID)
    model.focus(otherID)

    model.apply(.success([workSession(otherID), workSession(targetID)]), followups: nil)

    #expect(model.selection == otherID)
    #expect(model.pendingFocus == nil)
  }

  // MARK: External links

  @Test func anExternalLinkToAListedSessionSelectsIt() {
    let model = appliedModel([workSession(targetID)])

    model.openExternalLink(SessionLink.url(for: targetID))

    #expect(model.selection == targetID)
  }

  @Test(arguments: malformedLinks)
  func aMalformedSwitchboardLinkSetsAnError(_ string: String) throws {
    let model = appliedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    model.openExternalLink(url)

    #expect(model.actionError != nil)
  }

  @Test(arguments: malformedLinks)
  func aMalformedSwitchboardLinkSelectsNothing(_ string: String) throws {
    let model = appliedModel([workSession(targetID)])
    let url = try #require(URL(string: string))

    model.openExternalLink(url)

    #expect(model.selection == nil)
    #expect(model.pendingFocus == nil)
  }
}
