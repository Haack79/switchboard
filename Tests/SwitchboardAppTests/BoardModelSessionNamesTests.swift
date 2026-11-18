import AppKit
import Combine
import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let otherID = "s3k9ap"
private let otherName = "flag-cache-race"
private let goneID = "sgcctv"
private let goneName = "old-flag-cleanup"

/// A work session with a real-shaped id and a name that differs from it.
private func named(_ id: String, _ name: String, state: AttentionState = .working, reason: String = "")
  -> SessionSummary
{
  var s = needsItem(id, state: state)
  s.name = name
  s.reason = reason
  return s
}

private func tombstone(_ id: String, _ name: String, removed: Int64 = 1_794_377_400_000) -> RemovedSession {
  RemovedSession(id: id, name: name, removed: removed)
}

@MainActor
@Suite struct BoardModelSessionNamesTests {
  // MARK: Sources

  @Test func aListedSessionResolvesToItsName() {
    let model = offlineModel()

    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  @Test func aFollowupThatWaitsToStartResolves() {
    let model = offlineModel()
    var followup = unstartedFollowup(liveID)
    followup.name = liveName

    model.apply(.success([]), followups: [followup], removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  /// The directory reads `allSessions`, not the org-filtered `sessions`.
  @Test func aSessionThatTheOrgFilterHidesResolves() throws {
    let model = orgFilterModel(posthogOnly)
    var hidden = orgSession(liveID, "haacked/switchboard")
    hidden.name = liveName

    model.apply(.success([orgSession("sph234", "PostHog/posthog"), hidden]), followups: nil, removed: nil)

    try #require(!model.sessions.contains { $0.id == liveID })
    #expect(model.sessionNames.entry(liveID)?.name == liveName)
  }

  @Test func aFollowupThatTheOrgFilterHidesResolves() {
    let model = orgFilterModel(posthogOnly)
    var followup = unstartedFollowup(liveID, "haacked/x")
    followup.name = liveName

    model.apply(.success([]), followups: [followup], removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
  }

  @Test func aTombstoneResolvesAsRemoved() {
    let model = offlineModel()

    model.apply(.success([]), followups: nil, removed: [tombstone(goneID, goneName)])

    #expect(model.sessionNames.entry(goneID)?.name == goneName)
    #expect(model.sessionNames.entry(goneID)?.removed == true)
  }

  @Test func aLiveSessionWinsOverATombstoneForTheSameId() {
    let model = offlineModel()

    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [tombstone(liveID, "older-name")])

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  @Test func aRenameShowsOnTheNextRefresh() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

    model.apply(.success([named(liveID, "renamed-session")]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == "renamed-session")
  }

  // MARK: Only grows

  /// An id that just left `ls` keeps its name, so a mention of it does not
  /// flicker back to the bare id before `removed-ls` lists it.
  @Test func anIdThatLeavesTheListStaysWithItsLastNameMarkedRemoved() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName), named(otherID, otherName)]), followups: nil, removed: nil)

    model.apply(.success([named(otherID, otherName)]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == true)
  }

  @Test func aTombstoneForAnIdThatLeftTheListGivesTheTombstonesName() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
    model.apply(.success([]), followups: nil, removed: nil)

    model.apply(.success([]), followups: nil, removed: [tombstone(liveID, "name-at-removal")])

