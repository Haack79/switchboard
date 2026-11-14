import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// ⇧⌘E reveals the Message Claude field under the terminal view that shows now. The menu item is enabled only
/// while `messageFieldTarget` names a session whose `SessionView` shows, so it never reveals a field that no view
/// draws, and it never navigates.
@MainActor
@Suite struct BoardModelMessageField {
  /// Where the window shows the session.
  enum Place: CaseIterable {
    case selection, inboxSummary, inboxTerminal, board, issues
  }

  /// The sessions the target tests cover, with the Terminal toggle where it matters.
  enum Kind: CaseIterable {
    case work, chatToggleOff, chatToggleOn, managerToggleOff, managerToggleOn
    case docketRow, followupNotStarted, unstartedFollowupWithFolder, cleanedUp

    func session(_ id: String) -> SessionSummary {
      switch self {
      case .work: return needsItem(id)
      case .chatToggleOff, .chatToggleOn: return chatItem(id, group: "g1")
      case .managerToggleOff, .managerToggleOn: return needsItem(id, manager: true)
      case .docketRow: return docketSession(id)
      case .followupNotStarted: return unstartedFollowup(id)
      case .unstartedFollowupWithFolder:
        var s = needsItem(id)
        s.followup = Followup(prompt: "p")
        return s
      case .cleanedUp:
        var s = needsItem(id, state: .done)
        s.cleanup = CleanupStatus(state: .removed)
        return s
      }
    }

    /// The Terminal toggle while the session is selected. The Inbox's toggle is its place's.
    var toggle: Bool? {
      switch self {
      case .chatToggleOff, .managerToggleOff: return false
      case .chatToggleOn, .managerToggleOn: return true
      default: return nil
      }
    }

    /// Whether the session has a Claude terminal for its `SessionView` to show.
    var hasClaudeTerminal: Bool {
      switch self {
      case .work, .chatToggleOff, .chatToggleOn, .managerToggleOff, .managerToggleOn: return true
      case .docketRow, .followupNotStarted, .unstartedFollowupWithFolder, .cleanedUp: return false
      }
    }
  }

  /// Whether `place` draws the session's `SessionView`. A selected chat or Manager draws it only while the
  /// Terminal toggle is on. The Inbox in terminal mode draws it for any session with a Claude terminal.
  static func showsTerminalView(_ kind: Kind, at place: Place) -> Bool {
    switch place {
    case .selection: return kind.hasClaudeTerminal && kind.toggle != false
    case .inboxTerminal: return kind.hasClaudeTerminal
    case .inboxSummary, .board, .issues: return false
    }
  }

  /// Every kind and place where no `SessionView` shows.
  static let untargeted: [(Kind, Place)] = Kind.allCases.flatMap { kind in
    Place.allCases.filter { !showsTerminalView(kind, at: $0) }.map { (kind, $0) }
  }

  /// A model whose current target at `place` is `target`. The session is in the Inbox list.
  static func model(_ target: SessionSummary, at place: Place, toggle: Bool? = nil) throws -> BoardModel {
    let model = appliedModel([target, needsItem("other")])
    switch place {
    case .selection:
      model.selection = target.id
      model.showingTerminal = toggle ?? false
    case .inboxSummary, .inboxTerminal:
      model.show(.inbox)
      model.inboxFocus = target.id
      model.showingTerminal = place == .inboxTerminal
      try #require(model.currentInboxItem == target.id)
    case .board:
      model.show(.board)
      model.boardGrid = BoardGrid(lanes: [[["other"], [target.id]]])
      model.boardFocus = target.id
      try #require(model.currentBoardCard == target.id)
    case .issues:
      model.show(.issues)
    }
    return model
  }

  static func model(_ kind: Kind, at place: Place) throws -> BoardModel {
    try model(kind.session("a"), at: place, toggle: place == .selection ? kind.toggle : nil)
  }

  /// Everything a reveal must leave alone, and the two ids it sets.
  struct Snapshot: Equatable {
    var selection: String?
    var mainView: MainView
    var showingTerminal: Bool
    var inboxFocus: String?
    var boardFocus: String?
    var terminalFocus: String?
    var revealedMessageField: String?
    var messageFieldFocus: String?

    @MainActor init(_ model: BoardModel) {
      selection = model.selection
      mainView = model.mainView
      showingTerminal = model.showingTerminal
      inboxFocus = model.inboxFocus
      boardFocus = model.boardFocus
      terminalFocus = model.terminalFocus
      revealedMessageField = model.revealedMessageField
      messageFieldFocus = model.messageFieldFocus
    }
  }

  // MARK: messageFieldTarget

  @Test(arguments: [false, true])
  func aSelectedWorkSessionIsTheTarget(_ toggle: Bool) throws {
    let model = try Self.model(needsItem("a"), at: .selection, toggle: toggle)

    #expect(model.messageFieldTarget?.id == "a")
  }

