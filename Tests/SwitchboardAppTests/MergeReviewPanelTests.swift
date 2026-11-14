import Foundation
import SwiftUI
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

let reviewHead = "c0ffee"

/// An open thread on PostHog/charts#18303, the PR that `replyTarget` answers.
func reviewThread(
  _ rootId: Int64? = 1001, path: String = "a.swift", line: Int? = 12, outdated: Bool = false, author: String = "ann",
  bot: Bool? = nil, replied: Bool = false, url: String? = nil
) -> MergeDetails.ThreadDetail {
  MergeDetails.ThreadDetail(
    rootId: rootId, url: url ?? "https://github.com/PostHog/charts/pull/18303#discussion_r\(rootId ?? 1)",
    path: path, line: line, outdated: outdated, author: author, bot: bot, excerpt: "Why not use a guard?",
    replied: replied)
}

/// Every thread read and resolved, and no test gaps.
let greenReviewDetails = MergeDetails(threads: 2, threadsRead: 2, openThreads: 0, threadDetails: [])

/// PostHog/charts#18303, approved by stamphog on its head unless `verdicts` says otherwise.
func reviewedPR(
  details: MergeDetails? = greenReviewDetails,
  verdicts: [Review] = [
    Review(author: "stamphog", state: "APPROVED", submittedAt: "2026-11-14T10:00:00Z", commit: reviewHead)
  ],
  reviewRequests: [String]? = [], method: MergeMethod = .merge
) -> PullRequest {
  var pr = PullRequest(
    id: "PR_18303", number: 18303, url: "https://github.com/PostHog/charts/pull/18303", repo: "PostHog/charts",
    title: "Fix the chart", headSha: reviewHead, reviewDecision: .approved, verdicts: verdicts, checks: "SUCCESS",
    reviewRequests: reviewRequests, trunkConfig: method == .trunk, reviewDecisionRead: true,
    mergeQueue: method == .mergeQueue)
  pr.mergeDetails = details
  return pr
}

/// One review for each way the panel can look, and the rows that it makes amber.
struct PanelShape: Sendable, CustomTestStringConvertible {
  var label: String
  var pr: PullRequest
  var amber: [MergeReview.Row]

  var testDescription: String { label }
}

let panelShapes: [PanelShape] = [
  PanelShape(label: "all green", pr: reviewedPR(), amber: []),
  PanelShape(
    label: "an open thread",
    pr: reviewedPR(
      details: MergeDetails(threads: 1, threadsRead: 1, openThreads: 1, threadDetails: [reviewThread()])),
    amber: [.threads]),
  PanelShape(
    label: "an approval on an earlier commit",
    pr: reviewedPR(verdicts: [Review(author: "stamphog", state: "APPROVED", commit: "0ld")]), amber: [.approval]),
  PanelShape(label: "a pending reviewer", pr: reviewedPR(reviewRequests: ["@carol"]), amber: [.reviewers]),
  PanelShape(
    label: "a test plan gap",
    pr: reviewedPR(details: MergeDetails(testGaps: ["- [ ] Check the e2e suite"], threadDetails: [])),
    amber: [.testPlan]),
  PanelShape(label: "details not read", pr: reviewedPR(details: nil), amber: [.approval, .threads]),
]

/// The shown thread of `detail`, holding drafts `drafts`.
private func shownThread(_ detail: MergeDetails.ThreadDetail = reviewThread(), drafts: [Int] = []) -> MergeReview.Thread
{
  var thread = MergeReview.Thread(detail)
  thread.drafts = drafts
  return thread
}

private func approval(atHead: Bool?, commitsSince: Int? = nil, url: String? = nil) -> MergeReview.Approval {
  MergeReview.Approval(
    author: "stamphog", bot: nil, atHead: atHead, commitsSince: commitsSince, body: nil, url: url, notes: [],
    noteCount: 0)
}

@Suite struct MergeReviewPanelTests {
  // MARK: Which rows show

  @Test(arguments: panelShapes)
  func theFixtureMakesTheRowsItNamesAmber(_ shape: PanelShape) {
    #expect(MergeReview(shape.pr).amber == shape.amber)
  }

