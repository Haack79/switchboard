import Testing

@testable import SwitchboardCore

private let start = "haacked/first-fix"
private let other = "haacked/follow-up"

private func session(branch: String? = start, kind: SessionKind = .work) -> Session {
  var s = Session(id: "s1", name: "fix", cwd: "/tmp/fix", branch: branch, claudeSessionId: "c1", created: 1)
  switch kind {
  case .work: break
  case .manager: s.manager = true
  case .chat: s.chat = "g1"
  case .operator:
    s.isOperator = true
    s.manager = true
  }
  return s
}

private func pullRequest(_ number: Int) -> PullRequest {
  PullRequest(id: "PR_\(number)", number: number, url: "https://github.com/o/r/pull/\(number)", repo: "o/r")
}

private func facts(branch: String? = other, pr: Int? = nil, prNumbers: Set<Int> = []) -> SessionFacts {
  var f = SessionFacts()
  f.branch = branch
  f.pr = pr.map(pullRequest)
  f.prNumbers = prNumbers
  return f
}

private func summary(branch: String?, startBranch: String?) -> SessionSummary {
  var s = SessionSummary(
    id: "s1", name: "fix", cwd: "/tmp/fix", repo: nil, branch: branch, claudeSessionId: "c1", state: .working,
    reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [],
    notes: [])
  s.startBranch = startBranch
  return s
}

@Suite struct BranchSwitchTests {

  @Test func theDefaultSystemPromptHoldsTheGuidance() {
    #expect(TriageSettings().systemPrompt.contains(BranchSwitch.guidance))
  }

  @Test(arguments: ["`spawn`", "sb spawn"])
  func theGuidanceNamesSpawn(_ name: String) {
    #expect(BranchSwitch.guidance.contains(name))
  }

  /// The description already says "follow-up" for the `followup` argument, so the check names the new sentence's
  /// advice against a checkout in the session's own folder.
  @Test func theSpawnToolSaysToUseItForFollowUps() throws {
    let spawn = try #require(MCPToolServer.allTools.first { $0.name == "spawn" })

    #expect(spawn.description.contains("follow-up work"))
    #expect(spawn.description.contains("instead of checking out another branch"))
  }

  /// Each case that gives nil breaks one condition of `BranchSwitch.startBranch` and meets the others.
  struct Case: Sendable, CustomTestStringConvertible {
    var name: String
    var sessionBranch: String? = start
    var kind: SessionKind = .work
    var factsBranch: String? = other
    var pr: Int?
    var prNumbers: Set<Int> = [101]
    var expected: String?
    var testDescription: String { name }
  }

  @Test(arguments: [
    Case(name: "switched, with a PR on the new branch", pr: 202, prNumbers: [101, 202], expected: start),
    Case(name: "switched, before the new branch has a PR", pr: nil, prNumbers: [101], expected: start),
    Case(name: "switched, after the start branch's PR closed", pr: nil, prNumbers: [101, 202], expected: start),
    Case(name: "switched back to the start branch", factsBranch: start, pr: 101, prNumbers: [101, 202]),
    Case(name: "no branch when the session started", sessionBranch: nil, pr: 202, prNumbers: [101, 202]),
    Case(name: "the folder's branch isn't known yet", factsBranch: nil, pr: 101, prNumbers: [101, 202]),
    Case(name: "started on main, PR only on the new branch", sessionBranch: "main", pr: 202, prNumbers: [202]),
    Case(name: "started on main, no PR yet", sessionBranch: "main", pr: nil, prNumbers: []),
    Case(name: "a Manager conversation", kind: .manager, pr: 202, prNumbers: [101, 202]),
    Case(name: "a chat", kind: .chat, pr: 202, prNumbers: [101, 202]),
    Case(name: "the operator", kind: .operator, pr: 202, prNumbers: [101, 202]),
  ])
  func theStartBranchShowsOnlyForAWorkSessionThatLeftAnEarlierPR(_ c: Case) {
    let s = session(branch: c.sessionBranch, kind: c.kind)
    let f = facts(branch: c.factsBranch, pr: c.pr, prNumbers: c.prNumbers)

    #expect(BranchSwitch.startBranch(s, f) == c.expected)
  }

  @Test(arguments: [
    (Int?.some(202), Set([101, 202, 303]), [101, 303]),
    (nil, Set([303, 101, 202]), [101, 202, 303]),
    (nil, Set<Int>(), []),
    (7, Set([7]), []),
  ])
  func earlierPRNumbersLeaveOutTheCurrentPRInAscendingOrder(_ pr: Int?, _ prNumbers: Set<Int>, _ expected: [Int]) {
    #expect(facts(pr: pr, prNumbers: prNumbers).earlierPRNumbers == expected)
  }

  @Test func theNoteNamesBothBranches() {
    let s = summary(branch: other, startBranch: start)

    #expect(
      s.branchSwitchNote
        == "Switched from haacked/first-fix to haacked/follow-up. Start follow-up work in a new session.")
  }

  @Test(arguments: [("haacked/follow-up", nil), (nil, "haacked/first-fix")] as [(String?, String?)])
  func theNoteIsNilWithoutBothBranches(_ branch: String?, _ startBranch: String?) {
    #expect(summary(branch: branch, startBranch: startBranch).branchSwitchNote == nil)
  }

  /// An older sbd sends neither key, and the app still decodes its summaries.
  @Test func aSummaryWithoutTheNewKeysDecodesWithNeither() throws {
    var s = summary(branch: other, startBranch: start)
    s.earlierPRs = [101]
    var object = try #require(try JSON(encoding: s).object)
    object["startBranch"] = nil
    object["earlierPRs"] = nil

    let decoded = try JSONCoding.decode(SessionSummary.self, from: JSON.object(object).text)

    #expect(decoded.startBranch == nil)
    #expect(decoded.earlierPRs == nil)
  }
}
