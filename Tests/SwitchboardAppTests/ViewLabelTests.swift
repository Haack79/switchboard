import Testing

@testable import SwitchboardApp

@Suite struct ViewPickerLabels {
  @Test func showsTheCountWithoutParentheses() {
    #expect(ContentView.viewLabel("Inbox", 5) == "Inbox 5")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ContentView.viewLabel("Issues", 0) == "Issues")
  }

  @Test func loopsWithNoLoopThatNeedsAttentionShowsNoCount() {
    #expect(ContentView.viewLabel("Loops", 0) == "Loops")
  }

  @Test func loopsShowsHowManyLoopsNeedAttention() {
    #expect(ContentView.viewLabel("Loops", 2) == "Loops 2")
  }

  /// The toolbar picker and the Session menu's Show items read these titles.
  @Test func mainViewTitlesKeepThePickerAndMenuOrder() {
    #expect(MainView.allCases.map(\.title) == ["Inbox", "Board", "Issues", "Loops"])
  }

  /// The Session menu binds Show Inbox, Show Board, Show Issues, and Show Loops to ⌘1 to ⌘4.
  @Test func mainViewShortcutKeysAreOneToFour() {
    #expect(MainView.allCases.map(\.shortcutKey) == ["1", "2", "3", "4"])
  }

  /// The navigation history menu shows these symbols next to each place.
  @Test func mainViewSymbolsMatchTheHistoryIcons() {
    #expect(
      MainView.allCases.map(\.symbol) == [
        "tray", "square.grid.3x3", "smallcircle.filled.circle", "clock.arrow.circlepath",
      ])
  }
}
