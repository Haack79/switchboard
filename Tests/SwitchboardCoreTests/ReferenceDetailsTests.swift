import Foundation
import Testing

@testable import SwitchboardCore

/// One issue or pull request on GitHub, which each test turns into the shape of each source that can describe it:
/// a session's polled `PullRequest`, an `InboxIssue` in the Issues cache, and the `data` of a `GitHub.referenceQuery`
/// answer. The GraphQL values are GitHub's, such as `MERGED` and `CHANGES_REQUESTED`.
struct ReferenceItem: CustomTestStringConvertible, Sendable {
  var name: String
  var pull: Bool
  /// OPEN, CLOSED, or MERGED.
  var state = "OPEN"
  var draft = false
  var author: String? = "robin-k"
  var labels = ["bug"]
  /// The head commit's rollup state, or nil when the commit has no checks.
  var checks: String?
  var reviewDecision: String?
  var mergeable: String?
  var repo = "acme/widgets"
  var number = 7
  var title = "Totals round twice"
  var createdAt = "2026-11-01T10:00:00Z"
  var updatedAt = "2026-11-10T10:00:00Z"

  var testDescription: String { name }

  var url: String { "https://github.com/\(repo)/\(pull ? "pull" : "issues")/\(number)" }

  /// The `issueOrPullRequest` node, with only the fields that the plan's reference query selects.
  var node: JSON {
    var node: [String: JSON] = [
      "__typename": .string(pull ? "PullRequest" : "Issue"), "number": .number(Double(number)),
      "title": .string(title), "url": .string(url), "state": .string(state), "createdAt": .string(createdAt),
      "updatedAt": .string(updatedAt), "author": author.map { ["login": .string($0)] } ?? .null,
      "labels": ["nodes": .array(labels.map { ["name": .string($0)] })],
    ]
    if pull {
      node["isDraft"] = .bool(draft)
      node["reviewDecision"] = reviewDecision.map(JSON.string) ?? .null
      node["mergeable"] = mergeable.map(JSON.string) ?? .null
      let rollup: JSON = checks.map { ["state": .string($0)] } ?? .null
      node["commits"] = ["nodes": [["commit": ["statusCheckRollup": rollup]]]]
    }
    return .object(node)
  }

  /// The `data` of a reference query's answer.
  var data: JSON { ["rateLimit": ["cost": 1], "repository": ["issueOrPullRequest": node]] }

  /// The PR as a session's poll holds it. A poll reads no `updatedAt`.
  var pullRequest: PullRequest {
    var pr = PullRequest(
      id: "PR_\(number)", number: number, url: url, repo: repo, title: title,
      state: PRState(rawValue: state) ?? .open, draft: draft, mergeable: mergeable.flatMap(Mergeable.init(rawValue:)),
      reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)), labels: labels, checks: checks,
      author: author)
    pr.createdAt = createdAt
    return pr
  }

  /// The issue as the Issues cache holds it.
  var issue: InboxIssue {
    InboxIssue(
      repo: repo, number: number, title: title, url: url, state: state == "OPEN" ? .open : .closed, labels: labels,
      author: author, createdAt: createdAt, updatedAt: updatedAt, sources: [repo])
  }
}

/// The details as sbd sends them, without the keys whose value is null. The plan states the reply's JSON, and an
/// absent key and a null mean the same thing to the app.
func wire(_ details: ReferenceDetails) throws -> [String: JSON] {
  try #require(try JSON(encoding: details).object).filter { $0.value != .null }
}

/// `wire` without the keys that differ between sources by design.
private func shared(_ details: ReferenceDetails, dropping keys: Set<String>) throws -> [String: JSON] {
  try wire(details).filter { !keys.contains($0.key) }
}

private func parsed(_ item: ReferenceItem) throws -> ReferenceDetails {
  try #require(GitHub.parseReference(item.data), "the parser read nothing from \(item.name)")
}

private let twelveLabels = (1...12).map { "label-\($0)" }