    #expect(model.sessionNames.entry(liveID)?.name == "name-at-removal")
    #expect(model.sessionNames.entry(liveID)?.removed == true)
  }

  @Test func aFollowupThatLeavesBothListsStaysMarkedRemoved() {
    let model = offlineModel()
    var followup = unstartedFollowup(liveID)
    followup.name = liveName
    model.apply(.success([]), followups: [followup], removed: nil)

    model.apply(.success([]), followups: [], removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == true)
  }

  @Test func aFollowupThatStartsStaysLive() {
    let model = offlineModel()
    var followup = unstartedFollowup(liveID)
    followup.name = liveName
    model.apply(.success([]), followups: [followup], removed: nil)

    model.apply(.success([named(liveID, liveName)]), followups: [], removed: nil)

    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  /// sbd that does not answer has not removed every session.
  @Test func aFailedRefreshKeepsEverySessionLive() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

    model.apply(.failure(Boom()), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  /// Most refreshes do not read `followup-ls`, and pass nil for it.
  @Test func aRefreshThatDoesNotReadFollowupsKeepsAFollowupLive() {
    let model = offlineModel()
    var followup = unstartedFollowup(liveID)
    followup.name = liveName
    model.apply(.success([]), followups: [followup], removed: nil)

    model.apply(.success([]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  /// Most refreshes do not read `removed-ls`, and pass nil for it.
  @Test func aRefreshThatDoesNotReadTombstonesKeepsThem() {
    let model = offlineModel()
    model.apply(.success([]), followups: nil, removed: [tombstone(goneID, goneName)])

    model.apply(.success([]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(goneID)?.name == goneName)
  }

  @Test func aTombstoneThatALaterListLeavesOutStillResolves() {
    let model = offlineModel()
    model.apply(.success([]), followups: nil, removed: [tombstone(goneID, goneName)])

    model.apply(.success([]), followups: nil, removed: [])

    #expect(model.sessionNames.entry(goneID)?.name == goneName)
    #expect(model.sessionNames.entry(goneID)?.removed == true)
  }

  @Test func aRemovedIdThatTheListShowsAgainIsLive() {
    let model = offlineModel()
    model.apply(.success([]), followups: nil, removed: [tombstone(liveID, "older-name")])

    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

    #expect(model.sessionNames.entry(liveID)?.name == liveName)
    #expect(model.sessionNames.entry(liveID)?.removed == false)
  }

  // MARK: Reading removed-ls again

  @Test func aFailedRemovedReadReadsAgain() {
    let model = offlineModel()
    _ = model.takeRemovedRead()

    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil, readRemoved: true)

    #expect(model.readRemovedNext)
  }

  /// A failed `ls` drops the `removed-ls` answer, so the next refresh reads it again.
  @Test func aFailedListReadsRemovedAgain() {
    let model = offlineModel()
    _ = model.takeRemovedRead()

    model.apply(.failure(Boom()), followups: nil, removed: [tombstone(goneID, goneName)], readRemoved: true)

    #expect(model.readRemovedNext)
  }

  @Test func anIdThatLeavesTheListReadsRemovedAgain() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName), named(otherID, otherName)]), followups: nil, removed: [])
    _ = model.takeRemovedRead()

    model.apply(.success([named(otherID, otherName)]), followups: nil, removed: nil)

    #expect(model.readRemovedNext)
  }

  @Test func aSuccessfulReadOfAnUnchangedListDoesNotReadAgain() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [])
    _ = model.takeRemovedRead()

    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [], readRemoved: true)

    #expect(!model.readRemovedNext)
  }

  // MARK: Publishing

  /// A changed reason republishes `allSessions`. It changes no id or name, so
  /// the views that read the directory do not redraw for it.
  @Test func aRefreshThatChangesNoIdOrNameDoesNotRepublishTheDirectory() {
    let model = offlineModel()
    model.apply(
      .success([named(liveID, liveName, reason: "Running the tests")]), followups: nil,
      removed: [tombstone(goneID, goneName)])
    var published = 0
    let subscription = model.$sessionNames.dropFirst().sink { _ in published += 1 }
    defer { subscription.cancel() }

    model.apply(
      .success([named(liveID, liveName, reason: "Asked which flag to remove")]), followups: nil,
      removed: [tombstone(goneID, goneName)])

    #expect(published == 0)
  }

  @Test func aRefreshWithTheSameListDoesNotPublish() {
    let model = offlineModel()
    let list = [named(liveID, liveName)]
    model.apply(.success(list), followups: [], removed: [tombstone(goneID, goneName)])
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.apply(.success(list), followups: [], removed: [tombstone(goneID, goneName)])

    #expect(published == 0)
  }

  @Test func aRenameRepublishesTheDirectory() {
    let model = offlineModel()
    model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
    var published = 0
    let subscription = model.$sessionNames.dropFirst().sink { _ in published += 1 }
    defer { subscription.cancel() }

    model.apply(.success([named(liveID, "renamed-session")]), followups: nil, removed: nil)

    #expect(published == 1)
  }

  @Test func aNewTombstoneRepublishesTheDirectory() {
    let model = offlineModel()
    model.apply(.success([]), followups: nil, removed: [])
    var published = 0
    let subscription = model.$sessionNames.dropFirst().sink { _ in published += 1 }
    defer { subscription.cancel() }

    model.apply(.success([]), followups: nil, removed: [tombstone(goneID, goneName)])

    #expect(published == 1)
  }

  // MARK: Links

  @MainActor
  @Suite struct LinkHandler {
    @Test func aSessionLinkRevealsTheSession() {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

      let handled = model.openSessionLink(SessionLink.url(for: liveID))

      #expect(handled)
      #expect(model.selection == liveID)
    }

    /// `reveal` is the notification-click path, and the only one that shows the window.
    @Test func aSessionLinkShowsTheWindowThroughReveal() {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
      let shown = Counter()
      model.showWindow = { shown.increment() }

      _ = model.openSessionLink(SessionLink.url(for: liveID))

      #expect(shown.value == 1)
    }

    /// `reveal` widens the org filter, so a link to a hidden session never opens nothing.
    @Test func aLinkToASessionThatTheOrgFilterHidesShowsItsOrg() {
      let model = orgFilterModel(posthogOnly)
      model.apply(
        .success([orgSession("sph234", "PostHog/posthog"), orgSession(liveID, "haacked/switchboard")]),
        followups: nil, removed: nil)

      _ = model.openSessionLink(SessionLink.url(for: liveID))

      #expect(model.selection == liveID)
      #expect(model.sessions.contains { $0.id == liveID })
    }

    /// The app keeps a link to a session that is gone and selects nothing. Launch Services would otherwise hand the
    /// link to whichever build of the app it picks. The click comes from the window, so the window is not shown again.
    @Test(arguments: [goneID, "sxxxxx"])
    func aLinkToASessionThatIsGoneIsHandledAndRevealsNothing(_ id: String) {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [tombstone(goneID, goneName)])
      let shown = Counter()
      model.showWindow = { shown.increment() }

      let handled = model.openSessionLink(SessionLink.url(for: id))

      #expect(handled)
      #expect(model.selection == nil)
      #expect(shown.value == 0)
    }

    /// An in-app click on a link to a session that is gone sets the banner at once and leaves nothing for a later
    /// refresh to select.
    @Test(arguments: [(goneID, "Session \(goneID) was removed"), ("sxxxxx", "Switchboard has no session sxxxxx")])
    func aLinkToASessionThatIsGoneSetsTheBannerAndNoPendingFocus(_ id: String, _ banner: String) {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [tombstone(goneID, goneName)])

      _ = model.openSessionLink(SessionLink.url(for: id))

      #expect(model.actionError == banner)
      #expect(model.pendingFocus == nil)
    }

    /// The app claims its whole scheme, so Launch Services never hands one of its links to another build.
    @Test(arguments: [
      "switchboard:seb4ec",
      "switchboard:/session/seb4ec",
      "switchboard:///session/seb4ec",
      "Switchboard://session/seb4ec",
      "SWITCHBOARD://session/seb4ec",
      "switchboard://SESSION/seb4ec",
      "switchboard://session/seb4ec?x=1",
      "switchboard://session/seb4ec#top",
      "switchboard://session/seb4ec/",
      "switchboard://other/seb4ec",
      "switchboard://",
      "switchboard:",
    ])
    func aSwitchboardURLThatDoesNotParseIsHandledAndRevealsNothing(_ string: String) throws {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
      let url = try #require(URL(string: string))
      let shown = Counter()
      model.showWindow = { shown.increment() }

      let handled = model.openSessionLink(url)

      #expect(handled)
      #expect(model.selection == nil)
      #expect(shown.value == 0)
    }

    @Test(arguments: [
      "https://github.com/haacked/switchboard/pull/309",
      "https://example.com/seb4ec",
      "https://session/seb4ec",
      "file:///tmp/seb4ec",
      "switchboard-session:",
      "switchboard-session:seb4ec",
      "switchboard-session://seb4ec",
      "switchboards://session/seb4ec",
      "other:seb4ec",
    ])
    func anotherURLIsLeftToTheSystem(_ string: String) throws {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
      let url = try #require(URL(string: string))
      let shown = Counter()
      model.showWindow = { shown.increment() }

      let handled = model.openSessionLink(url)

      #expect(!handled)
      #expect(model.selection == nil)
      #expect(shown.value == 0)
    }
  }

  // MARK: In-app and external links

  /// An in-app click goes through `openSessionLink`. A URL from another app goes through `openExternalLink`.
  enum LinkPath: String, CaseIterable {
    case inApp, external

    @MainActor func open(_ url: URL, on model: BoardModel) {
      switch self {
      case .inApp: _ = model.openSessionLink(url)
      case .external: model.openExternalLink(url)
      }
    }
  }

  /// Both paths take the same link to a live session to the same place.
  @MainActor
  @Suite struct LinkParity {
    @Test func bothPathsSelectALiveSession() {
      let inApp = offlineModel()
      let external = offlineModel()
      for model in [inApp, external] {
        model.apply(.success([named(liveID, liveName), named(otherID, otherName)]), followups: nil, removed: nil)
      }

      LinkPath.inApp.open(SessionLink.url(for: liveID), on: inApp)
      LinkPath.external.open(SessionLink.url(for: liveID), on: external)

      #expect(inApp.selection == liveID)
      #expect(external.selection == inApp.selection)
    }

    @Test(arguments: LinkPath.allCases)
    func aLiveLinkShowsTheWindowOnce(_ path: LinkPath) {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)
      let shown = Counter()
      model.showWindow = { shown.increment() }

      path.open(SessionLink.url(for: liveID), on: model)

      #expect(shown.value == 1)
    }

    @Test(arguments: LinkPath.allCases)
    func aLiveLinkToAFollowupThatHasNotStartedOpensItsSection(_ path: LinkPath) throws {
      let model = offlineModel()
      var followup = unstartedFollowup(liveID)
      followup.name = liveName
      model.apply(.success([named(otherID, otherName)]), followups: [followup], removed: nil)
      try #require(!model.sidebarOrder.contains(liveID))

      path.open(SessionLink.url(for: liveID), on: model)

      #expect(model.selection == liveID)
      #expect(model.sidebarOrder.contains(liveID))
    }

    @Test(arguments: LinkPath.allCases)
    func aLiveLinkToASessionThatTheOrgFilterHidesShowsItsOrg(_ path: LinkPath) {
      let model = orgFilterModel(posthogOnly)
      model.apply(
        .success([orgSession("sph234", "PostHog/posthog"), orgSession(liveID, "haacked/switchboard")]),
        followups: nil, removed: nil)

      path.open(SessionLink.url(for: liveID), on: model)

      #expect(model.selection == liveID)
      #expect(model.sessions.contains { $0.id == liveID })
    }

    @Test(arguments: LinkPath.allCases)
    func aLinkToARemovedSessionSelectsNothing(_ path: LinkPath) {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [tombstone(goneID, goneName)])

      path.open(SessionLink.url(for: goneID), on: model)

      #expect(model.selection == nil)
      #expect(model.pendingFocus == nil)
    }

    /// Both paths say why the link shows nothing.
    @Test(arguments: LinkPath.allCases)
    func aLinkToARemovedSessionSetsTheRemovedError(_ path: LinkPath) {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: [tombstone(goneID, goneName)])

      path.open(SessionLink.url(for: goneID), on: model)

      #expect(model.actionError == "Session \(goneID) was removed")
    }

    /// An in-app link to an unknown id names no session the user can wait for.
    @Test func anInAppLinkToAnUnknownSessionLeavesNoPendingFocus() {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

      LinkPath.inApp.open(SessionLink.url(for: "sxxxxx"), on: model)

      #expect(model.pendingFocus == nil)
    }

    /// `sb focus` can open the link for a session that `sb new` made a moment earlier, before the app lists it.
    @Test func anExternalLinkToAnUnknownSessionWaitsForARefreshThatListsIt() {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName)]), followups: nil, removed: nil)

      LinkPath.external.open(SessionLink.url(for: "sxxxxx"), on: model)

      #expect(model.pendingFocus == .id("sxxxxx"))
    }
  }

  // MARK: Text outside SwiftUI

  @MainActor
  @Suite struct InboxLine {
    @Test func aTitleThatNamesASessionIdShowsTheSessionsName() {
      let model = offlineModel()
      var s = named(otherID, otherName, state: .needsYou)
      s.triage = TriageItem(title: "Review \(liveID)'s PR", kind: .decision, summary: "", source: .summary)
      model.apply(.success([named(liveID, liveName), s]), followups: nil, removed: nil)

      #expect(model.inboxLine(s) == "Review \(liveName)'s PR")
    }

    @Test func aReasonThatNamesASessionIdShowsTheSessionsName() {
      let model = offlineModel()
      var s = named(otherID, otherName, state: .needsYou, reason: "Waiting on \(liveID) to merge")
      s.triage = nil
      model.apply(.success([named(liveID, liveName), s]), followups: nil, removed: nil)

      #expect(model.inboxLine(s) == "Waiting on \(liveName) to merge")
    }

    @Test func aRemovedSessionShowsItsTombstoneName() {
      let model = offlineModel()
      var s = named(otherID, otherName, state: .needsYou, reason: "Waiting on \(goneID) to merge")
      s.triage = nil
      model.apply(.success([s]), followups: nil, removed: [tombstone(goneID, goneName)])

      #expect(model.inboxLine(s) == "Waiting on \(goneName) to merge")
    }

    @Test func aBodyWithoutIdsStaysAsWritten() {
      let model = offlineModel()
      var s = named(otherID, otherName, state: .needsYou, reason: "Asked which flag to remove")
      s.triage = nil
      model.apply(.success([named(liveID, liveName), s]), followups: nil, removed: nil)

      #expect(model.inboxLine(s) == "Asked which flag to remove")
    }
  }

  @MainActor
  @Suite struct DeliveryError {
    func sendCard(_ id: Int64, session: String) throws -> Card {
      let json: JSON = [
        "id": .number(Double(id)), "session": .string(session), "kind": "send", "tool": "send_group",
        "summary": "", "input": [:], "questions": [], "since": 0, "deferred": false, "hookClosed": false,
        "send": ["group": "g1", "groupName": "Flags", "text": "Rebase.", "targets": [], "expires": 0],
      ]
      return try JSONCoding.convert(json, to: Card.self)
    }

    /// A model that sent a group message whose delivery to `target` failed.
    func failedDelivery(to target: String, removed: [RemovedSession]? = nil) async throws -> BoardModel {
      let model = offlineModel()
      model.apply(.success([named(liveID, liveName), named(otherID, otherName)]), followups: nil, removed: removed)
      let answer: JSON = [
        "group": "g1", "targets": [], "sent": true,
        "deliveries": [["session": .string(target), "error": "claude is busy"]],
      ]
      model.send = { _, _ in answer }
      model.answer(try sendCard(7, session: otherID), behavior: "allow")
      await settle { model.actionError != nil }
      return model
    }

    @Test func aFailedDeliveryNamesTheTargetSession() async throws {
      let model = try await failedDelivery(to: liveID)

      #expect(model.actionError == "send: \(liveName): claude is busy")
    }

    @Test func aFailedDeliveryToARemovedSessionNamesItsTombstone() async throws {
      let model = try await failedDelivery(to: goneID, removed: [tombstone(goneID, goneName)])

      #expect(model.actionError == "send: \(goneName): claude is busy")
    }

    @Test func aFailedDeliveryToAnUnknownIdKeepsTheId() async throws {
      let model = try await failedDelivery(to: "sxxxxx")

      #expect(model.actionError == "send: sxxxxx: claude is busy")
    }
  }
}
