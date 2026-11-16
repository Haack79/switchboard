import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The first poll reads the session's PR and learns its body refs. The
  /// second poll reads the PRs that those refs name.
  func pollTwice() throws {
    try poll()
    try poll(all: true)
  }

  /// The session's edges as `sb get --json` shows them.
  func edges(_ id: String) throws -> [Dependency]? {
    try JSONCoding.decode(SessionSummary.self, from: try sb("get", "--json", id)).dependencies
  }

  /// The text of each message that sbd itself sent to the session.
  func messagesFromSbd(_ id: String) throws -> [String] {
    try events(id).filter { $0.kind == "sent" && $0.data["by"]?.string == "sbd" }.compactMap { $0.data["text"]?.string }
  }
}

private let posthog = "PostHog/posthog"
/// #122953's head branch.
private let baseBranch = "haacked/cdp-dlq-breaker-counts-lookups"
/// #122896's head branch.
private let dependentBranch = "haacked/mcp-experiment-condition-ids"
/// The deployment-status-posthog comment on #122179, which shows it deployed to dev, prod-us, and prod-eu.
private let deployComment = "IC_kwDODg-Tdc8AAAABfAhApw"
private let readTheReply = "read its last reply and decide what's next"

/// Makes #122896's base #122953's head branch, as a stacked PR's base is.
/// The base ref names no merged PR, so the retarget rule does not fire.
private func stack(_ github: FakeGitHub, on base: String = baseBranch) {
  github.change(122896) {
    $0["baseRefName"] = .string(base)
    $0["baseRef"] = ["associatedPullRequests": ["nodes": []]]
  }
}

private func body(_ github: FakeGitHub, _ text: String) {
  github.change(122896) { $0["body"] = .string(text) }
}

/// A repository whose deploys no deploy comment shows. Its #20992 is recorded.
private let docs = "PostHog/posthog.com"
private let docsLabel = "PostHog/posthog.com#20992"
private let devSync = "Dev: Deploy with ArgoCD (feature-flags) / Dev: ArgoCD Sync"

/// Merges `number` with the merge commit that the feature-flags routes compare.
private func merge(_ github: FakeGitHub, _ number: Int) {
  github.change(number) {
    $0["state"] = "MERGED"
    $0["mergedAt"] = "2026-10-23T22:00:00Z"
    $0["mergeCommit"] = ["oid": .string(DeployPollerTests.merge)]
  }
}

/// A service check can run in the poll after the one that reads the edge's
/// PR, so the tests poll once more before they look.
private func pollEdges(_ sbd: Instance) throws {
  try sbd.pollTwice()
  try sbd.poll(all: true)
}

private func pollAfterTheDeployInterval(_ sbd: Instance) throws {
  try sbd.advanceClock(DeployPollerTests.deployMs)
  try sbd.poll(all: true)
  try sbd.poll(all: true)
}

