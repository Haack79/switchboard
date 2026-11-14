import Foundation
import Testing

@testable import SwitchboardCore

private func details(threads: Int = 0, threadsRead: Int? = nil, openThreads: Int = 0, testGaps: [String] = [])
  -> MergeDetails
{
  MergeDetails(
    additions: 315, deletions: 208, changedFiles: 4, threads: threads, threadsRead: threadsRead ?? threads,
    openThreads: openThreads, description: "The description.", testGaps: testGaps)
}

private func reviewedPR(_ details: MergeDetails?) -> PullRequest {
  var pr = readyPR()
  pr.mergeDetails = details
  return pr
}

/// A ready PR whose author is haacked, with a code owner requirement and the
/// code owner requests that GitHub made.
private func ownedPR(_ groups: [[String]]?, requests: [String]?, verdicts: [Review] = []) -> PullRequest {
  var pr = readyPR(verdicts: verdicts)
  pr.author = "haacked"
  pr.codeOwners = groups.map { CodeOwnerRequirement(groups: $0) }
  pr.codeOwnerRequests = requests
  pr.mergeDetails = details()
  return pr
}

private let carolOnHead = sampleVerdict("carol", "APPROVED", on: samplePRHead)

@Suite struct MergeReviewTests {
  // Review threads

  @Test func withoutDetailsTheThreadCountsAreUnknown() {
    #expect(MergeReview(reviewedPR(nil)).threads == nil)
  }

  @Test func detailsWithNoThreadsGiveZeroCountsRatherThanUnknown() {
    let review = MergeReview(reviewedPR(details()))

    #expect(review.threads == MergeReview.Threads(total: 0, read: 0, open: 0))
  }

  @Test(arguments: [(4, 4, 2), (4, 4, 0), (1, 1, 1)])
  func threadsReadInFullGiveTheirCounts(_ total: Int, _ read: Int, _ open: Int) {
    let review = MergeReview(reviewedPR(details(threads: total, threadsRead: read, openThreads: open)))

    #expect(review.threads == MergeReview.Threads(total: total, read: read, open: open))
  }

  @Test(arguments: [(150, 100, 3), (150, 100, 0), (3, 2, 1)])
  func threadsReadInPartGiveTheCountReadBelowTheTotal(_ total: Int, _ read: Int, _ open: Int) {
    let review = MergeReview(reviewedPR(details(threads: total, threadsRead: read, openThreads: open)))

    #expect(review.threads == MergeReview.Threads(total: total, read: read, open: open))
  }

  // Test plan

  @Test func withoutDetailsThereAreNoTestGaps() {
    #expect(MergeReview(reviewedPR(nil)).testGaps.isEmpty)
  }

  @Test func testGapsComeFromTheDetailsInOrder() {
    let gaps = ["Not run: the database-backed suites.", "- [ ] Check the e2e suite"]

    #expect(MergeReview(reviewedPR(details(testGaps: gaps))).testGaps == gaps)
  }

  @Test func testGapsKeepMarkdownCharactersUnescaped() {
    let gap = "Not run: the `e2e` *suite* [link](https://example.com) #42"

    #expect(MergeReview(reviewedPR(details(testGaps: [gap]))).testGaps == [gap])
  }

  // Code owners

  @Test func aWaitingCodeOwnerGroupIsAGap() {
    let review = MergeReview(ownedPR([["@PostHog/team-flags"]], requests: []))

    #expect(review.codeOwnerGap == .waiting([["@PostHog/team-flags"]]))
  }

  @Test func everyWaitingGroupIsListedInCodeOwnerStatusOrder() {
    let review = MergeReview(ownedPR([["@PostHog/team-flags"], ["@alice", "@bob"]], requests: []))

    #expect(review.codeOwnerGap == .waiting([["@alice", "@bob"], ["@PostHog/team-flags"]]))
  }

  @Test func anApprovedGroupIsLeftOutOfTheWaitingGroups() {
    let pr = ownedPR([["@PostHog/team-flags"], ["@carol"]], requests: [], verdicts: [carolOnHead])

    #expect(MergeReview(pr).codeOwnerGap == .waiting([["@PostHog/team-flags"]]))
  }

  @Test func waitingGroupsWinOverPendingCodeOwnerRequests() {
    let pr = ownedPR([["@PostHog/team-flags"]], requests: ["@PostHog/team-flags"])

    #expect(MergeReview(pr).codeOwnerGap == .waiting([["@PostHog/team-flags"]]))
  }

  @Test func satisfiedCodeOwnersWithoutRequestsHaveNoGap() {
    let pr = ownedPR([["@carol"]], requests: [], verdicts: [carolOnHead])

    #expect(MergeReview(pr).codeOwnerGap == nil)
  }

  @Test func satisfiedCodeOwnersWithAPendingRequestStillListTheRequest() throws {
    let pr = ownedPR([["@carol"]], requests: ["@carol"], verdicts: [carolOnHead])
    let status = try #require(CodeOwnerStatus(pr))
    #expect(status.satisfied)

    #expect(MergeReview(pr).codeOwnerGap == .requested(["@carol"]))
  }

  @Test func codeOwnerRequestsWithoutARequirementAreAGap() {
    let review = MergeReview(ownedPR(nil, requests: ["@PostHog/team-flags", "@alice"]))

    #expect(review.codeOwnerGap == .requested(["@PostHog/team-flags", "@alice"]))
  }

  @Test func aRequestThatNoGroupNamesFallsBackToTheRequests() {
    let pr = ownedPR([["@alice"]], requests: ["@bob"])
    #expect(CodeOwnerStatus(pr) == nil)

    #expect(MergeReview(pr).codeOwnerGap == .requested(["@bob"]))
  }

  @Test(arguments: [[String]?.none, []])
  func noRequirementAndNoRequestsHaveNoGap(_ requests: [String]?) {
    #expect(MergeReview(ownedPR(nil, requests: requests)).codeOwnerGap == nil)
  }

  @Test func codeOwnerGapDoesNotDependOnTheDetails() {
    var pr = ownedPR([["@PostHog/team-flags"]], requests: [])
    pr.mergeDetails = nil

    #expect(MergeReview(pr).codeOwnerGap == .waiting([["@PostHog/team-flags"]]))
  }

  // Whole value

  @Test func aPRWithNothingToPauseHasNoGaps() {
    let review = MergeReview(reviewedPR(details(threads: 4, openThreads: 0)))

    #expect(review.threads == MergeReview.Threads(total: 4, read: 4, open: 0))
    #expect(review.testGaps.isEmpty)
    #expect(review.codeOwnerGap == nil)
  }

  @Test(arguments: [
    reviewedPR(nil),
    reviewedPR(details(threads: 150, threadsRead: 100, openThreads: 3, testGaps: ["Not run: e2e."])),
    ownedPR([["@PostHog/team-flags"], ["@alice", "@bob"]], requests: []),
    ownedPR(nil, requests: ["@PostHog/team-flags"]),
  ])
  func aReviewSurvivesAJSONRoundTrip(_ pr: PullRequest) throws {
    let review = MergeReview(pr)

    let decoded = try JSONDecoder().decode(MergeReview.self, from: JSONEncoder().encode(review))

    #expect(decoded == review)
  }
}
