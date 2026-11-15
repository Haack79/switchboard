import Foundation
import Testing

@testable import SwitchboardCore

private let onHead = sampleVerdict("stamphog", "APPROVED", on: samplePRHead)

/// Every thread read and resolved, and no test gaps.
private let greenDetails = MergeDetails(threads: 2, threadsRead: 2, openThreads: 0, threadDetails: [])

private let openThread = MergeDetails.ThreadDetail(
  rootId: 1001, url: "https://github.com/acme/widgets/pull/42#discussion_r1001", path: "a.swift", line: 3,
  outdated: false, author: "greptile-apps", bot: true, excerpt: "This default changes the replica count.",
  replied: false)

private let methods: [MergeMethod] = [.merge, .mergeQueue, .trunk]

/// Sets the facts that make the session's merge method `method`.
private func apply(_ method: MergeMethod, to pr: inout PullRequest) {
  switch method {
  case .merge: (pr.trunkConfig, pr.mergeQueue) = (false, false)
  case .mergeQueue: (pr.trunkConfig, pr.mergeQueue) = (false, true)
  case .trunk: (pr.trunkConfig, pr.mergeQueue) = (true, false)
  case .unknown: (pr.trunkConfig, pr.mergeQueue) = (nil, nil)
  }
}

/// A ready PR #42 that GitHub approved, with `verdicts` and `details`.
private func approved(
  _ verdicts: [Review] = [onHead], details: MergeDetails? = greenDetails, reviewRequests: [String]? = [],
  method: MergeMethod = .merge
) -> PullRequest {
  var pr = readyPR(reviewDecision: .approved, verdicts: verdicts, reviewRequests: reviewRequests)
  pr.mergeDetails = details
  apply(method, to: &pr)
  return pr
}

/// A ready PR #42 on a branch that requires no review, by haacked, with a
/// code owner requirement and the code owner requests that GitHub made.
private func owned(_ groups: [[String]]?, requests: [String]?) -> PullRequest {
  var pr = readyPR()
  pr.author = "haacked"
  pr.codeOwners = groups.map { CodeOwnerRequirement(groups: $0) }
  pr.codeOwnerRequests = requests
  pr.mergeDetails = greenDetails
  return pr
}

private func withDetails(_ pr: PullRequest, _ details: MergeDetails?) -> PullRequest {
  var pr = pr
  pr.mergeDetails = details
  return pr
}

private func reviewDetail(_ author: String, on commit: String, commitsSince: Int?) -> MergeDetails.ReviewDetail {
  MergeDetails.ReviewDetail(
    author: author, bot: nil, state: "APPROVED", commit: commit, commitsSince: commitsSince, body: "Looks good.",
    url: "https://github.com/acme/widgets/pull/42#pullrequestreview-3001", notes: [], noteCount: 0)
}

