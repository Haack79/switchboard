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

// MARK: - Stage 3: the panel's rows

/// A ready PR that GitHub approved, with `verdicts` and merge details that
/// show every thread read and resolved and no test gaps.
private func approvedPR(_ verdicts: [Review], details: MergeDetails? = MergeDetails()) -> PullRequest {
  var pr = readyPR(reviewDecision: .approved, verdicts: verdicts)
  pr.mergeDetails = details
  return pr
}

private func approval(_ author: String, on commit: String?, at submittedAt: String = "2026-10-25T00:00:00Z")
  -> Review
{
  Review(author: author, state: "APPROVED", submittedAt: submittedAt, commit: commit)
}

private func reviewDetail(
  _ author: String, on commit: String?, commitsSince: Int?, body: String = "",
  notes: [MergeDetails.ReviewDetail.Note] = [],
  noteCount: Int? = nil
) -> MergeDetails.ReviewDetail {
  MergeDetails.ReviewDetail(
    author: author, bot: nil, state: "APPROVED", commit: commit, commitsSince: commitsSince, body: body,
    url: "https://github.com/acme/widgets/pull/42#pullrequestreview-3001", notes: notes,
    noteCount: noteCount ?? notes.count)
}

private func threadDetail(rootId: Int64?, path: String = "a.swift") -> MergeDetails.ThreadDetail {
  MergeDetails.ThreadDetail(
    rootId: rootId, url: "https://github.com/acme/widgets/pull/42#discussion_r\(rootId ?? 1)", path: path, line: 3,
    outdated: false, author: "ann", bot: nil, excerpt: "Why not use a guard?", replied: false)
}

/// The row's title and detail lines as one text, or nil when the review
/// hides the row.
private func rowText(_ review: MergeReview, _ row: MergeReview.Row) -> String? {
  review.lines.first { $0.row == row }.map { ([$0.title] + $0.details).joined(separator: "\n") }
}

private func rowTitle(_ review: MergeReview, _ row: MergeReview.Row) -> String? {
  review.lines.first { $0.row == row }?.title
}

private let headApproval = approval("stamphog", on: samplePRHead)

extension MergeReviewTests {
  @Suite struct Approvals {
    @Test func anApprovalOnTheHeadIsAtTheHead() throws {
      let review = MergeReview(approvedPR([headApproval]))

      let only = try #require(review.approvals.first)
      #expect(review.approvals.count == 1)
      #expect(only.author == "stamphog")
      #expect(only.atHead == true)
    }

    @Test func anApprovalOnAnEarlierCommitIsNotAtTheHead() {
      let review = MergeReview(approvedPR([approval("stamphog", on: "c0")]))

      #expect(review.approvals.map(\.atHead) == [false])
    }

    @Test func anApprovalWhoseCommitIsUnknownHasAnUnknownPlace() {
      let review = MergeReview(approvedPR([approval("stamphog", on: nil)]))

      #expect(review.approvals.map(\.atHead) == [nil])
    }

    @Test func approvalsSortNewestFirst() {
      let pr = approvedPR([
        approval("alice", on: samplePRHead, at: "2026-10-24T00:00:00Z"),
        approval("carol", on: samplePRHead, at: "2026-10-26T00:00:00Z"),
        approval("bob", on: "c0", at: "2026-10-25T00:00:00Z"),
      ])

      #expect(MergeReview(pr).approvals.map(\.author) == ["carol", "bob", "alice"])
    }

    @Test func aChangeRequestIsNotAnApproval() {
      var pr = approvedPR([headApproval])
      pr.verdicts.append(Review(author: "dana", state: "CHANGES_REQUESTED", commit: samplePRHead))

      #expect(MergeReview(pr).approvals.map(\.author) == ["stamphog"])
    }

    @Test func anApprovalTakesTheBodyNotesAndCommitsSinceOfItsReviewDetail() throws {
      let note = MergeDetails.ReviewDetail.Note(
        path: "a.swift", line: 3, excerpt: "Nit: a comment here.",
        url: "https://github.com/acme/widgets/pull/42#discussion_r3002")
      let details = MergeDetails(
        reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2, body: "Looks good.", notes: [note], noteCount: 4)]
      )
      let pr = approvedPR([approval("stamphog", on: "c0")], details: details)

      let only = try #require(MergeReview(pr).approvals.first)

