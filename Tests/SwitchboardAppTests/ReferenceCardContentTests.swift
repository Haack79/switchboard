import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let hour: Int64 = 60 * 60 * 1000
private let day: Int64 = 24 * hour

/// `now` minus `ms`, as GitHub writes a time.
private func iso(_ ms: Int64) -> String {
  ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now - ms) / 1000))
}

private let ref = GitHubRef(parsing: "haacked/switchboard#283")!

/// sbd's `ref-details` reply for haacked/switchboard#283, with `fields` merged over an open issue's. A nil value
/// leaves the key out, as sbd does for a nil field.
private func details(_ fields: [String: JSON?] = [:]) throws -> ReferenceDetails {
  var object: [String: JSON] = [
    "repo": "haacked/switchboard", "number": 283, "kind": "issue", "title": "Link issues and PRs",
    "url": "https://github.com/haacked/switchboard/issues/283", "state": "open", "draft": false,
    "author": "haacked", "labels": ["enhancement"], "createdAt": .string(iso(3 * day)),
    "updatedAt": .string(iso(2 * hour)), "source": "fetch", "read": 1_799_999_000_000,
  ]
  for (key, value) in fields { object[key] = value }
  return try JSONCoding.convert(JSON.object(object), to: ReferenceDetails.self)
}

/// A PR reply with every PR line set, merged with `fields`.
private func pull(_ fields: [String: JSON?] = [:]) throws -> ReferenceDetails {
  var all: [String: JSON?] = [
    "kind": "pr", "url": "https://github.com/haacked/switchboard/pull/283", "checks": "SUCCESS",
    "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
  ]
  for (key, value) in fields { all[key] = value }
  return try details(all)
}

private func content(_ load: ReferenceLoad?, sessions: [SessionSummary] = []) -> ReferenceCardContent {
  ReferenceCardContent(ref, load: load, sessions: sessions, now: now)
}

private func loaded(_ d: ReferenceDetails, sessions: [SessionSummary] = []) -> ReferenceCardContent {
  content(.loaded(d), sessions: sessions)
}

private func session(_ id: String, pr: (repo: String, number: Int)? = nil, issues: [SessionIssue]? = nil)
  -> SessionSummary
{
  var s = needsItem(id, state: .working)
  s.pr = pr.map {
    PRSummary(
      PullRequest(
        id: "PR_\($0.number)", number: $0.number, url: "https://github.com/\($0.repo)/pull/\($0.number)", repo: $0.repo)
    )
  }
  s.issues = issues
  return s
}

@Suite struct ReferenceCardContentTests {
  @Suite struct Header {
    @Test func theHeaderNamesTheRepositoryAndNumber() throws {
      let c = loaded(try details())

      #expect(c.repo == "haacked/switchboard")
      #expect(c.number == 283)
    }

    @Test func theTitleIsTheItemsTitle() throws {
      #expect(loaded(try details()).title == "Link issues and PRs")
    }
  }

  @Suite struct StateChip {
    @Test(arguments: [
      ("issue", "open", false, "Open issue", ReferenceCardContent.Tone.green),
      ("issue", "closed", false, "Closed issue", .purple),
      ("pr", "open", false, "Open pull request", .green),
      ("pr", "open", true, "Draft pull request", .gray),
      ("pr", "merged", false, "Merged pull request", .purple),
      ("pr", "closed", false, "Closed pull request", .red),
    ])
    func eachStateHasItsChip(kind: String, state: String, draft: Bool, text: String, tone: ReferenceCardContent.Tone)
      throws
    {
      let d = try details(["kind": .string(kind), "state": .string(state), "draft": .bool(draft)])

      let chip = try #require(loaded(d).chip)

      #expect(chip.text == text)
      #expect(chip.tone == tone)
    }
  }

  @Suite struct Meta {
    @Test func theMetaLineNamesTheAuthorAndBothTimes() throws {
      #expect(loaded(try details()).meta == "by haacked · opened 3d ago · updated 2h ago")
    }

