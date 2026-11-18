import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The empty Inbox names the filters that hide the sessions that need the user.
@Suite struct InboxEmptyStateScope {
  @Test func theGroupScopeCountsTheSessionsTheGroupFilterHides() {
    #expect(
      InboxView.emptyMessage(hiddenNeedingYou: 1, scope: .groups) == "1 session in a group the filter hides needs you.")
    #expect(
      InboxView.emptyMessage(hiddenNeedingYou: 4, scope: .groups) == "4 sessions in groups the filter hides need you.")
  }

  @Test func theGroupScopeTitleNamesTheGroups() {
    #expect(
      InboxView.emptyTitle(hiddenNeedingYou: 1, scope: .groups, hasPlanProposals: false)
        == "Nothing in these groups needs you")
    #expect(
      InboxView.emptyTitle(hiddenNeedingYou: 4, scope: .groups, hasPlanProposals: true)
        == "No session in these groups needs you")
  }

  @Test func theBothScopeCountsTheSessionsTheFiltersHide() {
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 1, scope: .both) == "1 session that the filters hide needs you.")
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 5, scope: .both) == "5 sessions that the filters hide need you.")
  }

  @Test func theBothScopeTitleNamesOrgsAndGroups() {
    #expect(
      InboxView.emptyTitle(hiddenNeedingYou: 1, scope: .both, hasPlanProposals: false)
        == "Nothing in these orgs and groups needs you")
    #expect(
      InboxView.emptyTitle(hiddenNeedingYou: 5, scope: .both, hasPlanProposals: true)
        == "No session in these orgs and groups needs you")
  }

  @Test(arguments: [SessionFilter.Scope.orgs, .groups, .both])
  func withNothingHiddenEveryScopeSaysWhatShowsHere(_ scope: SessionFilter.Scope) {
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 0, scope: scope, hasPlanProposals: false) == "Nothing needs you")
    #expect(InboxView.emptyTitle(hiddenNeedingYou: 0, scope: scope, hasPlanProposals: true) == "No session needs you")
    #expect(InboxView.emptyMessage(hiddenNeedingYou: 0, scope: scope).hasPrefix("Sessions show here when they need"))
  }
}