      #expect(only.commitsSince == 2)
      #expect(only.body == "Looks good.")
      #expect(only.notes == [note])
      #expect(only.noteCount == 4)
    }

    /// GitHub's logins ignore case, and the status read and the merge details
    /// read can spell one differently.
    @Test func theJoinToAReviewDetailIgnoresTheLoginsCase() throws {
      let details = MergeDetails(reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2, body: "Looks good.")])
      let pr = approvedPR([approval("StampHog", on: "c0")], details: details)

      let only = try #require(MergeReview(pr).approvals.first)

      #expect(only.commitsSince == 2)
      #expect(only.body == "Looks good.")
    }

    /// The detail is an older review by the same reviewer, so its body is not this approval's.
    @Test func aReviewDetailOnAnotherCommitDoesNotJoin() throws {
      let details = MergeDetails(reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2, body: "Looks good.")])
      let pr = approvedPR([approval("stamphog", on: samplePRHead)], details: details)

      let only = try #require(MergeReview(pr).approvals.first)

      #expect(only.commitsSince == nil)
      #expect(only.body == nil)
      #expect(only.notes.isEmpty)
    }

    @Test func anApprovalWithoutAReviewDetailHasNoCommitsSince() throws {
      let only = try #require(MergeReview(approvedPR([approval("stamphog", on: "c0")])).approvals.first)

      #expect(only.commitsSince == nil)
    }

    @Test func aBotsApprovalIsMarkedBot() throws {
      var bot = headApproval
      bot.bot = true

      let only = try #require(MergeReview(approvedPR([bot])).approvals.first)

      #expect(only.bot == true)
    }

    @Test func noApprovalsAndNoReviewDecisionOnARepoThatWasReadMeansNoReviewRequired() {
      var pr = readyPR()
      pr.mergeDetails = MergeDetails()

      #expect(MergeReview(pr).noReviewRequired)
    }

    @Test(arguments: [
      ("GitHub approved but sbd read no approver", readyPR(reviewDecision: .approved)),
      ("an approval exists", readyPR(verdicts: [headApproval])),
    ])
    func otherwiseAReviewIsNotNoReviewRequired(_ label: String, _ pr: PullRequest) {
      #expect(!MergeReview(pr).noReviewRequired, "\(label)")
    }
  }
}

extension MergeReviewTests {
  @Suite struct Facts {
    @Test(arguments: [(MergeDetails?.none, false), (MergeDetails(), true)])
    func detailsReadSaysWhetherSbdReadTheMergeDetails(_ details: MergeDetails?, _ read: Bool) {
      #expect(MergeReview(approvedPR([headApproval], details: details)).detailsRead == read)
    }

    @Test func theShownThreadsAreTheThreadDetailsInOrder() throws {
      let details = MergeDetails(
        threads: 2, threadsRead: 2, openThreads: 2,
        threadDetails: [threadDetail(rootId: 1001, path: "a.swift"), threadDetail(rootId: 1002, path: "b.swift")])

      let threads = try #require(MergeReview(approvedPR([headApproval], details: details)).threads)

      #expect(threads.shown.map(\.path) == ["a.swift", "b.swift"])
      #expect(threads.shown.map(\.rootId) == [1001, 1002])
      #expect(threads.shown.allSatisfy { $0.drafts.isEmpty })
    }

    @Test func openThreadsWithoutDetailsShowNoThreads() throws {
      let details = MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, threadDetails: nil)

      let threads = try #require(MergeReview(approvedPR([headApproval], details: details)).threads)

      #expect(threads.shown.isEmpty)
    }

    @Test(arguments: [[String]?.none, [], ["bob"], ["bob", "PostHog/team-flags"]])
    func pendingReviewersAreTheOpenReviewRequests(_ requests: [String]?) {
      var pr = approvedPR([headApproval])
      pr.reviewRequests = requests

      #expect(MergeReview(pr).pendingReviewers == (requests ?? []))
    }

    @Test func changesRequestedByNamesTheReviewersWhoseLastVerdictRequestsChanges() {
      var pr = approvedPR([headApproval])
      pr.verdicts.append(Review(author: "dana", state: "CHANGES_REQUESTED", commit: samplePRHead))

      #expect(MergeReview(pr).changesRequestedBy == ["dana"])
    }
  }
}