/// The Ready to merge verdict of a session whose turn ended and that then
/// got `pr`, and the item that the rule gives it.
private func readyItem(_ pr: PullRequest, then: [Event] = []) throws -> (verdict: Verdict, item: TriageItem) {
  let f = try prFacts(pr, then: then)
  let v = Attention.evaluate(session(), f, now: 1000)
  try #require(v.state == .readyToMerge, "the fixture gave \(v.state): \(v.reason)")
  return (v, try #require(Triage.item(f, v, kind: .work)))
}

/// One input shape that reaches `Attention.readyToMerge`, and the rows that
/// it makes amber.
struct GuardShape: Sendable, CustomTestStringConvertible {
  var label: String
  var pr: PullRequest
  var amber: [MergeReview.Row]

  var testDescription: String { label }
}

private let amberShapes: [GuardShape] = [
  GuardShape(label: "details not read", pr: approved(details: nil), amber: [.approval, .threads]),
  GuardShape(
    label: "some threads unread and none of those read open",
    pr: approved(details: MergeDetails(threads: 150, threadsRead: 100, openThreads: 0, threadDetails: [])),
    amber: [.threads]),
  GuardShape(
    label: "some threads unread and some open",
    pr: approved(details: MergeDetails(threads: 150, threadsRead: 100, openThreads: 3, threadDetails: [openThread])),
    amber: [.threads]),
  GuardShape(
    label: "an open thread with its details",
    pr: approved(details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, threadDetails: [openThread])),
    amber: [.threads]),
  GuardShape(
    label: "an open thread without its details",
    pr: approved(details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, threadDetails: nil)),
    amber: [.threads]),
  GuardShape(label: "GitHub approved but sbd read no approver", pr: approved([]), amber: [.approval]),
  GuardShape(
    label: "an approval on an unknown commit", pr: approved([sampleVerdict("stamphog", "APPROVED")]),
    amber: [.approval]),
  GuardShape(
    label: "one approval on the head and one on an unknown commit",
    pr: approved([onHead, sampleVerdict("alice", "APPROVED")]), amber: [.approval]),
  GuardShape(
    label: "an approval two commits earlier",
    pr: approved(
      [sampleVerdict("stamphog", "APPROVED", on: "c0")],
      details: MergeDetails(threadDetails: [], reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2)])),
    amber: [.approval]),
  GuardShape(
    label: "an approval on an earlier commit that a force-push dropped",
    pr: approved(
      [sampleVerdict("stamphog", "APPROVED", on: "c0")],
      details: MergeDetails(threadDetails: [], reviews: [reviewDetail("stamphog", on: "c0", commitsSince: nil)])),
    amber: [.approval]),
  GuardShape(label: "review requests not read", pr: approved(reviewRequests: nil), amber: [.reviewers]),
  GuardShape(
    label: "code owner requests not read",
    pr: {
      var pr = approved()
      pr.codeOwnerRequests = nil
      return pr
    }(), amber: [.reviewers]),
  GuardShape(
    label: "neither request list read",
    pr: {
      var pr = approved(reviewRequests: nil)
      pr.codeOwnerRequests = nil
      return pr
    }(), amber: [.reviewers]),
  GuardShape(label: "a pending user review request", pr: approved(reviewRequests: ["bob"]), amber: [.reviewers]),
  GuardShape(
    label: "a pending team review request", pr: approved(reviewRequests: ["PostHog/team-flags"]),
    amber: [.reviewers]),
  GuardShape(
    label: "a code owner group still waiting", pr: owned([["@PostHog/team-flags"]], requests: []),
    amber: [.reviewers]),
  GuardShape(
    label: "code owners requested without a requirement", pr: owned(nil, requests: ["@PostHog/team-flags"]),
    amber: [.reviewers]),
  GuardShape(
    label: "a test plan gap", pr: approved(details: MergeDetails(testGaps: ["Not run: the database-backed suites."])),
    amber: [.testPlan]),
  GuardShape(
    label: "an earlier approval, an open thread, and a test gap",
    pr: approved(
      [sampleVerdict("stamphog", "APPROVED", on: "c0")],
      details: MergeDetails(
        threads: 1, threadsRead: 1, openThreads: 1, testGaps: ["Tested by hand"], threadDetails: [openThread])),
    amber: [.approval, .threads, .testPlan]),
]

private let greenShapes: [GuardShape] = [
  GuardShape(label: "approved on the head", pr: approved(), amber: []),
  GuardShape(label: "no review required", pr: withDetails(readyPR(), greenDetails), amber: []),
  GuardShape(
    label: "one approval on the head and one earlier",
    pr: approved([onHead, sampleVerdict("alice", "APPROVED", on: "c0")]), amber: []),
  GuardShape(
    label: "every thread read and resolved",
    pr: approved(details: MergeDetails(threads: 4, threadsRead: 4, openThreads: 0, threadDetails: [])), amber: []),
  GuardShape(
    label: "satisfied code owners",
    pr: {
      var pr = owned([["@carol"]], requests: [])
      pr.verdicts = [sampleVerdict("carol", "APPROVED", on: samplePRHead)]
      return pr
    }(), amber: []),
]

/// The guard decides whether ⌘⇧Return merges. Merge stays the main option
/// only when every row is known to be green. Each shape asserts the paths
/// that must agree: the verdict's review, the item's review, the merge
/// option's label and `recommended`, and the item's main option.
extension MergeAttentionTests {
  @Suite struct ReviewGuard {
    @Test(arguments: amberShapes)
    func anAmberRowDemotesTheMergeOption(_ shape: GuardShape) throws {
      let (v, item) = try readyItem(shape.pr)

      #expect(v.review?.amber == shape.amber)
      #expect(item.review?.amber == shape.amber)
      let merge = try #require(item.options.first { $0.action == .merge })
      #expect(merge.label == "Merge #42 anyway")
      #expect(merge.detail == "#42 has open review items")
      #expect(!merge.recommended)
      #expect(item.primary == nil)
    }

    @Test(arguments: greenShapes)
    func everyRowGreenKeepsMergeAsTheMainOption(_ shape: GuardShape) throws {
      let (v, item) = try readyItem(shape.pr)

      #expect(v.review?.amber == [])
      #expect(item.review?.amber == [])
      let merge = try #require(item.options.first { $0.action == .merge })
      #expect(merge.label == "Merge #42")
      #expect(merge.recommended)
      #expect(item.primary == merge)
    }

    @Test(arguments: methods)
    func allGreenKeepsEachMethodsOptionAsTheMainOption(_ method: MergeMethod) throws {
      let (_, item) = try readyItem(approved(method: method))

      #expect(item.primary?.label == "\(method.verb) #42")
      #expect(item.primary?.action == .merge)
      #expect(item.primary?.recommended == true)
    }

