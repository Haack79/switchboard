import CoreGraphics
import Testing

@testable import SwitchboardApp

@Suite struct BoardLaneWidth {
  @Test func fillsAWideBoard() {
    // 1,268 pt less 32 of padding, 140 of label, and 60 of spacing leaves 1,036 for five lanes.
    #expect(abs(BoardView.laneWidth(available: 1268, columns: 5) - 207.2) < 0.01)
  }

  @Test func neverDrawsNarrowerThanTheMinimum() {
    #expect(BoardView.laneWidth(available: 692, columns: 5) == BoardView.minLaneWidth)
  }

  @Test func neverDrawsWiderThanTheMaximum() {
    #expect(BoardView.laneWidth(available: 4000, columns: 5) == BoardView.maxLaneWidth)
  }

  @Test func fitsEveryLaneInTheDefaultWindow() {
    // The default 1,400 pt window leaves about 1,090 pt for the Board beside a 300 pt sidebar.
    let width = BoardView.laneWidth(available: 1090, columns: 5)
    #expect(2 * BoardView.boardPadding + BoardView.labelWidth + 5 * (width + BoardView.laneSpacing) <= 1090)
  }
}