/// The amber rule at the model, for the shapes that `Attention.readyToMerge`
/// never sees: `reviewSatisfied` keeps them out of Ready to merge, so they
/// have no merge option to demote. MergeAttentionTests.ReviewGuard covers the
/// shapes that reach the option.
extension MergeReviewTests {
  @Suite struct AmberAtTheModel {
    @Test func aChangeRequestMakesTheReviewersRowAmber() {
      var pr = approvedPR([headApproval])
      pr.verdicts.append(Review(author: "dana", state: "CHANGES_REQUESTED", commit: samplePRHead))

      #expect(MergeReview(pr).amber == [.reviewers])
    }

    @Test func noApprovalsWithAReviewDecisionThatWasNotReadMakeTheApprovalRowAmber() {
      var pr = samplePR(checks: "SUCCESS", reviewDecisionRead: nil)
      pr.mergeDetails = MergeDetails()

      #expect(MergeReview(pr).amber == [.approval])
    }

    @Test func noApprovalsWithReviewRequiredMakeTheApprovalRowAmber() {
      var pr = readyPR(reviewDecision: .reviewRequired)
      pr.mergeDetails = MergeDetails()

      #expect(MergeReview(pr).amber == [.approval])
    }

    @Test func amberRowsComeInPanelOrder() {
      var pr = approvedPR(
        [approval("stamphog", on: "c0")],
        details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, testGaps: ["Not run: e2e."]))
      pr.reviewRequests = ["bob"]

      #expect(MergeReview(pr).amber == [.approval, .threads, .reviewers, .testPlan])
    }
  }
}

/// The three callouts that the panel replaced, case for case, as rows with
/// the same text.
extension MergeReviewTests {
  @Suite struct Rows {
    // Review threads

    @Test(arguments: [
      (1, 1, 1, "1 open review thread"),
      (2, 2, 2, "2 open review threads"),
      (5, 5, 3, "3 open review threads"),
      (150, 100, 3, "At least 3 open review threads"),
      (150, 100, 0, "Not every review thread was read"),
    ])
    func openOrUnreadThreadsGiveAnAmberThreadsRowWithTheCalloutsTitle(
      _ threads: Int, _ read: Int, _ open: Int, _ title: String
    ) {
      let details = MergeDetails(threads: threads, threadsRead: read, openThreads: open, threadDetails: [])
      let review = MergeReview(approvedPR([headApproval], details: details))

      #expect(rowTitle(review, .threads) == title)
      #expect(review.amber.contains(.threads))
    }

    @Test(arguments: [(150, 100, 3), (150, 100, 0), (3, 2, 1)])
    func unreadThreadsSayHowManyWereRead(_ threads: Int, _ read: Int, _ open: Int) throws {
      let details = MergeDetails(threads: threads, threadsRead: read, openThreads: open)
      let review = MergeReview(approvedPR([headApproval], details: details))

      let text = try #require(rowText(review, .threads))
      #expect(text.contains("has \(threads) review threads, and sbd read \(read)."), "\(text)")
    }

    @Test(arguments: [(0, 0), (4, 4)])
    func everyThreadReadAndResolvedGivesAGreenThreadsRow(_ threads: Int, _ read: Int) {
      let details = MergeDetails(threads: threads, threadsRead: read, openThreads: 0, threadDetails: [])
      let review = MergeReview(approvedPR([headApproval], details: details))

      #expect(rowTitle(review, .threads) == "No open review threads")
      #expect(!review.amber.contains(.threads))
    }

    @Test func theThreadsRowNeverSaysZeroOpenThreads() throws {
      let details = MergeDetails(threads: 150, threadsRead: 100, openThreads: 0, threadDetails: [])
      let review = MergeReview(approvedPR([headApproval], details: details))

      let title = try #require(rowTitle(review, .threads))
      #expect(!title.hasPrefix("0 ") && !title.contains(" 0 open"))
    }

    // Before the read

    @Test(arguments: [MergeReview.Row.approval, .threads])
    func withoutDetailsTheRowSaysSbdHasNotReadThem(_ row: MergeReview.Row) throws {
      let review = MergeReview(approvedPR([headApproval], details: nil))

      let text = try #require(rowText(review, row))
      #expect(text.contains("sbd hasn't read the review details yet"), "\(text)")
    }

    // Test plan

