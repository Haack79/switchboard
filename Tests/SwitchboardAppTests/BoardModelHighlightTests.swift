import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A session of `kind` in `state`, highlighted when `on` is true. sbd sets the flag to true or leaves it out.
private func session(_ id: String, kind: SessionKind = .work, state: AttentionState = .needsYou, on: Bool = false)
  -> SessionSummary
{
  var s = needsItem(id, manager: kind == .manager || kind == .operator, state: state)
  s.kind = kind
  if kind == .chat { s.chat = "g1" }
  s.highlighted = on ? true : nil
  return s
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelHighlight {
  // MARK: The request

  @Test func setHighlightedSendsTheOp() async {
    let sent = await firstRequest { $0.setHighlighted("a", true) }

    #expect(sent.op == "highlight")
    #expect(sent.args == ["session": "a", "highlighted": true])
  }

  @Test func clearingSendsFalse() async {
    let sent = await firstRequest { $0.setHighlighted("a", false) }

    #expect(sent.op == "highlight")
    #expect(sent.args == ["session": "a", "highlighted": false])
  }

  // MARK: The Inbox order

  /// The highlighted item is the newest and has the lowest rank, so only the highlight can put it first.
  private func inboxWithANewerHighlightedItem() -> BoardModel {
    var a = session("a")
    a.since = 1
    var b = session("b")
    b.since = 2
    var c = session("c", state: .canContinue, on: true)
    c.since = 3
    return appliedModel([a, b, c])
  }

  @Test func theInboxPutsAHighlightedItemFirst() {
    let model = inboxWithANewerHighlightedItem()

    #expect(model.triage.map(\.id) == ["c", "a", "b"])
  }

  @Test func theDefaultInboxFocusIsTheHighlightedItem() {
    let model = inboxWithANewerHighlightedItem()
    model.inboxFocus = nil

    #expect(model.currentInboxItem == "c")
  }

  // MARK: The context menu item

  /// "Remove Highlight" shows whenever the flag is set. "Highlight" shows only where sbd accepts a highlight: a
  /// work session that isn't Done.
  @Test(arguments: [SessionKind.work, .manager, .chat, .operator], AttentionState.allCases)
  func menuTitleForEachKindAndState(_ kind: SessionKind, _ state: AttentionState) {
    let plain = session("s", kind: kind, state: state)
    let highlighted = session("s", kind: kind, state: state, on: true)

    #expect(
      HighlightMenuItem.title(for: plain) == (kind == .work && state != .done ? "Highlight" : nil),
      "not highlighted")
    #expect(HighlightMenuItem.title(for: highlighted) == "Remove Highlight", "highlighted")
  }
}
