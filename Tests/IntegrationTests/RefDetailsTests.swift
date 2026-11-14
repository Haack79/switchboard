import Foundation
import SwitchboardCore
import Testing

// These tests need FakeGitHub to answer the `reference` query (`repository { issueOrPullRequest(number:) }`):
// `putReference(_:)` adds an item, each request is logged with kind "reference" and the id "owner/name#N", an unknown
// repository answers `repository: null`, an unknown number answers `issueOrPullRequest: null`, and `reply(...)`
// still replaces the next answer.

private let widgets = "acme/widgets"
private let ledger = "acme/ledger"

/// The head branch of the recorded PR 18303 in PostHog/charts.
private let chartsBranch = "haacked/cdp-dlq-runbook-lookup-step"

extension Instance {
  /// What `sb ref <args> --json` prints, without the null fields.
  fileprivate func ref(_ args: String...) throws -> [String: JSON] {
    let printed = try sb(["ref"] + args + ["--json"])
    return try #require(JSON.parse(printed)?.object, "sb ref printed \(printed)").filter { $0.value != .null }
  }

  /// The error of an `sb ref` that fails. It fails the test when sb succeeds.
  fileprivate func refRefusal(_ args: String...) throws -> String {
    let r = try run(["ref"] + args)
    try #require(r.status != 0, "sb ref \(args) printed \(r.stdout)")
    return r.stderr
  }
}

extension FakeGitHub {
  /// The reference queries that the fake answered.
  fileprivate var fetches: [Request] { requests.filter { $0.kind == "reference" } }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct RefDetailsTests {

  // MARK: Local sources

  @Test func aSessionsPolledPRAnswersWithoutAGitHubRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: "PostHog/charts", branch: chartsBranch)
    try sbd.poll()
    let sent = github.requests.count

    let details = try sbd.ref("PostHog/charts#18303")