    @Test func testGapsGiveAnAmberTestPlanRowThatNamesEach() throws {
      let gaps = ["Not run: the database-backed suites.", "Tested by hand"]
      let review = MergeReview(approvedPR([headApproval], details: MergeDetails(testGaps: gaps)))

      #expect(rowTitle(review, .testPlan) == "The test plan has gaps")
      let text = try #require(rowText(review, .testPlan))
      #expect(gaps.allSatisfy { text.contains($0) }, "\(text)")
      #expect(review.amber == [.testPlan])
    }

    @Test func noTestGapHidesTheTestPlanRow() {
      #expect(rowText(MergeReview(approvedPR([headApproval])), .testPlan) == nil)
    }

    // Other reviewers

    @Test func waitingCodeOwnerGroupsGiveTheRequiredWording() throws {
      let review = MergeReview(ownedPR([["@PostHog/team-flags"], ["@alice", "@bob"]], requests: []))

      let text = try #require(rowText(review, .reviewers))
      #expect(text.contains("Code owner review still required"), "\(text)")
      #expect(text.contains("@alice or @bob; @PostHog/team-flags"), "\(text)")
      #expect(review.amber == [.reviewers])
    }

    @Test func codeOwnerRequestsGiveTheRequestedWording() throws {
      let review = MergeReview(ownedPR(nil, requests: ["@PostHog/team-flags", "@alice"]))

      let text = try #require(rowText(review, .reviewers))
      #expect(text.contains("Code owners still requested"), "\(text)")
      #expect(text.contains("@PostHog/team-flags, @alice"), "\(text)")
      #expect(review.amber == [.reviewers])
    }

    @Test func pendingReviewRequestsAreNamedInTheReviewersRow() throws {
      var pr = approvedPR([headApproval])
      pr.reviewRequests = ["bob", "PostHog/team-flags"]

      let text = try #require(rowText(MergeReview(pr), .reviewers))

      #expect(text.contains("bob"), "\(text)")
      #expect(text.contains("PostHog/team-flags"), "\(text)")
    }

    @Test func noOtherReviewerHidesTheReviewersRow() {
      #expect(rowText(MergeReview(approvedPR([headApproval])), .reviewers) == nil)
    }

    // Approvals

    @Test func noApprovalWhereNoReviewIsRequiredSaysSo() throws {
      var pr = readyPR()
      pr.mergeDetails = MergeDetails()

      let text = try #require(rowText(MergeReview(pr), .approval))

      #expect(text.contains("No review required"), "\(text)")
    }

    @Test func anApprovalOnAnEarlierCommitSaysHowManyCommitsEarlier() throws {
      let details = MergeDetails(reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2)])

      let text = try #require(
        rowText(MergeReview(approvedPR([approval("stamphog", on: "c0")], details: details)), .approval))

      #expect(text.contains("2 commits earlier"), "\(text)")
    }

    @Test func anApprovalWithoutACommitCountSaysAnEarlierCommit() throws {
      let text = try #require(rowText(MergeReview(approvedPR([approval("stamphog", on: "c0")])), .approval))

      #expect(text.contains("an earlier commit"), "\(text)")
    }

    @Test func theRowsKeepMarkdownCharactersUnescaped() throws {
      let gap = "Not run: the `e2e` *suite* [link](https://example.com)"
      let review = MergeReview(approvedPR([headApproval], details: MergeDetails(testGaps: [gap])))

      #expect(try #require(rowText(review, .testPlan)).contains(gap))
    }

    // One list drives every path

    @Test(arguments: [
      approvedPR([headApproval]),
      approvedPR([headApproval], details: nil),
      approvedPR([approval("stamphog", on: nil)]),
      approvedPR([headApproval], details: MergeDetails(threads: 150, threadsRead: 100, openThreads: 0)),
      approvedPR([headApproval], details: MergeDetails(testGaps: ["Not run: e2e."])),
      ownedPR([["@PostHog/team-flags"]], requests: []),
      readyPR(),
    ])
    func theAmberLinesAreTheAmberRowsInOrder(_ pr: PullRequest) {
      let review = MergeReview(pr)

      #expect(review.lines.filter(\.amber).map(\.row) == review.amber)
    }

    @Test(arguments: [approvedPR([headApproval]), approvedPR([headApproval], details: nil), readyPR()])
    func theApprovalAndThreadsRowsAlwaysShow(_ pr: PullRequest) {
      let rows = MergeReview(pr).lines.map(\.row)

      #expect(rows.contains(.approval))
      #expect(rows.contains(.threads))
    }
  }
}

