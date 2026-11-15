import Testing

@testable import SwitchboardApp

@Suite struct ListSectionHeaderSpeech {
  @Test func readsTheTitleAndTheCount() {
    #expect(ListSectionHeader.spoken(title: "Needs you", count: 4) == "Needs you, 4")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ListSectionHeader.spoken(title: "Needs you", count: 0) == "Needs you")
  }

  @Test func readsWhetherASectionIsCollapsed() {
    #expect(ListSectionHeader.spoken(title: "Waiting", count: 3, collapsed: true) == "Waiting, 3, collapsed")
    #expect(ListSectionHeader.spoken(title: "Waiting", count: 3, collapsed: false) == "Waiting, 3, expanded")
  }
}
