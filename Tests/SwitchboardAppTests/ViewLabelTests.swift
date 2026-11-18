import Testing

@testable import SwitchboardApp

@Suite struct ViewPickerLabels {
  @Test func showsTheCountWithoutParentheses() {
    #expect(ContentView.viewLabel("Inbox", 5) == "Inbox 5")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ContentView.viewLabel("Issues", 0) == "Issues")
  }

  /// The toolbar picker and the Session menu's Show items read these titles.
  @Test func mainViewTitlesKeepThePickerAndMenuOrder() {
    #expect(MainView.allCases.map(\.title) == ["Inbox", "Board", "Issues"])
  }

  /// The Session menu binds Show Inbox, Show Board, and Show Issues to ⌘1 to ⌘3.
  @Test func mainViewShortcutKeysAreOneToThree() {
    #expect(MainView.allCases.map(\.shortcutKey) == ["1", "2", "3"])
  }

  /// The navigation history menu shows these symbols next to each place.
  @Test func mainViewSymbolsMatchTheHistoryIcons() {
    #expect(MainView.allCases.map(\.symbol) == ["tray", "square.grid.3x3", "smallcircle.filled.circle"])
  }
}