/// `CodeOwnerGap` travels on `triage.message.review`, so its JSON is a
/// single-key object, not Swift's synthesized `{"waiting": {"_0": …}}`.
extension MergeReviewTests {
  @Suite struct CodeOwnerGapWire {
    @Test func waitingEncodesAsASingleKeyObjectOfGroups() throws {
      let gap = MergeReview.CodeOwnerGap.waiting([["@alice", "@bob"], ["@PostHog/team-flags"]])

      #expect(try JSON(encoding: gap) == ["waiting": [["@alice", "@bob"], ["@PostHog/team-flags"]]])
    }

    @Test func requestedEncodesAsASingleKeyObjectOfLogins() throws {
      #expect(try JSON(encoding: MergeReview.CodeOwnerGap.requested(["@carol"])) == ["requested": ["@carol"]])
    }

    @Test(arguments: [
      MergeReview.CodeOwnerGap.waiting([["@alice", "@bob"], ["@PostHog/team-flags"]]), .waiting([]),
      .requested(["@carol"]), .requested([]),
    ])
    func eachGapRoundTrips(_ gap: MergeReview.CodeOwnerGap) throws {
      #expect(try JSONCoding.convert(try JSON(encoding: gap), to: MergeReview.CodeOwnerGap.self) == gap)
    }

    @Test func theWaitingShapeDecodes() throws {
      let json: JSON = ["waiting": [["@alice", "@bob"], ["@PostHog/team-flags"]]]

      let gap = try JSONCoding.convert(json, to: MergeReview.CodeOwnerGap.self)

      #expect(gap == .waiting([["@alice", "@bob"], ["@PostHog/team-flags"]]))
    }

    @Test func theRequestedShapeDecodes() throws {
      #expect(
        try JSONCoding.convert(["requested": ["@carol"]], to: MergeReview.CodeOwnerGap.self) == .requested(["@carol"]))
    }

    @Test(
      arguments: [
        ["waiting": ["_0": [["@alice"]]]],
        ["requested": ["_0": ["@carol"]]],
        [:],
        ["waiting": [["@alice"]], "requested": ["@carol"]],
        ["waiting": ["@alice"]],
        ["requested": [["@carol"]]],
        ["waiting": "@alice"],
        ["other": ["@carol"]],
      ] as [JSON])
    func everyOtherShapeFailsToDecode(_ json: JSON) {
      #expect(throws: (any Error).self) { try JSONCoding.convert(json, to: MergeReview.CodeOwnerGap.self) }
    }

    @Test func aReviewWithAGapEncodesItUnderCodeOwnerGap() throws {
      let review = MergeReview(ownedPR([["@PostHog/team-flags"]], requests: []))

      #expect(try JSON(encoding: review)["codeOwnerGap"] == ["waiting": [["@PostHog/team-flags"]]])
    }
  }
}

extension MergeReviewTests {
  @Suite struct Coding {
    @Test(arguments: [
      approvedPR([headApproval]),
      approvedPR([headApproval], details: nil),
      approvedPR(
        [approval("stamphog", on: "c0"), approval("alice", on: samplePRHead, at: "2026-10-26T00:00:00Z")],
        details: MergeDetails(
          threads: 2, threadsRead: 2, openThreads: 1, testGaps: ["Not run: e2e."],
          threadDetails: [threadDetail(rootId: 1001), threadDetail(rootId: nil)],
          reviews: [reviewDetail("stamphog", on: "c0", commitsSince: 2, body: "Looks good.")])),
      ownedPR([["@PostHog/team-flags"], ["@alice", "@bob"]], requests: []),
    ])
    func aFullReviewSurvivesAJSONRoundTrip(_ pr: PullRequest) throws {
      let review = MergeReview(pr)

      let decoded = try JSONCoding.convert(try JSON(encoding: review), to: MergeReview.self)

      #expect(decoded == review)
    }

    @Test func amberEncodesAsTheRowNames() throws {
      var pr = approvedPR(
        [approval("stamphog", on: "c0")],
        details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, testGaps: ["Not run: e2e."]))
      pr.reviewRequests = ["bob"]

      let json = try JSON(encoding: MergeReview(pr))

      #expect(json["amber"] == ["approval", "threads", "reviewers", "testPlan"])
    }
  }
}