  @Test(arguments: panelShapes)
  func theApprovalAndThreadsRowsAlwaysShow(_ shape: PanelShape) {
    let rows = MergeReview(shape.pr).lines.map(\.row)

    #expect(Array(rows.prefix(2)) == [.approval, .threads])
  }

  /// A hidden amber row would leave the merge option demoted with nothing on the card that says why.
  @Test(arguments: panelShapes)
  func everyAmberRowShows(_ shape: PanelShape) {
    let review = MergeReview(shape.pr)

    let shown = Set(review.lines.map(\.row))

    #expect(Set(review.amber).isSubset(of: shown))
  }

  @Test func greenOtherReviewersAndTestPlanRowsAreHidden() {
    let rows = MergeReview(reviewedPR()).lines.map(\.row)

    #expect(rows == [.approval, .threads])
  }

  @Test func anAmberOtherReviewersRowShows() {
    let rows = MergeReview(reviewedPR(reviewRequests: ["@carol"])).lines.map(\.row)

    #expect(rows == [.approval, .threads, .reviewers])
  }

  @Test func anAmberTestPlanRowShows() {
    let pr = reviewedPR(details: MergeDetails(testGaps: ["- [ ] Check the e2e suite"], threadDetails: []))

    #expect(MergeReview(pr).lines.map(\.row) == [.approval, .threads, .testPlan])
  }

  @Test(arguments: [MergeReview.Row.approval, .threads])
  func detailsNotReadSayTheReviewDetailsAreUnread(_ row: MergeReview.Row) throws {
    let review = MergeReview(reviewedPR(details: nil))
    let line = try #require(review.lines.first { $0.row == row })
    let note = row == .approval ? review.approvalNote : review.threadsNote

    #expect(line.amber)
    #expect(note == "sbd hasn't read the review details yet.")
    #expect(line.details.contains(try #require(note)))
  }

  // MARK: Icons

  @Test(arguments: panelShapes)
  func eachRowIsAmberExactlyWhenTheReviewListsIt(_ shape: PanelShape) {
    let review = MergeReview(shape.pr)

    for line in review.lines {
      #expect(line.amber == review.amber.contains(line.row), "\(line.row)")
    }
  }

  @Test func anAmberRowHasTheWarningCalloutsIconAndColor() {
    let icon = MergeReviewPanel.icon(amber: true)

    #expect(icon.name == CalloutView.style(.warning).icon)
    #expect(icon.color == CalloutView.style(.warning).color)
  }

  @Test func aGreenRowHasAGreenCheckmark() {
    let icon = MergeReviewPanel.icon(amber: false)

    #expect(icon.name == "checkmark.circle.fill")
    #expect(icon.color == .green)
  }

  // MARK: Thread place

  @Test func aThreadOnALineShowsItsPathAndLine() {
    #expect(shownThread(reviewThread(path: "a.swift", line: 12)).place == "a.swift:12")
  }

  @Test func aThreadWithoutALineShowsItsPath() {
    #expect(shownThread(reviewThread(path: "a.swift", line: nil)).place == "a.swift")
  }

