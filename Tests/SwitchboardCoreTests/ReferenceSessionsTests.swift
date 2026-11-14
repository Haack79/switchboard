import Testing

@testable import SwitchboardCore

private let switchboardRepo = "haacked/switchboard"

private func session(_ id: String, pr: PRSummary? = nil, issues: [SessionIssue] = []) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: .working, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
    pr: pr)
  s.issues = issues.isEmpty ? nil : issues
  return s
}

private func pr(_ number: Int, in repo: String = switchboardRepo) -> PRSummary {
  PRSummary(
    PullRequest(id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo))
}

private func issue(_ number: Int, in repo: String? = switchboardRepo) -> SessionIssue {
  SessionIssue(repo: repo, number: number, via: .set)
}

private func ref(_ text: String) throws -> GitHubRef {
  try #require(GitHubRef(parsing: text), "fixture \(text.debugDescription) names no reference")
}

private func matching(_ text: String, _ sessions: [SessionSummary]) throws -> [String] {
  ReferenceSessions.matching(try ref(text), in: sessions).map(\.id)
}

@Suite struct ReferenceSessionsTests {
  @Test func sessionWhosePullRequestIsTheReferenceMatches() throws {
    #expect(try matching("haacked/switchboard#283", [session("s1", pr: pr(283))]) == ["s1"])
  }

  @Test func sessionThatWorksOnTheIssueMatches() throws {
    #expect(try matching("haacked/switchboard#283", [session("s1", issues: [issue(283)])]) == ["s1"])
  }

  @Test func issueAfterTheFirstMatches() throws {
    #expect(try matching("haacked/switchboard#283", [session("s1", issues: [issue(7), issue(283)])]) == ["s1"])
  }

  @Test(arguments: [
    session("s1", pr: pr(283, in: "haacked/dotfiles")),
    session("s1", issues: [issue(283, in: "haacked/dotfiles")]),
    session("s1", pr: pr(284)),
    session("s1", issues: [issue(284)]),
    session("s1", pr: pr(28)),
    session("s1", pr: pr(2830)),
    session("s1"),
  ])
  func sessionWithAnotherRepoOrNumberDoesNotMatch(_ session: SessionSummary) throws {
    #expect(try matching("haacked/switchboard#283", [session]).isEmpty)
  }

  /// A session issue whose repository sbd does not know names no repository, so no reference can name it.
  @Test func issueWithNoRepoDoesNotMatch() throws {
    #expect(try matching("haacked/switchboard#283", [session("s1", issues: [issue(283, in: nil)])]).isEmpty)
  }

  @Test(arguments: ["Haacked/Switchboard", "HAACKED/SWITCHBOARD"])
  func sessionRepoInAnotherCaseMatches(_ written: String) throws {
    let sessions = [session("s1", pr: pr(283, in: written)), session("s2", issues: [issue(283, in: written)])]

    #expect(try matching("haacked/switchboard#283", sessions) == ["s1", "s2"])
  }

  @Test func referenceRepoInAnotherCaseMatches() throws {
    let sessions = [session("s1", pr: pr(283)), session("s2", issues: [issue(283)])]

    #expect(try matching("HAACKED/Switchboard#283", sessions) == ["s1", "s2"])
  }

  /// GitHub numbers issues and pull requests together, so the form a reference was written in says nothing about which one it names.
  @Test(arguments: [
    "haacked/switchboard#283", "https://github.com/haacked/switchboard/issues/283",
    "https://github.com/haacked/switchboard/pull/283",
  ])
  func formOfTheReferenceDoesNotMatter(_ text: String) throws {
    let sessions = [session("s1", pr: pr(283)), session("s2", issues: [issue(283)])]

    #expect(try matching(text, sessions) == ["s1", "s2"])
  }

  @Test func sessionWhosePullRequestAndIssueBothMatchAppearsOnce() throws {
    let sessions = [session("s1", pr: pr(283), issues: [issue(283)])]

    #expect(try matching("haacked/switchboard#283", sessions) == ["s1"])
  }

  @Test func matchesKeepTheOrderOfTheSessions() throws {
    let sessions = [
      session("s3", issues: [issue(283)]), session("s1"), session("s2", pr: pr(283)),
      session("s4", pr: pr(283, in: "o/r")), session("s5", pr: pr(1), issues: [issue(283)]),
    ]

    #expect(try matching("haacked/switchboard#283", sessions) == ["s3", "s2", "s5"])
  }

  @Test func noSessionsGiveNoMatches() throws {
    #expect(try matching("haacked/switchboard#283", []).isEmpty)
  }

  @Test func bareNumberMatchesInTheContextRepo() throws {
    let pieces = InlineMentions(names: .empty, repo: switchboardRepo).pieces("#283")
    guard case .reference(let found)? = pieces.first?.mention else {
      Issue.record("#283 gives \(pieces), not one reference")
      return
    }
    let sessions = [session("s1", pr: pr(283)), session("s2", pr: pr(283, in: "o/r"))]

    #expect(ReferenceSessions.matching(found, in: sessions).map(\.id) == ["s1"])
  }
}
