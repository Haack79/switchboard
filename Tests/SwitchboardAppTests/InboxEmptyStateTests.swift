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

  @Test func titleSaysNothingNeedsYouWhenNothingIsHidden() {
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 0, hasPlanProposals: false) == "Nothing needs you")
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 0, hasPlanProposals: true) == "No session needs you")
  }

  @Test func titleNamesTheFilterWhenItHidesSessionsThatNeedYou() {
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 2, hasPlanProposals: false) == "Nothing in these orgs needs you")
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 2, hasPlanProposals: true) == "No session in these orgs needs you")
  }
}
