import Testing

@testable import SwitchboardApp

@Suite struct ListSectionHeaderSpeech {
  @Test func readsTheTitleAndTheCount() {
    #expect(ListSectionHeader.spoken(title: "Needs you", count: 4) == "Needs you, 4")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ListSectionHeader.spoken(title: "Needs you", count: 0) == "Needs you")
  }
}
