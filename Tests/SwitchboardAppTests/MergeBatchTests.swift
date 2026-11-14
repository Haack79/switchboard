import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A Ready to merge session whose PR's repository merges by `method`.
private func readySession(
  _ id: String, _ method: MergeMethod?, since: Int64 = 0, state: AttentionState = .readyToMerge
) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.since = since
  var pr = PRSummary(
    PullRequest(id: "PR_\(id)", number: 1, url: "https://github.com/acme/widgets/pull/1", repo: "acme/widgets"))
  pr.mergeMethod = method
  s.pr = pr
  return s
}

/// Session `id`, Ready to merge on acme/widgets#`number` "Fix it", which stamphog approved on its head. Its item
/// carries the review of the PR with `details`, or no review when `reviewed` is false, as an older sbd sends it.
private func reviewedSession(
  _ id: String, number: Int, details: MergeDetails? = MergeDetails(threadDetails: []), reviewed: Bool = true
) -> SessionSummary {
  var s = readySession(id, .merge)
  var pr = PullRequest(
    id: "PR_\(id)", number: number, url: "https://github.com/acme/widgets/pull/\(number)", repo: "acme/widgets",
    title: "Fix it", headSha: "h1", reviewDecision: .approved,
    verdicts: [Review(author: "stamphog", state: "APPROVED", commit: "h1")], reviewRequests: [], trunkConfig: false,
    reviewDecisionRead: true, mergeQueue: false)
  pr.mergeDetails = details
  var summary = PRSummary(pr)
  summary.mergeMethod = .merge
  s.pr = summary
  s.triage = TriageItem(
    title: "Merge #\(number)", kind: .approval, summary: "", review: reviewed ? MergeReview(pr) : nil, source: .rule)
  return s
}

private let twoOpenThreadsAndATestGap = MergeDetails(
  threads: 2, threadsRead: 2, openThreads: 2, testGaps: ["- [ ] Check the e2e suite"])

private let twoOpenThreads = MergeDetails(threads: 2, threadsRead: 2, openThreads: 2)

@Suite struct MergeBatchTests {
  @Test func batchLeavesOutOtherSessionsWhoseMethodIsUnknown() {
    let a = readySession("a", .merge)
    let b = readySession("b", .unknown, since: 1)
    let c = readySession("c", .trunk, since: 2)

    #expect(a.readyToMergeSessions(all: [a, b, c]).map(\.id) == ["a", "c"])
  }

  @Test func batchFromASessionWhoseMethodIsUnknownIsEmpty() {
    let a = readySession("a", .unknown)
    let b = readySession("b", .merge)

    #expect(a.readyToMergeSessions(all: [a, b]).isEmpty)
  }

  @Test func batchKeepsEveryMethodThatMergesOrEnqueuesOldestFirst() {
    let a = readySession("a", .merge, since: 5)
    let b = readySession("b", .trunk, since: 3)
    let c = readySession("c", .mergeQueue, since: 1)
    let d = readySession("d", .merge, since: 2)

    #expect(a.readyToMergeSessions(all: [a, b, c, d]).map(\.id) == ["a", "c", "d", "b"])
  }

  @Test func batchLeavesOutSessionsThatAreNotReadyToMerge() {
    let a = readySession("a", .merge)
    let b = readySession("b", .merge, since: 1, state: .waiting)

    #expect(a.readyToMergeSessions(all: [a, b]).map(\.id) == ["a"])
  }

  @Test(arguments: [[MergeMethod.merge], [.merge, .merge]])
  func titleIsMergeAllWhenEverySessionMerges(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Merge All")
  }

  @Test(arguments: [[MergeMethod.trunk], [.mergeQueue], [.trunk, .mergeQueue], [.mergeQueue, .mergeQueue]])
  func titleIsEnqueueAllWhenEverySessionEnqueues(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Enqueue All")
  }

  @Test(arguments: [[MergeMethod.merge, .trunk], [.mergeQueue, .merge], [.trunk, .merge, .mergeQueue]])
  func titleIsMergeAndEnqueueAllWhenTheMethodsMix(_ methods: [MergeMethod]) {
    let sessions = methods.enumerated().map { readySession("s\($0.offset)", $0.element) }

    #expect(mergeBatchTitle(sessions) == "Merge and Enqueue All")
  }

  // MARK: The confirmation's lines

  @Test func anAllGreenPRsLineNamesThePROnly() {
    #expect(mergeBatchLine(reviewedSession("a", number: 7)) == "Merge #7 Fix it (acme/widgets)")
  }

  @Test func aPRWithoutAReviewHasTheSameLineAsAnAllGreenPR() {
    #expect(mergeBatchLine(reviewedSession("a", number: 7, reviewed: false)) == "Merge #7 Fix it (acme/widgets)")
  }

  @Test func aSessionWithoutAPRHasNoLine() {
    var s = readySession("a", .merge)
    s.pr = nil

    #expect(mergeBatchLine(s) == nil)
  }

  @Test func anAmberPRsLineNamesThePRThenWhatToCheckFirst() throws {
    let line = try #require(mergeBatchLine(reviewedSession("a", number: 8, details: twoOpenThreadsAndATestGap)))

    #expect(line.hasPrefix("Merge #8 Fix it (acme/widgets)"))
    #expect(line.contains("check first:"))
    #expect(line.contains("2 open"))
    #expect(line.lowercased().contains("test plan"))
  }

  @Test func anAmberPRsLineNamesOnlyItsAmberRows() throws {
    let line = try #require(mergeBatchLine(reviewedSession("a", number: 8, details: twoOpenThreads)))

    #expect(line.contains("2 open"))
    #expect(!line.lowercased().contains("test plan"))
  }

  // MARK: The header

  @Test func theHeaderWithNoAmberPRCountsThePRs() {
    let sessions = [reviewedSession("a", number: 7), reviewedSession("b", number: 8)]

    #expect(mergeBatchHeader(sessions) == "2 PRs are ready to merge")
  }

  @Test func theHeaderWithOneAmberPRSaysItNeedsALook() {
    let sessions = [reviewedSession("a", number: 7), reviewedSession("b", number: 8, details: twoOpenThreads)]

    #expect(mergeBatchHeader(sessions) == "2 PRs are ready to merge, 1 needs a look")
  }

  @Test func theHeaderWithTwoAmberPRsSaysTheyNeedALook() {
    let sessions = [
      reviewedSession("a", number: 7), reviewedSession("b", number: 8, details: twoOpenThreads),
      reviewedSession("c", number: 9, details: twoOpenThreadsAndATestGap),
    ]

    #expect(mergeBatchHeader(sessions) == "3 PRs are ready to merge, 2 need a look")
  }

  @Test func aPRWithoutAReviewIsNotCountedAsNeedingALook() {
    let sessions = [reviewedSession("a", number: 7), reviewedSession("b", number: 8, reviewed: false)]

    #expect(mergeBatchHeader(sessions) == "2 PRs are ready to merge")
  }

  /// sbd hasn't read the details, so the review can't show the PR is green.
  @Test func aPRWhoseDetailsAreUnreadNeedsALook() {
    let sessions = [reviewedSession("a", number: 7), reviewedSession("b", number: 8, details: nil)]

    #expect(mergeBatchHeader(sessions) == "2 PRs are ready to merge, 1 needs a look")
  }
}