  @Test(arguments: [Int?.none, 12])
  func anOutdatedThreadSaysOutdatedEvenWithAPath(_ line: Int?) {
    #expect(
      shownThread(reviewThread(path: "a.swift", line: line, outdated: true)).place == "outdated")
  }

  @Test func aThreadWithoutAPathIsOnThePRConversation() {
    #expect(shownThread(reviewThread(path: "", line: nil)).place == "PR conversation")
  }

  // MARK: Author and reply labels

  @Test func aRepliedThreadSaysYouReplied() {
    #expect(shownThread(reviewThread(replied: true)).replyLabel == "you replied")
  }

  @Test func anUnrepliedThreadSaysNoReply() {
    #expect(shownThread(reviewThread(replied: false)).replyLabel == "no reply")
  }

  // MARK: Approval place

  @Test func anApprovalOnTheHeadSaysSo() {
    #expect(approval(atHead: true, commitsSince: 0).place == "on the head")
  }

  @Test(arguments: [(1, "1 commit earlier"), (2, "2 commits earlier"), (14, "14 commits earlier")])
  func anApprovalOnAnEarlierCommitCountsTheCommitsSince(_ since: Int, _ expected: String) {
    #expect(approval(atHead: false, commitsSince: since).place == expected)
  }

  /// sbd lost the commit, for example after a force-push, so the panel can't count.
  @Test func anApprovalOnAnEarlierCommitWithoutACountSaysEarlier() {
    #expect(approval(atHead: false).place == "on an earlier commit")
  }

  @Test func anApprovalOnAnUnknownCommitSaysUnknown() {
    #expect(approval(atHead: nil).place == "on an unknown commit")
  }

  // MARK: Links

  @Test(arguments: [
    "https://github.com/PostHog/charts/pull/18303#discussion_r1001",
    "HTTPS://github.com/PostHog/charts/pull/18303#discussion_r1001",
  ])
  func anHttpsThreadURLIsALink(_ url: String) {
    #expect(MergeReviewPanel.link(url) != nil)
  }

  /// Anyone who can comment on the PR wrote the text around these URLs, and NSWorkspace would run a file or app URL.
  @Test(arguments: [
    "http://github.com/PostHog/charts/pull/18303#discussion_r1001",
    "javascript:alert(1)",
    "file:///etc/passwd",
    "//github.com/PostHog/charts/pull/18303",
    "github.com/PostHog/charts/pull/18303",
    "x-apple-systempreferences:com.apple.preference.security",
    "",
  ])
  func aURLThatIsNotHttpsIsNoLink(_ url: String) {
    #expect(MergeReviewPanel.link(url) == nil)
  }

  @Test func aThreadWhoseURLIsHttpShowsNoLink() {
    let thread = shownThread(reviewThread(url: "http://github.com/PostHog/charts/pull/18303#discussion_r1001"))

    #expect(MergeReviewPanel.link(thread.url) == nil)
  }

  @Test func anApprovalWithoutAURLShowsNoLink() {
    #expect(MergeReviewPanel.link(approval(atHead: true).url) == nil)
  }

  @Test func anApprovalWithAJavascriptURLShowsNoLink() {
    #expect(MergeReviewPanel.link(approval(atHead: true, url: "javascript:alert(1)").url) == nil)
  }

  // MARK: Drafts in a thread

  @Test func aThreadShowsEachDraftItHoldsInOrder() {
    let drafts = [targetedDraft(.ready(replyTarget), number: 1), targetedDraft(.ready(replyTarget), number: 2)]
    let item = TriageItem(title: "Merge", kind: .approval, summary: "", drafts: drafts, source: .session)

    let shown = MergeReviewPanel.drafts(shownThread(drafts: [1, 2]), in: item)

    #expect(shown.map(\.number) == [1, 2])
  }

  @Test func aThreadWithoutDraftsShowsNone() {
    let item = TriageItem(
      title: "Merge", kind: .approval, summary: "", drafts: [targetedDraft(.ready(replyTarget))], source: .session)

    #expect(MergeReviewPanel.drafts(shownThread(), in: item).isEmpty)
  }

  // MARK: Accessibility

  @Test(arguments: panelShapes)
  func eachRowsLabelReadsItsTitle(_ shape: PanelShape) {
    for line in MergeReview(shape.pr).lines {
      #expect(MergeReviewPanel.accessibilityLabel(line).contains(line.title), "\(line.row)")
    }
  }

  /// VoiceOver can't see the icon's color, so the label says whether the row needs a look.
  @Test func anAmberRowAndAGreenRowWithTheSameTitleReadDifferently() {
    let amber = MergeReview.Line(row: .threads, amber: true, title: "Review threads", details: [])
    let green = MergeReview.Line(row: .threads, amber: false, title: "Review threads", details: [])

    #expect(MergeReviewPanel.accessibilityLabel(amber) != MergeReviewPanel.accessibilityLabel(green))
  }
}