    @Test(arguments: methods)
    func anAmberRowDemotesEachMethodsOptionToAnyway(_ method: MergeMethod) throws {
      let (_, item) = try readyItem(approved(details: nil, method: method))

      let merge = try #require(item.options.first { $0.action == .merge })
      #expect(merge.label == "\(method.verb) #42 anyway")
      #expect(!merge.recommended)
      #expect(item.primary == nil)
    }

    /// Acknowledge stays, and stays not recommended, so nothing is the main option.
    @Test func theDemotedItemStillOffersAcknowledgeAsASecondaryOption() throws {
      let (_, item) = try readyItem(approved(details: nil))

      #expect(item.options.map(\.action) == [.merge, .dismiss])
      #expect(item.options.allSatisfy { !$0.recommended })
    }

    /// The only option left is Acknowledge, which the item's main button
    /// then runs, as before the panel.
    @Test(arguments: [approved(details: nil), approved()])
    func anUnknownMergeMethodStillHasNoMergeOption(_ pr: PullRequest) throws {
      var pr = pr
      apply(.unknown, to: &pr)

      let (v, item) = try readyItem(pr)

      #expect(!item.options.contains { $0.action == .merge })
      #expect(item.primary?.action != .merge)
      #expect(v.review != nil)
      #expect(item.review == v.review)
    }

    @Test func theVerdictsOptionsMatchTheItemsOptions() throws {
      let (v, item) = try readyItem(approved(details: nil))

      #expect(v.options == item.options)
    }

    @Test func theVerdictsReviewIsTheReviewOfItsPR() throws {
      let pr = approved(
        [sampleVerdict("stamphog", "APPROVED", on: "c0")],
        details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, threadDetails: [openThread]))

      let (v, _) = try readyItem(pr)

      #expect(v.review == MergeReview(pr))
    }
  }
}

/// The panel replaced three callouts. "The last merge failed" stays one.
extension MergeAttentionTests {
  @Suite struct ReviewCallouts {
    /// A PR that every replaced callout would warn about.
    private func pausedPR() -> PullRequest {
      var pr = approved(
        details: MergeDetails(
          threads: 150, threadsRead: 100, openThreads: 3, testGaps: ["Not run: the e2e suite."],
          threadDetails: [openThread]))
      pr.author = "haacked"
      pr.codeOwners = CodeOwnerRequirement(groups: [["@PostHog/team-flags"]])
      pr.codeOwnerRequests = ["@PostHog/team-flags"]
      return pr
    }

    @Test func theReplacedCalloutsAreGone() throws {
      let (v, item) = try readyItem(pausedPR())

      #expect(v.callouts.isEmpty)
      #expect(item.callouts.isEmpty)
    }

    @Test func aFailedMergeAtTheHeadIsStillTheOnlyCallout() throws {
      let failed = mergeEvent(4, head: samplePRHead, "failed", error: "Pull request is not mergeable")

      let (v, _) = try readyItem(pausedPR(), then: [failed])

      #expect(v.callouts.map(\.title) == ["The last merge failed"])
      #expect(v.callouts.map(\.kind) == [.warning])
      #expect(v.callouts.first?.body == "Pull request is not mergeable")
    }

    @Test func theRowsCarryWhatTheCalloutsSaid() throws {
      let (v, _) = try readyItem(pausedPR())

      #expect(v.review?.amber == [.threads, .reviewers, .testPlan])
      #expect(v.review?.threads?.open == 3)
      #expect(v.review?.testGaps == ["Not run: the e2e suite."])
      // GitHub approved while a code owner group waits. CodeOwnerStatus then can't tell the groups, and the requests stand.
      #expect(v.review?.codeOwnerGap == .requested(["@PostHog/team-flags"]))
    }
  }
}

/// Only Ready to merge carries the panel. Other PR verdicts keep their callouts.
extension MergeAttentionTests {
  @Suite struct ReviewOnlyWhenReady {
    @Test(arguments: [
      ("under review", readyPR(reviewDecision: .reviewRequired)),
      ("checks running", approved(details: nil).with { $0.checks = "PENDING" }),
      ("conflict", approved().with { $0.mergeable = .conflicting }),
    ])
    func aPRThatIsNotReadyToMergeHasNoReview(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)
      let v = Attention.evaluate(session(), f, now: 1000)
      try #require(v.state != .readyToMerge, "\(label)")

      #expect(v.review == nil, "\(label)")
      #expect(Triage.item(f, v, kind: .work)?.review == nil, "\(label)")
    }
  }
}

extension PullRequest {
  fileprivate func with(_ edit: (inout PullRequest) -> Void) -> PullRequest {
    var pr = self
    edit(&pr)
    return pr
  }
}