/// The PR shapes of Risk 4.
private let pullItems = [
  ReferenceItem(
    name: "open PR", pull: true, checks: "PENDING", reviewDecision: "REVIEW_REQUIRED", mergeable: "MERGEABLE"),
  ReferenceItem(name: "draft PR", pull: true, draft: true, mergeable: "MERGEABLE"),
  ReferenceItem(name: "merged PR", pull: true, state: "MERGED", checks: "SUCCESS", reviewDecision: "APPROVED"),
  ReferenceItem(name: "closed PR", pull: true, state: "CLOSED", mergeable: "CONFLICTING"),
  ReferenceItem(
    name: "approved PR with passing checks", pull: true, checks: "SUCCESS", reviewDecision: "APPROVED",
    mergeable: "MERGEABLE"),
  ReferenceItem(
    name: "conflicting PR", pull: true, checks: "FAILURE", reviewDecision: "CHANGES_REQUESTED",
    mergeable: "CONFLICTING"),
  ReferenceItem(name: "PR with no checks", pull: true, checks: nil, mergeable: "UNKNOWN"),
  ReferenceItem(name: "PR with no author", pull: true, author: nil),
  ReferenceItem(name: "PR with no labels", pull: true, labels: []),
  ReferenceItem(name: "PR with 12 labels", pull: true, labels: twelveLabels),
]

/// The issue shapes of Risk 4.
private let issueItems = [
  ReferenceItem(name: "open issue", pull: false),
  ReferenceItem(name: "closed issue", pull: false, state: "CLOSED"),
  ReferenceItem(name: "issue with no author", pull: false, author: nil),
  ReferenceItem(name: "issue with no labels", pull: false, labels: []),
  ReferenceItem(name: "issue with 12 labels", pull: false, labels: twelveLabels),
]

@Suite struct ReferenceDetailsTests {

  // MARK: From a session's PR

