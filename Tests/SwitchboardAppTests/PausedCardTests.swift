import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A paused session's Board card draws greyed out: dimmer text and a gray fill and edge.
@Suite struct PausedCardTests {
  static func card(paused: Bool) -> SessionSummary {
    var s = needsItem("s1", state: .waiting)
    if paused { s.pause = Pause(by: .you, since: 0) }
    return s
  }

  @Test func aPausedCardIsDimmed() {
    #expect(Self.card(paused: true).boardCardOpacity < 1)
  }

  @Test func anUnpausedCardIsNotDimmed() {
    #expect(Self.card(paused: false).boardCardOpacity == 1)
  }

  @Test func aPausedCardIsTintedGray() {
    #expect(Self.card(paused: true).boardCardTint == .gray)
  }

  @Test func anUnpausedCardKeepsItsStateColor() {
    #expect(Self.card(paused: false).boardCardTint == AttentionState.waiting.color)
  }
}
