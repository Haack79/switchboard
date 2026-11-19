import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// A host's summary comes from `SessionFacts.withoutGitHub`, which keeps the folder's branch and drops the PRs
/// that this Mac's GitHub login read.
@Suite struct BranchSwitchScopeTests {
  private func switched() -> (Session, SessionFacts) {
    let session = Session(
      id: "m1", name: "fix", cwd: "/srv/fix", branch: "haacked/first-fix", claudeSessionId: "c1", created: 1)
    var facts = SessionFacts()
    facts.branch = "haacked/follow-up"
    facts.pr = PullRequest(id: "PR_202", number: 202, url: "https://github.com/o/r/pull/202", repo: "o/r")
    facts.prNumbers = [101, 202]
    return (session, facts)
  }

  @Test func theHostsFactsGiveNoStartBranch() {
    let (session, facts) = switched()

    #expect(BranchSwitch.startBranch(session, facts) == "haacked/first-fix")
    #expect(BranchSwitch.startBranch(session, facts.withoutGitHub) == nil)
  }

  @Test func theHostsFactsGiveNoEarlierPRs() {
    let (_, facts) = switched()

    #expect(facts.withoutGitHub.earlierPRNumbers.isEmpty)
  }
}