@Suite(.blocking(timeLimit: .seconds(120))) struct DependencyTests {
  @Test func bodyEdgesShowInGetAndLs() throws {
    let github = try FakeGitHub()
    body(github, "Moves the flags.\r\n\r\nDepends on #122953\r\nDepends on PostHog/charts#18303\r\n")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    #expect(try sbd.edges(s.id) == nil)
    let activity = try sbd.get(s.id).lastActivity

    try sbd.pollTwice()

    let expected = [
      Dependency(via: .body, repo: posthog, number: 122953, state: .open),
      Dependency(via: .body, repo: "PostHog/charts", number: 18303, state: .open),
    ]
    #expect(try sbd.edges(s.id) == expected)
    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    #expect(listed.first { $0.id == s.id }?.dependencies == expected)
    let text = try sbd.sb("get", s.id)
    #expect(text.contains("  depends: #122953 open\n"))
    #expect(text.contains("  depends: PostHog/charts#18303 open\n"))
    #expect(try sbd.events(s.id).contains { $0.kind == "dependencies" })
    #expect(try sbd.get(s.id).lastActivity == activity)
  }

  @Test func bodyEdgeHoldsTheSessionInReadyForReview() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    let after = try sbd.get(s.id)
    #expect(after.state == .readyForReview)
    #expect(after.reason.hasSuffix("; waits on #122953"))
    #expect(try sbd.triage().isEmpty)
  }

  @Test func bodyEdgeInAnotherRepoNamesItsRepo() throws {
    let github = try FakeGitHub()
    body(github, "- Depends on https://github.com/PostHog/charts/pull/18303")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.get(s.id).reason.hasSuffix("; waits on PostHog/charts#18303"))
  }

  @Test func unreadEdgePrintsUnknown() throws {
    let github = try FakeGitHub()
    // The fake has no PR #1, so the poller never reads the edge's state.
    body(github, "Depends on #1")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 1, state: nil)])
    #expect(try sbd.sb("get", s.id).contains("  depends: #1 unknown\n"))
    #expect(try sbd.get(s.id).reason.hasSuffix("; waits on #1"))
  }

  @Test func repeatedRefsCollapseToOneEdge() throws {
    let github = try FakeGitHub()
    body(
      github,
      "Depends on #122953\nDepends on PostHog/posthog#122953 and https://github.com/PostHog/posthog/pull/122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 122953, state: .open)])
  }

  @Test func bodyLinesThatOnlyMentionAPRGiveNoEdge() throws {
    let github = try FakeGitHub()
    body(github, "Follows #122953.\nSee PostHog/charts#18303 for the runbook.\nThis depends on #122179.")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == nil)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func stackEdgeLinksTwoSessions() throws {
    let github = try FakeGitHub()
    stack(github)
    let sbd = try Instance.withGitHub(github)
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")

    try sbd.pollTwice()

    #expect(
      try sbd.edges(top.id) == [
        Dependency(via: .stack, repo: posthog, number: 122953, base: baseBranch, state: .open, session: base.id)
      ])
    #expect(try sbd.edges(base.id) == nil)
    #expect(try sbd.get(top.id).state == .readyForReview)
    #expect(try sbd.get(top.id).reason.hasSuffix("; waits on #122953"))
    #expect(try sbd.sb("get", top.id).contains("  depends: #122953 open (session \(base.id))\n"))
  }

  @Test(arguments: [
    "release/2026-11",
    // #122953 heads this branch, but no session works on #122953.
    baseBranch,
  ])
  func baseThatNoOtherSessionsPRHeadsGivesNoEdge(_ base: String) throws {
    let github = try FakeGitHub()
    stack(github, on: base)
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(try sbd.edges(s.id) == nil)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func bodyRefToTheStackBaseMergesIntoTheStackEdge() throws {
    let github = try FakeGitHub()
    stack(github)
    body(github, "Depends on #122953 (deployed to dev, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let base = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")

    try sbd.pollTwice()

    #expect(
      try sbd.edges(top.id) == [
        Dependency(
          via: .stack, repo: posthog, number: 122953, base: baseBranch, deploy: true, state: .open, session: base.id,
          service: "feature-flags", environments: [.dev])
      ])
  }

  @Test func mergedStackBaseResumesTheSession() throws {
    let github = try FakeGitHub()
    stack(github)
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")
    try sbd.pollTwice()
    #expect(try sbd.messagesFromSbd(top.id).isEmpty)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(top.id).isEmpty }
    #expect(try sbd.messagesFromSbd(top.id) == ["Switchboard: #122953 merged; retarget and rebase #122896."])
  }

  /// GitHub retargets a stacked PR when its base merges and the base branch
  /// is deleted. A poll can read the retarget before it reads the merge.
  @Test func retargetReadBeforeTheBaseMergeStillResumesTheSession() throws {
    let github = try FakeGitHub()
    stack(github)
    // A settled base, mergeable and approved, polls only at the idle
    // interval. The dependent PR's UNKNOWN mergeability keeps it due at every
    // poll.
    github.change(122953) {
      $0["mergeable"] = "MERGEABLE"
      $0["reviewDecision"] = "APPROVED"
    }
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: posthog, branch: baseBranch, folder: "base")
    let top = try sbd.session(in: posthog, branch: dependentBranch, folder: "top")
    try sbd.pollTwice()
    #expect(try sbd.edges(top.id)?.map(\.via) == [.stack])

    github.change(122953) { $0["state"] = "MERGED" }
    github.change(122896) { $0["baseRefName"] = "master" }
    try sbd.poll()
    #expect(github.requests.last { $0.kind == "status" }?.ids == [github.pr(122896)["id"]!.string!])
    #expect(try sbd.edges(top.id)?.map(\.state) == [.open])
    #expect(try sbd.messagesFromSbd(top.id).isEmpty)

    try sbd.poll()
    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(top.id).isEmpty }
    #expect(try sbd.messagesFromSbd(top.id) == ["Switchboard: #122953 merged; retarget and rebase #122896."])
    #expect(try sbd.edges(top.id) == nil)
  }

  @Test func dependenciesThatMergeInOnePollSendOneMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953 and PostHog/charts#18303")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122953) { $0["state"] = "MERGED" }
    github.change(18303) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == [
        "Switchboard: #122953 merged, so #122896 no longer waits on it.\nPostHog/charts#18303 merged, so #122896 no longer waits on it."
      ])
  }

  @Test func mergedBodyDependencyResumesTheSessionOnce() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == ["Switchboard: #122953 merged, so #122896 no longer waits on it."])
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    #expect(try sbd.messagesFromSbd(s.id).count == 1)
  }

  @Test func dependencyAlreadyMergedAtFirstSightSendsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122179")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.edges(s.id) == [Dependency(via: .body, repo: posthog, number: 122179, state: .merged)])
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  @Test func sessionMarkedDoneGetsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    try sbd.sb("done", s.id)

    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func sessionWhoseOwnPRClosedGetsNoMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122896) { $0["state"] = "CLOSED" }
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func deployEdgeResolvesFromTheDeployComment() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122179 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try sbd.pollTwice()

    #expect(
      try sbd.edges(s.id) == [
        Dependency(via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: true)
      ])
    #expect(try sbd.get(s.id).reason == readTheReply)
    #expect(try sbd.sb("get", s.id).contains("  depends: #122179 merged, deployed\n"))
  }

  @Test func deployToBothProdRegionsResumesTheSession() throws {
    let github = try FakeGitHub()
    let deployed = try #require(
      FakeGitHub.recorded("github-bodies.json").first { $0["id"]?.string == deployComment }?["body"]?.string)
    let euPending = deployed.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.contains("**prod-eu**") ? "| **prod-eu** | :hourglass_flowing_sand: Pending |  |  |" : String($0)
    }.joined(separator: "\n")
    github.edit(comment: deployComment, body: euPending, at: "2026-10-23T22:30:00Z")
    body(github, "Depends on #122179 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    #expect(
      try sbd.edges(s.id) == [
        Dependency(via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: false)
      ])
    #expect(try sbd.get(s.id).state == .readyForReview)
    #expect(try sbd.get(s.id).reason.hasSuffix("; waits on the deploy of #122179"))
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.sb("get", s.id).contains("  depends: #122179 merged, deploy\n"))

    github.edit(comment: deployComment, body: deployed, at: "2026-10-23T22:34:45Z")
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == ["Switchboard: #122179 deployed to prod, so #122896 no longer waits on it."])
  }

  /// The deploy comment decides a PostHog/posthog edge in the environments
  /// that its line names, not in both prod regions.
  @Test func deployCommentEdgeToDevHoldsWhileDevIsPending() throws {
    let github = try FakeGitHub()
    let deployed = try #require(
      FakeGitHub.recorded("github-bodies.json").first { $0["id"]?.string == deployComment }?["body"]?.string)
    let devPending = deployed.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.contains("**dev**") ? "| **dev** | :hourglass_flowing_sand: Pending |  |  |" : String($0)
    }.joined(separator: "\n")
    github.edit(comment: deployComment, body: devPending, at: "2026-10-23T22:30:00Z")
    body(github, "Depends on #122179 (deployed to dev)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    #expect(
      try sbd.edges(s.id) == [
        Dependency(
          via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: false,
          environments: [.dev])
      ])
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)

    github.edit(comment: deployComment, body: deployed, at: "2026-10-23T22:34:45Z")
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == ["Switchboard: #122179 deployed to dev, so #122896 no longer waits on it."])
  }

  @Test func failedReadAfterARestartKeepsTheEdgeAndStillResumesTheSession() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    let open = [Dependency(via: .body, repo: posthog, number: 122953, state: .open)]
    #expect(try sbd.edges(s.id) == open)

    sbd.stopSbd()
    try sbd.startSbd()
    github.fail(122953)
    try sbd.poll(all: true)
    #expect(try sbd.edges(s.id) == open)

    github.recover(122953)
    github.change(122953) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(try sbd.messagesFromSbd(s.id) == ["Switchboard: #122953 merged, so #122896 no longer waits on it."])
  }

  @Test func failedDeployCommentReadAfterARestartSendsNoSecondMessage() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122179 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()
    let deployed = [Dependency(via: .body, repo: posthog, number: 122179, deploy: true, state: .merged, deployed: true)]
    #expect(try sbd.edges(s.id) == deployed)

    sbd.stopSbd()
    try sbd.startSbd()
    github.fail(comment: deployComment)
    try sbd.poll(all: true)
    #expect(try sbd.edges(s.id) == deployed)

    github.recover(comment: deployComment)
    try sbd.poll(all: true)
    sleep(1)

    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  @Test func closedDependencyNeedsYou() throws {
    let github = try FakeGitHub()
    body(github, "Depends on #122953")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.pollTwice()

    github.change(122953) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)

    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason == "decide what replaces #122953, which closed unmerged")
    #expect(try sbd.sb("get", s.id).contains("  depends: #122953 closed\n"))
    sleep(1)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  // MARK: Deploy edges that name a service or environments

  @Test func serviceEdgeInAnotherRepoResolvesFromTheStateFileAndResumesTheSession() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    try deploys.serveFeatureFlags(
      github, jobs: try deploys.flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]), repository: docs)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed to dev and prod, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try pollEdges(sbd)
    #expect(
      try sbd.edges(s.id) == [
        Dependency(
          via: .body, repo: docs, number: 20992, deploy: true, state: .merged, deployed: false,
          service: "feature-flags", environments: [.dev, .prodUS, .prodEU])
      ])
    #expect(try sbd.get(s.id).state == .readyForReview)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)

    github.route(DeployPollerTests.jobsPath, try deploys.flagsJobs())
    try pollAfterTheDeployInterval(sbd)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == [
        "Switchboard: \(docsLabel) deployed to dev, prod-us, and prod-eu, so #122896 no longer waits on it."
      ])
  }

  @Test func edgeThatNamesDevHoldsWhileOnlyProdDeployed() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    try deploys.serveFeatureFlags(
      github, jobs: try deploys.flagsJobs([devSync: ("in_progress", nil)]), repository: docs)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed to dev, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    let edge = try #require(try sbd.edges(s.id)?.first)
    #expect(edge.deployed == false)
    #expect(edge.problem == nil)
    let held = try sbd.get(s.id)
    #expect(held.state == .readyForReview)
    #expect(held.reason.contains("waits on the deploy of \(docsLabel)"))
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
    #expect(try sbd.sb("get", s.id).contains("  depends: \(docsLabel) merged, deploy of feature-flags to dev\n"))

    github.route(DeployPollerTests.jobsPath, try deploys.flagsJobs())
    try pollAfterTheDeployInterval(sbd)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == ["Switchboard: \(docsLabel) deployed to dev, so #122896 no longer waits on it."])
  }

  /// The control for the dev edge: with the same jobs, an edge that names no
  /// environments waits only on both prod regions.
  @Test func edgeThatNamesNoEnvironmentsResolvesWhileDevStillDeploys() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    try deploys.serveFeatureFlags(
      github, jobs: try deploys.flagsJobs([devSync: ("in_progress", nil)]), repository: docs)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    #expect(try sbd.edges(s.id)?.first?.deployed == true)
    #expect(try sbd.get(s.id).reason == readTheReply)
  }

  /// #122179's deploy comment says Deployed everywhere. It describes the main
  /// posthog app, so it can't resolve an edge that names feature-flags.
  @Test func serviceEdgeOnAPostHogPRIgnoresTheDeployComment() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 122179)
    try deploys.serveFeatureFlags(
      github, jobs: try deploys.flagsJobs([DeployPollerTests.prodEUSync: ("in_progress", nil)]))
    body(github, "Depends on #122179 (deployed, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    #expect(try sbd.edges(s.id)?.first?.deployed == false)
    #expect(try sbd.get(s.id).reason.contains("waits on the deploy of #122179"))
  }

  /// Each case sets up a service whose deploy of #20992 can't finish as the
  /// line names it.
  @Test(arguments: [
    ("another repository", "duckgres deploys from PostHog/duckgres"),
    ("no state file", "no state/no-such-service.yaml"),
    ("failed sync", "the deploy to prod-eu failed"),
    ("merge off the deployed branch", "doesn't deploy from"),
  ])
  func serviceEdgeThatCantResolveNeedsYou(_ problem: String, _ expected: String) throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    var service = "feature-flags"
    switch problem {
    case "another repository":
      service = "duckgres"
      github.route(
        "repos/PostHog/charts/contents/state/duckgres.yaml", contentType: "text/plain; charset=utf-8",
        try deployResponse("state-duckgres.yaml"))
    case "no state file":
      service = "no-such-service"
    case "failed sync":
      try deploys.serveFeatureFlags(
        github, jobs: try deploys.flagsJobs([DeployPollerTests.prodEUSync: ("completed", "failure")]),
        repository: docs)
    default:
      try deploys.serveFeatureFlags(github, jobs: try deploys.flagsJobs(), repository: docs)
      github.route(
        "repos/\(docs)/compare/\(DeployPollerTests.flagsCommit)...\(DeployPollerTests.merge)",
        #"{"status":"diverged","ahead_by":2,"behind_by":5,"files":[]}"#)
    }
    body(github, "Depends on PostHog/posthog.com#20992 (deployed, service: \(service))")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    let edge = try #require(try sbd.edges(s.id)?.first)
    let reason = try #require(edge.problem)
    #expect(reason.contains(expected))
    #expect(edge.deployed != true)
    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason == oneLine("\(docsLabel) can't resolve: \(reason)"))
    #expect(try sbd.sb("get", s.id).contains("  depends: \(docsLabel) merged, deploy of \(service); \(reason)\n"))
    sleep(1)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  /// A problem lasts only until a later read of the service decides the
  /// deploy. A rerun sync that succeeds resumes the session.
  @Test func serviceEdgeRecoversWhenTheFailedSyncSucceeds() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    try deploys.serveFeatureFlags(
      github, jobs: try deploys.flagsJobs([DeployPollerTests.prodEUSync: ("completed", "failure")]),
      repository: docs)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    #expect(try sbd.edges(s.id)?.first?.problem != nil)
    #expect(try sbd.get(s.id).state == .needsYou)

    github.route(DeployPollerTests.jobsPath, try deploys.flagsJobs())
    try pollAfterTheDeployInterval(sbd)

    try sbd.waitFor("the resume message") { try !sbd.messagesFromSbd(s.id).isEmpty }
    #expect(
      try sbd.messagesFromSbd(s.id) == [
        "Switchboard: \(docsLabel) deployed to prod, so #122896 no longer waits on it."
      ])
    let edge = try #require(try sbd.edges(s.id)?.first)
    #expect(edge.problem == nil)
    #expect(edge.deployed == true)
  }

  @Test func serviceFromAnotherRepositoryNamesThatRepository() throws {
    let github = try FakeGitHub()
    merge(github, 20992)
    github.route(
      "repos/PostHog/charts/contents/state/duckgres.yaml", contentType: "text/plain; charset=utf-8",
      try deployResponse("state-duckgres.yaml"))
    body(github, "Depends on PostHog/posthog.com#20992 (deployed, service: duckgres)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    #expect(try sbd.edges(s.id)?.first?.problem?.contains("PostHog/duckgres") == true)
    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason.hasPrefix("\(docsLabel) can't resolve: "))
  }

  @Test func deployEdgeInAnotherRepoWithNoServiceNeedsYou() throws {
    let github = try FakeGitHub()
    merge(github, 20992)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    let edge = try #require(try sbd.edges(s.id)?.first)
    #expect(edge.problem?.contains("service: <name>") == true)
    #expect(edge.deployed != true)
    let after = try sbd.get(s.id)
    #expect(after.state == .needsYou)
    #expect(after.reason.hasPrefix("\(docsLabel) can't resolve: "))
    sleep(1)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }

  /// The problem is about the deploy, so it waits until the PR merged.
  @Test func openDeployEdgeInAnotherRepoWithNoServiceWaitsOnTheMerge() throws {
    let github = try FakeGitHub()
    body(github, "Depends on PostHog/posthog.com#20992 (deployed)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)

    try pollEdges(sbd)

    #expect(try sbd.edges(s.id)?.first?.problem == nil)
    let after = try sbd.get(s.id)
    #expect(after.state == .readyForReview)
    #expect(after.reason.hasSuffix("; waits on \(docsLabel)"))
  }

  @Test func serviceEdgeStaysDeployedAfterTheStateFileGoes() throws {
    let github = try FakeGitHub()
    let deploys = DeployPollerTests()
    merge(github, 20992)
    try deploys.serveFeatureFlags(github, jobs: try deploys.flagsJobs(), repository: docs)
    body(github, "Depends on PostHog/posthog.com#20992 (deployed, service: feature-flags)")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try pollEdges(sbd)
    #expect(try sbd.edges(s.id)?.first?.deployed == true)

    github.route(DeployPollerTests.statePath, status: 404, #"{"message":"Not Found"}"#)
    try pollAfterTheDeployInterval(sbd)

    let edge = try #require(try sbd.edges(s.id)?.first)
    #expect(edge.deployed == true)
    #expect(edge.problem == nil)
    #expect(try sbd.get(s.id).reason == readTheReply)
    sleep(1)
    #expect(try sbd.messagesFromSbd(s.id).isEmpty)
  }
}