    #expect(details["source"] == "session")
    #expect(details["kind"] == "pr")
    #expect(details["title"] == github.pr(18303)["title"])
    #expect(github.requests.count == sent)
  }

  /// The poll's status query reads `createdAt`, so the session source has it.
  @Test func aPolledPRsCreationTimeReachesTheReply() throws {
    let github = try FakeGitHub()
    github.change(18303) { $0["createdAt"] = "2026-10-20T08:00:00Z" }
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: "PostHog/charts", branch: chartsBranch)
    try sbd.poll()

    let details = try sbd.ref("https://github.com/PostHog/charts/pull/18303")

    #expect(details["createdAt"] == "2026-10-20T08:00:00Z")
  }

  @Test func anIssueInTheIssuesCacheAnswersWithoutAGitHubRequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.put(FakeGitHub.FakeIssue(repo: ledger, number: 4312, title: "Invoice PDF currency", labels: ["bug"]))
    try sbd.sb("issues", "source", "add", ledger)
    try #require(try sbd.poll(all: true)["issuesError"] == nil)
    let sent = github.requests.count

    let details = try sbd.ref("acme/ledger#4312")

    #expect(details["source"] == "issues")
    #expect(details["title"] == "Invoice PDF currency")
    #expect(github.requests.count == sent)
  }

  // MARK: Fetch and TTLs

  @Test func anUnknownOpenIssueIsFetchedOnceAndAgainAfter60Seconds() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7, title: "Totals round twice"))

    let first = try sbd.ref("acme/widgets#7")
    let second = try sbd.ref("acme/widgets#7")
    let fetchedOnce = github.fetches.count
    try sbd.advanceClock(61_000)
    _ = try sbd.ref("acme/widgets#7")

    #expect(first["source"] == "fetch")
    #expect(github.fetches.first?.ids == ["acme/widgets#7"])
    #expect(second == first)
    #expect(fetchedOnce == 1)
    #expect(github.fetches.count == 2)
  }

  @Test func aFetchRecordsWhenSbdReadTheItem() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))
    let before = try sbd.now()

    let details = try sbd.ref("acme/widgets#7")

    let read = try #require(details["read"]?.int)
    #expect((Int(before)...Int(try sbd.now())).contains(read))
  }

  /// sbd keys its cache by the lowercase owner/name#N.
  @Test func aReferenceInAnotherCaseAnswersFromTheCache() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))
    let first = try sbd.ref("acme/widgets#7")

    let second = try sbd.ref("https://github.com/ACME/Widgets/issues/7")

    #expect(second == first)
    #expect(github.fetches.count == 1)
  }

  @Test func aMergedPRStaysCachedPast60SecondsUntil10Minutes() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 8, pull: true, state: "MERGED"))
    let first = try sbd.ref("acme/widgets#8")

    try sbd.advanceClock(61_000)
    let cached = try sbd.ref("acme/widgets#8")
    let fetchedOnce = github.fetches.count
    try sbd.advanceClock(540_000)
    _ = try sbd.ref("acme/widgets#8")

    #expect(first["state"] == "merged")
    #expect(cached == first)
    #expect(fetchedOnce == 1)
    #expect(github.fetches.count == 2)
  }

  @Test func notFoundAnswersWithAMessageAndIsCachedFor10Minutes() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 1))

    let first = try sbd.refRefusal("acme/widgets#99")
    try sbd.advanceClock(61_000)
    let cached = try sbd.refRefusal("acme/widgets#99")
    let fetchedOnce = github.fetches.count
    try sbd.advanceClock(540_000)
    _ = try sbd.refRefusal("acme/widgets#99")

    #expect(first.lowercased().contains("not found"))
    #expect(cached == first)
    #expect(fetchedOnce == 1)
    #expect(github.fetches.count == 2)
  }

  @Test func aGitHub502AnswersWithAnErrorAndIsFetchedAgainAfter30Seconds() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))
    github.reply(502, #"{"message":"Server Error"}"#)

    let error = try sbd.refRefusal("acme/widgets#7")
    let cached = try sbd.refRefusal("acme/widgets#7")
    let fetchedOnce = github.fetches.count
    try sbd.advanceClock(31_000)
    let details = try sbd.ref("acme/widgets#7")

    #expect(error.contains("502"))
    #expect(cached == error)
    #expect(fetchedOnce == 1)
    #expect(details["source"] == "fetch")
    #expect(github.fetches.count == 2)
  }

  /// The poller's GraphQL rate-limit pause covers the fetch, which then sends nothing.
  @Test func theGraphQLPauseTurnsIntoTheErrorWithoutARequest() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    _ = try sbd.session(in: "PostHog/charts", branch: chartsBranch)
    let reset = Int(Date().timeIntervalSince1970) + 600
    github.reply(
      200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"],
      #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
    try sbd.poll()
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))
    let sent = github.requests.count

    let error = try sbd.refRefusal("acme/widgets#7")

    #expect(error.contains("paused after a GitHub GraphQL rate limit"))
    #expect(github.requests.count == sent)
  }

  // MARK: The op and the CLI

  @Test func sbRefJSONPrintsTheOpsReply() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))
    let printed = try sbd.ref("acme/widgets#7")

    let reply = try sbd.client.call("ref-details", ["ref": "acme/widgets#7"])

    #expect(try #require(reply.object).filter { $0.value != .null } == printed)
  }

  @Test func theOpTakesARepositoryAndANumber() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7, title: "Totals round twice"))

    let reply = try sbd.client.call("ref-details", ["repo": "acme/widgets", "number": 7])

    #expect(reply["title"] == "Totals round twice")
    #expect(github.fetches.map(\.ids) == [["acme/widgets#7"]])
  }

  @Test func aBareNumberWithoutRepoFailsWithAMessageThatNamesRepo() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7))

    let error = try sbd.refRefusal("#7")

    #expect(error.contains("--repo"))
    #expect(github.fetches.isEmpty)
  }

  @Test func aBareNumberWithRepoNamesTheItemInThatRepo() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(FakeGitHub.FakeReference(repo: widgets, number: 7, title: "Totals round twice"))

    let details = try sbd.ref("#7", "--repo", widgets)

    #expect(details["title"] == "Totals round twice")
    #expect(github.fetches.map(\.ids) == [["acme/widgets#7"]])
  }

  @Test func sbRefWithoutAReferenceFails() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)

    let r = try sbd.run("ref")

    #expect(r.status != 0)
    #expect(github.fetches.isEmpty)
  }

  @Test func sbRefPrintsAnIssueAsLines() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(
      FakeGitHub.FakeReference(repo: widgets, number: 7, title: "Totals round twice", labels: ["bug", "ui"]))

    let lines = try sbd.sb("ref", "acme/widgets#7").split(separator: "\n").map(String.init)

    #expect(lines.count == 3)
    #expect(lines.first == "acme/widgets#7 issue open")
    #expect(lines.dropFirst().first == "Totals round twice")
    #expect(lines.last?.contains("by robin-k") == true)
    #expect(lines.last?.contains("bug") == true)
  }

  @Test func sbRefPrintsAnOpenPRWithItsChecksReviewAndMergeability() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    github.putReference(
      FakeGitHub.FakeReference(
        repo: widgets, number: 9, pull: true, title: "Round totals once", checks: "SUCCESS",
        reviewDecision: "APPROVED", mergeable: "MERGEABLE"))

    let lines = try sbd.sb("ref", "acme/widgets#9").split(separator: "\n").map(String.init)

    #expect(lines.count == 4)
    #expect(lines.first == "acme/widgets#9 pr open")
    #expect(lines.dropFirst().first == "Round totals once")
  }
}