    @Test func aNilAuthorIsLeftOut() throws {
      #expect(loaded(try details(["author": nil])).meta == "opened 3d ago · updated 2h ago")
    }

    /// A session's PR has no `updatedAt`.
    @Test func aNilUpdateTimeIsLeftOut() throws {
      #expect(loaded(try details(["updatedAt": nil])).meta == "by haacked · opened 3d ago")
    }

    @Test func noAuthorAndNoTimesGiveNoMetaLine() throws {
      #expect(loaded(try details(["author": nil, "createdAt": nil, "updatedAt": nil])).meta == nil)
    }
  }

  @Suite struct Labels {
    @Test func noLabelsGiveNoChips() throws {
      let c = loaded(try details(["labels": []]))

      #expect(c.labels.isEmpty)
      #expect(c.extraLabels == 0)
    }

    @Test func twelveLabelsShowTheFirstSix() throws {
      let names = (1...12).map { "label-\($0)" }

      let c = loaded(try details(["labels": .array(names.map(JSON.string))]))

      #expect(c.labels == Array(names.prefix(6)))
    }

    @Test func twelveLabelsCountTheSixLeftOut() throws {
      let names = (1...12).map { "label-\($0)" }

      #expect(loaded(try details(["labels": .array(names.map(JSON.string))])).extraLabels == 6)
    }

    @Test func theCountUsesGitHubsTotalWhenTheReadHoldsFewerLabels() throws {
      let names = (1...10).map { "label-\($0)" }

      #expect(loaded(try details(["labels": .array(names.map(JSON.string)), "labelCount": 15])).extraLabels == 9)
    }

    @Test func sixLabelsShowAllOfThemAndNoCount() throws {
      let names = (1...6).map { "label-\($0)" }

      let c = loaded(try details(["labels": .array(names.map(JSON.string))]))

      #expect(c.labels == names)
      #expect(c.extraLabels == 0)
    }
  }

  @Suite struct PullRequestLines {
    @Test func anOpenPRListsChecksReviewAndMergeability() throws {
      #expect(loaded(try pull()).prLines == ["Checks passing", "Approved", "No conflicts"])
    }

    /// A draft is open, so its lines show.
    @Test func aDraftPRListsItsLines() throws {
      #expect(loaded(try pull(["draft": true])).prLines == ["Checks passing", "Approved", "No conflicts"])
    }

    @Test(arguments: ["merged", "closed"])
    func aPRThatIsNotOpenHasNoLines(_ state: String) throws {
      #expect(loaded(try pull(["state": .string(state)])).prLines.isEmpty)
    }

    @Test func anIssueHasNoLines() throws {
      #expect(loaded(try details()).prLines.isEmpty)
    }

    @Test(arguments: [
      ("SUCCESS", "Checks passing"), ("FAILURE", "Checks failing"), ("ERROR", "Checks failing"),
      ("PENDING", "Checks running"), ("EXPECTED", "Checks running"),
    ])
    func eachChecksRollupHasItsLine(_ rollup: String, _ line: String) throws {
      let d = try pull(["checks": .string(rollup), "reviewDecision": nil, "mergeable": nil])

      #expect(loaded(d).prLines == [line])
    }

    @Test(arguments: [
      ("APPROVED", "Approved"), ("CHANGES_REQUESTED", "Changes requested"), ("REVIEW_REQUIRED", "Review required"),
    ])
    func eachReviewDecisionHasItsLine(_ decision: String, _ line: String) throws {
      let d = try pull(["checks": nil, "reviewDecision": .string(decision), "mergeable": nil])

      #expect(loaded(d).prLines == [line])
    }

    @Test(arguments: [
      ("MERGEABLE", "No conflicts"), ("CONFLICTING", "Conflicts"), ("UNKNOWN", "Checking mergeability"),
    ])
    func eachMergeabilityHasItsLine(_ mergeable: String, _ line: String) throws {
      let d = try pull(["checks": nil, "reviewDecision": nil, "mergeable": .string(mergeable)])

      #expect(loaded(d).prLines == [line])
    }

