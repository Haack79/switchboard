import Testing

@testable import SwitchboardApp

@Suite struct InboxEmptyState {
  @Test func saysWhatShowsHereWhenNothingIsHidden() {
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 0).hasPrefix("Sessions show here when they need"))
  }

  @Test func countsTheSessionsTheOrgFilterHides() {
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 1) == "1 session in an org the filter hides needs you.")
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 3) == "3 sessions in orgs the filter hides need you.")
  }
}
