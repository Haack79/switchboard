import CoreGraphics
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardColumnWidth {
  /// The width that five columns draw beside the label, the padding, and a legacy vertical scroller.
  private func drawnWidth(_ columnWidth: CGFloat) -> CGFloat {
    BoardView.legacyScrollerWidth + 2 * BoardView.boardPadding + BoardView.labelWidth
      + 5 * (columnWidth + BoardView.columnSpacing)
  }

  @Test func fillsAWideBoard() {
    let width = BoardView.fittedColumnWidth(available: 1268, columns: 5)
    #expect(width > BoardView.minColumnWidth && width < BoardView.maxColumnWidth)
    #expect(abs(drawnWidth(width) - 1268) < 0.01)
  }

  @Test func neverDrawsNarrowerThanTheMinimum() {
    #expect(BoardView.fittedColumnWidth(available: 692, columns: 5) == BoardView.minColumnWidth)
  }

  @Test func neverDrawsWiderThanTheMaximum() {
    #expect(BoardView.fittedColumnWidth(available: 4000, columns: 5) == BoardView.maxColumnWidth)
  }

  @Test func fitsEveryColumnInTheDefaultWindow() {
    // The default 1,400 pt window leaves about 1,090 pt for the Board beside a 300 pt sidebar.
    // A legacy vertical scroller takes its width out of those 1,090 pt.
    #expect(BoardView.legacyScrollerWidth > 0)
    #expect(drawnWidth(BoardView.fittedColumnWidth(available: 1090, columns: 5)) <= 1090 + 0.01)
  }
}