  @Test(arguments: [Kind.chatToggleOff, .managerToggleOff])
  func aSelectedChatOrManagerWithTheTerminalToggleOffHasNoTarget(_ kind: Kind) throws {
    #expect(try Self.model(kind, at: .selection).messageFieldTarget == nil)
  }

  @Test(arguments: [Kind.chatToggleOn, .managerToggleOn])
  func aSelectedChatOrManagerWithTheTerminalToggleOnIsTheTarget(_ kind: Kind) throws {
    #expect(try Self.model(kind, at: .selection).messageFieldTarget?.id == "a")
  }

  @Test func theInboxInSummaryModeHasNoTarget() throws {
    #expect(try Self.model(needsItem("a"), at: .inboxSummary).messageFieldTarget == nil)
  }

  @Test func theInboxInTerminalModeTargetsTheCurrentItem() throws {
    #expect(try Self.model(needsItem("a"), at: .inboxTerminal).messageFieldTarget?.id == "a")
  }

  /// `terminalTarget` names the focused card, but the Board draws no `SessionView`.
  @Test func theBoardHasNoTarget() throws {
    let model = try Self.model(needsItem("a"), at: .board)
    try #require(model.terminalTarget?.id == "a")

    #expect(model.messageFieldTarget == nil)
  }

  @Test func theIssuesViewHasNoTarget() throws {
    #expect(try Self.model(needsItem("a"), at: .issues).messageFieldTarget == nil)
  }

  @Test(arguments: [Kind.docketRow, .followupNotStarted, .unstartedFollowupWithFolder, .cleanedUp])
  func aSessionWithNoClaudeTerminalHasNoTarget(_ kind: Kind) throws {
    #expect(try Self.model(kind, at: .selection).messageFieldTarget == nil)
  }

  @Test func anUnlistedSelectionHasNoTarget() {
    let model = appliedModel([needsItem("a")])
    model.selectUnlisted("new")

    #expect(model.messageFieldTarget == nil)
  }

  @Test func anEmptyInboxHasNoTarget() {
    let model = offlineModel()
    model.show(.inbox)
    model.showingTerminal = true

    #expect(model.messageFieldTarget == nil)
  }

  /// The menu item is enabled exactly where a `SessionView` with a Claude terminal shows.
  @Test(arguments: Kind.allCases, Place.allCases)
  func theTargetIsTheSessionExactlyWhereItsTerminalViewShows(_ kind: Kind, _ place: Place) throws {
    let model = try Self.model(kind, at: place)

    #expect(model.messageFieldTarget?.id == (Self.showsTerminalView(kind, at: place) ? "a" : nil))
  }

  // MARK: revealMessageField

  @Test func revealSetsTheRevealToTheTarget() throws {
    let model = try Self.model(needsItem("a"), at: .selection)

    model.revealMessageField()

    #expect(model.revealedMessageField == "a")
  }

  @Test func revealAsksTheTargetsFieldToTakeFocus() throws {
    let model = try Self.model(needsItem("a"), at: .selection)

    model.revealMessageField()

    #expect(model.messageFieldFocus == "a")
  }

  /// A draft already shows the field. The menu item still focuses it.
  @Test func revealWithADraftThatAlreadyShowsTheFieldStillFocusesIt() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.messageDraft(for: session).text = "Rebase onto main"

    model.revealMessageField()

    #expect(model.messageFieldFocus == "a")
  }

  /// The reveal shows the field in place. It changes nothing but the two ids.
  @Test(arguments: [Place.selection, .inboxTerminal])
  func revealNeverNavigates(_ place: Place) throws {
    let model = try Self.model(needsItem("a"), at: place)
    var expected = Snapshot(model)
    expected.revealedMessageField = "a"
    expected.messageFieldFocus = "a"

    model.revealMessageField()

    #expect(Snapshot(model) == expected)
  }

  @Test(arguments: untargeted)
  func revealWithoutATargetChangesNothing(_ kind: Kind, _ place: Place) throws {
    let model = try Self.model(kind, at: place)
    let before = Snapshot(model)

    model.revealMessageField()

    #expect(Snapshot(model) == before)
  }

  // MARK: hideMessageField

  @Test func hideClearsTheReveal() throws {
    let model = try Self.model(needsItem("a"), at: .selection)
    model.revealMessageField()

    model.hideMessageField("a")

    #expect(model.revealedMessageField == nil)
  }

  /// An error alone keeps the field showing, so the field could not hide without this.
  @Test func hideClearsTheDraftsError() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.revealMessageField()
    model.messageDraft(for: session).error = "notes.txt isn't an image"

    model.hideMessageField("a")

    #expect(model.messageDraft(for: session).error == nil)
  }

  @Test func hideKeepsTheDraftsText() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.messageDraft(for: session).text = "Rebase onto main"

    model.hideMessageField("a")

    #expect(model.messageDraft(for: session).text == "Rebase onto main")
  }

  @Test func hideReturnsKeyboardFocusToTheClaudeTerminal() throws {
    let model = try Self.model(needsItem("a"), at: .selection)
    model.revealMessageField()

    model.hideMessageField("a")

    #expect(model.terminalFocus == "a")
  }
}