  @Test func aSessionsPRGivesEveryFieldThatThePollRead() throws {
    let item = ReferenceItem(
      name: "PR", pull: true, labels: ["bug", "ui"], checks: "SUCCESS", reviewDecision: "APPROVED",
      mergeable: "MERGEABLE")

    let details = ReferenceDetails(pr: item.pullRequest)

    #expect(
      try wire(details) == [
        "repo": "acme/widgets", "number": 7, "kind": "pr", "title": "Totals round twice",
        "url": "https://github.com/acme/widgets/pull/7", "state": "open", "draft": false, "author": "robin-k",
        "labels": ["bug", "ui"], "createdAt": "2026-11-01T10:00:00Z", "checks": "SUCCESS",
        "reviewDecision": "APPROVED", "mergeable": "MERGEABLE", "source": "session",
      ])
  }

  @Test(arguments: [
    (PRState.open, false, "open"), (.open, true, "open"), (.merged, false, "merged"), (.closed, false, "closed"),
  ])
  func aSessionsPRStateIsLowercaseAndADraftStaysOpen(_ state: PRState, _ draft: Bool, _ expected: String) throws {
    var item = ReferenceItem(name: "PR", pull: true, draft: draft)
    item.state = state.rawValue

    let details = try wire(ReferenceDetails(pr: item.pullRequest))

    #expect(details["state"] == .string(expected))
    #expect(details["draft"] == .bool(draft))
  }

  /// A poll reads no `updatedAt`, and the session source has no read time. Both stay out of the reply rather than
  /// taking a default.
  @Test func aSessionsPRHasNoUpdateTimeAndNoReadTime() throws {
    let details = try wire(ReferenceDetails(pr: ReferenceItem(name: "PR", pull: true).pullRequest))

    #expect(details["updatedAt"] == nil)
    #expect(details["read"] == nil)
  }

  @Test func aSessionsPRThatThePollReadNoCreationTimeForHasNone() throws {
    var pr = ReferenceItem(name: "PR", pull: true).pullRequest
    pr.createdAt = nil

    #expect(try wire(ReferenceDetails(pr: pr))["createdAt"] == nil)
  }

  // MARK: From the Issues cache

  @Test func aCachedIssueGivesEveryIssueField() throws {
    let item = ReferenceItem(name: "issue", pull: false, labels: ["bug", "ui"])

    let details = ReferenceDetails(issue: item.issue)

    #expect(
      try wire(details) == [
        "repo": "acme/widgets", "number": 7, "kind": "issue", "title": "Totals round twice",
        "url": "https://github.com/acme/widgets/issues/7", "state": "open", "draft": false, "author": "robin-k",
        "labels": ["bug", "ui"], "createdAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-10T10:00:00Z",
        "source": "issues",
      ])
  }

  @Test func aClosedCachedIssueIsClosed() throws {
    let item = ReferenceItem(name: "issue", pull: false, state: "CLOSED")

    #expect(try wire(ReferenceDetails(issue: item.issue))["state"] == "closed")
  }

  @Test func aCachedIssueWithoutAnAuthorHasNoAuthor() throws {
    let item = ReferenceItem(name: "issue", pull: false, author: nil)

    #expect(try wire(ReferenceDetails(issue: item.issue))["author"] == nil)
  }

  @Test func aCachedIssueHasNoPRFields() throws {
    let details = try wire(ReferenceDetails(issue: ReferenceItem(name: "issue", pull: false).issue))

    #expect(details["checks"] == nil)
    #expect(details["reviewDecision"] == nil)
    #expect(details["mergeable"] == nil)
  }

  // MARK: From a fetch

  @Test func anIssueNodeGivesEveryIssueField() throws {
    let item = ReferenceItem(name: "issue", pull: false, labels: ["bug", "ui"])

    let details = try parsed(item)

    #expect(
      try wire(details) == [
        "repo": "acme/widgets", "number": 7, "kind": "issue", "title": "Totals round twice",
        "url": "https://github.com/acme/widgets/issues/7", "state": "open", "draft": false, "author": "robin-k",
        "labels": ["bug", "ui"], "createdAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-10T10:00:00Z",
        "source": "fetch",
      ])
  }

  @Test func aPRNodeGivesEveryPRField() throws {
    let item = ReferenceItem(
      name: "PR", pull: true, state: "OPEN", draft: true, labels: ["bug"], checks: "FAILURE",
      reviewDecision: "CHANGES_REQUESTED", mergeable: "CONFLICTING")

    let details = try parsed(item)

    #expect(
      try wire(details) == [
        "repo": "acme/widgets", "number": 7, "kind": "pr", "title": "Totals round twice",
        "url": "https://github.com/acme/widgets/pull/7", "state": "open", "draft": true, "author": "robin-k",
        "labels": ["bug"], "createdAt": "2026-11-01T10:00:00Z", "updatedAt": "2026-11-10T10:00:00Z",
        "checks": "FAILURE", "reviewDecision": "CHANGES_REQUESTED", "mergeable": "CONFLICTING", "source": "fetch",
      ])
  }

  @Test(arguments: [("OPEN", "open"), ("CLOSED", "closed"), ("MERGED", "merged")])
  func aPRNodesStateIsLowercase(_ state: String, _ expected: String) throws {
    let item = ReferenceItem(name: "PR", pull: true, state: state)

    #expect(try wire(try parsed(item))["state"] == .string(expected))
  }

  /// The query reads no repository name. The node's URL gives it, in GitHub's case.
  @Test func theRepositoryComesFromTheNodesURLInGitHubsCase() throws {
    let item = ReferenceItem(name: "issue", pull: false, repo: "Acme/Widgets")

    #expect(try wire(try parsed(item))["repo"] == "Acme/Widgets")
  }

  @Test func aNodeWithoutAnAuthorHasNoAuthor() throws {
    let item = ReferenceItem(name: "issue", pull: false, author: nil)

    #expect(try wire(try parsed(item))["author"] == nil)
  }

  @Test func aCommitWithoutChecksHasNoChecks() throws {
    let item = ReferenceItem(name: "PR", pull: true, checks: nil)

    #expect(try wire(try parsed(item))["checks"] == nil)
  }

  @Test func anIssueNodeHasNoPRFields() throws {
    let details = try wire(try parsed(ReferenceItem(name: "issue", pull: false)))

    #expect(details["checks"] == nil)
    #expect(details["reviewDecision"] == nil)
    #expect(details["mergeable"] == nil)
  }

  /// The service sets the read time when it fetches. The parser has no clock.
  @Test func aParsedNodeHasNoReadTime() throws {
    #expect(try wire(try parsed(ReferenceItem(name: "issue", pull: false)))["read"] == nil)
  }

  /// GitHub answers a repository that is missing, or that the token can't see, with a null repository. It answers a
  /// number that the repository has no item for with a null item. Both are "not found".
  @Test(arguments: [
    JSON.object(["rateLimit": ["cost": 1], "repository": .null]),
    JSON.object(["rateLimit": ["cost": 1], "repository": ["issueOrPullRequest": .null]]),
    JSON.object(["rateLimit": ["cost": 1]]),
    JSON.null,
  ])
  func aMissingRepositoryOrItemParsesAsNothing(_ data: JSON) {
    #expect(GitHub.parseReference(data) == nil)
  }

  @Test func theQueryReadsOneItemByOwnerNameAndNumber() {
    let query = GitHub.referenceQuery

    #expect(query.contains("issueOrPullRequest(number:"))
    #expect(query.contains("rateLimit"))
  }

  // MARK: Codable

  @Test(arguments: pullItems + issueItems)
  func detailsSurviveAJSONRoundTrip(_ item: ReferenceItem) throws {
    let details = try parsed(item)

    let decoded = try JSONCoding.decode(ReferenceDetails.self, from: try JSONCoding.encode(details))

    #expect(decoded == details)
  }

  /// The reply that the plan shows for `ref-details` decodes, `null` fields included.
  @Test func thePlansExampleReplyDecodes() throws {
    let text = """
      {"repo":"haacked/switchboard","number":283,"kind":"issue","title":"Issue and PR links",\
      "url":"https://github.com/haacked/switchboard/issues/283","state":"open","draft":false,"author":"haacked",\
      "labels":["enhancement"],"createdAt":"2026-11-10T08:00:00Z","updatedAt":"2026-11-13T09:00:00Z",\
      "checks":null,"reviewDecision":null,"mergeable":null,"source":"fetch","read":1794377400000}
      """

    let details = try JSONCoding.decode(ReferenceDetails.self, from: text)

    #expect(try wire(details)["read"] == 1_794_377_400_000)
    #expect(try wire(details)["kind"] == "issue")
  }

  // MARK: Parity (Risk 4)

  /// A session's PR and a fetch of the same PR agree on every field that both hold. Only the fetch reads
  /// `updatedAt`.
  @Test(arguments: pullItems)
  func aSessionsPRAndAFetchOfItAgree(_ item: ReferenceItem) throws {
    let differ: Set<String> = ["source", "read", "updatedAt"]

    let session = try shared(ReferenceDetails(pr: item.pullRequest), dropping: differ)
    let fetched = try shared(try parsed(item), dropping: differ)

    #expect(session == fetched)
  }

  @Test(arguments: issueItems)
  func aCachedIssueAndAFetchOfItAgree(_ item: ReferenceItem) throws {
    let differ: Set<String> = ["source", "read"]

    let cached = try shared(ReferenceDetails(issue: item.issue), dropping: differ)
    let fetched = try shared(try parsed(item), dropping: differ)

    #expect(cached == fetched)
  }

  /// No source drops or caps labels itself. Each keeps every label that its GitHub read returned.
  @Test(arguments: [true, false])
  func everySourceKeepsAllTwelveLabels(_ pull: Bool) throws {
    let item = ReferenceItem(name: "12 labels", pull: pull, labels: twelveLabels)
    let local = pull ? ReferenceDetails(pr: item.pullRequest) : ReferenceDetails(issue: item.issue)

    #expect(try wire(local)["labels"] == .array(twelveLabels.map(JSON.string)))
    #expect(try wire(try parsed(item))["labels"] == .array(twelveLabels.map(JSON.string)))
  }
}