    @Test func anOpenPRWithNoneOfTheFactsHasNoLines() throws {
      #expect(loaded(try pull(["checks": nil, "reviewDecision": nil, "mergeable": nil])).prLines.isEmpty)
    }
  }

  @Suite struct Sessions {
    private let all = [
      session("pr-here", pr: ("haacked/switchboard", 283)),
      session("other-pr", pr: ("haacked/switchboard", 284)),
      session("issue-here", issues: [bodyIssue(283, "Haacked/Switchboard")]),
      session("other-repo", issues: [bodyIssue(283, "PostHog/posthog")]),
      session("unknown-repo", issues: [SessionIssue(repo: nil, number: 283, via: .branch, url: nil)]),
    ]

    /// Parity: the card lists exactly what Core's matcher finds, in its order.
    @Test func theRowsAreTheSessionsThatReferenceSessionsMatches() throws {
      let rows = loaded(try details(), sessions: all).sessions

      #expect(rows.map(\.id) == ReferenceSessions.matching(ref, in: all).map(\.id))
    }

    @Test func aSessionWhosePRIsTheItemAndOneWhoseIssueIsTheItemAreListed() throws {
      #expect(loaded(try details(), sessions: all).sessions.map(\.id) == ["pr-here", "issue-here"])
    }

    @Test func aRowCarriesTheSessionsNameAndState() throws {
      var s = session("pr-here", pr: ("haacked/switchboard", 283))
      s.name = "fix-links"
      s.state = .needsYou

      let row = try #require(loaded(try details(), sessions: [s]).sessions.first)

      #expect(row.name == "fix-links")
      #expect(row.state == .needsYou)
    }

    @Test func noMatchingSessionGivesNoRows() throws {
      #expect(loaded(try details(), sessions: [session("other-pr", pr: ("haacked/switchboard", 284))]).sessions.isEmpty)
    }
  }

  @Suite struct Loading {
    @Test(arguments: [ReferenceLoad?.none, .loading])
    func beforeTheFirstAnswerTheCardIsLoading(_ load: ReferenceLoad?) {
      #expect(content(load).loading)
    }

    @Test func aLoadingCardTakesItsHeaderFromTheReference() {
      let c = content(.loading)

      #expect(c.repo == "haacked/switchboard")
      #expect(c.number == 283)
    }

    @Test func aLoadingCardHasNoTitleChipOrMessage() {
      let c = content(.loading)

      #expect(c.title == nil)
      #expect(c.chip == nil)
      #expect(c.message == nil)
    }

    @Test func aLoadedCardIsNotLoading() throws {
      #expect(!loaded(try details()).loading)
    }
  }

  @Suite struct Failure {
    @Test func anErrorShowsItsMessage() {
      #expect(
        content(.failed("paused after a GitHub GraphQL rate limit")).message
          == "paused after a GitHub GraphQL rate limit")
    }

    @Test func anErrorKeepsTheHeaderFromTheReference() {
      let c = content(.failed("network down"))

      #expect(c.repo == "haacked/switchboard")
      #expect(c.number == 283)
    }

    @Test func anErrorHasNoTitleChipOrLoadingLine() {
      let c = content(.failed("network down"))

      #expect(c.title == nil)
      #expect(c.chip == nil)
      #expect(!c.loading)
    }

    @Test func notFoundSaysTheTokenMayNotSeeIt() {
      let c = content(.notFound)

      #expect(c.message == "Not found, or your GitHub token can't see it.")
      #expect(c.repo == "haacked/switchboard")
      #expect(c.number == 283)
      #expect(!c.loading)
    }

    /// Only a not-found answer gets the card's own words. An error that mentions "not found" is shown as sbd wrote it.
    @Test func anErrorThatSaysNotFoundShowsItsMessage() {
      let error = "haacked/switchboard#283 not found, or your GitHub token can't see it"

      #expect(content(.failed(error)).message == error)
    }

    @Test func aLoadedCardHasNoMessage() throws {
      #expect(loaded(try details()).message == nil)
    }
  }
}
