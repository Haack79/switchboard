import Foundation
import SwitchboardCore
import Testing

extension FakeGitHub {
  /// The `threads` variable of each merge details read, oldest first. nil
  /// for a read that sent no `threads`.
  var threadsSent: [Bool?] {
    requests.filter { $0.kind == PRQuery.mergeDetails.rawValue }.map { $0.variables["threads"]?.bool }
  }
}

extension Instance {
  /// The merge details of the session's last `pr` event, as the events
  /// request returns it.
  func recordedMergeDetails(_ id: String) throws -> JSON? {
    try events(id, kind: "pr").last?.data["pr"]?["mergeDetails"]
  }
}

/// sbd reads each open thread's first comment, and each review's body and
/// inline comments, for the merge card's "Before you merge" panel. It reads
/// thread comments only for a PR at a merge decision that has or may have
/// open threads.
@Suite(.blocking(timeLimit: .seconds(180))) struct MergeReviewTests {
  static let earlier = "1111111111111111111111111111111111111111"
  static let middle = "2222222222222222222222222222222222222222"

  func ready(_ github: FakeGitHub) throws -> (Instance, SessionSummary) {
    let sbd = try Instance.withMergeStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    return (sbd, try MergeTests().readySession(sbd))
  }

  func pollAgain(_ sbd: Instance) throws {
    try sbd.advanceClock(600_000)
    try sbd.poll()
  }

  // MARK: The threads variable

  @Test func readyPRWithAnOpenThreadIsReadWithItsThreadComments() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, resolved: [true, false])

    _ = try ready(github)

    #expect(github.threadsSent == [true])
  }

  @Test func readyPRWhoseLastReadShowedAnOpenThreadIsReadWithThreadCommentsAgain() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, resolved: [false])
    let (sbd, _) = try ready(github)

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, true])
  }

  @Test func readyPRWithNoOpenThreadsIsReadWithoutThreadCommentsOnTheNextStatusRead() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, resolved: [true])
    let (sbd, _) = try ready(github)

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, false])
  }

  @Test func readyPRWithNoThreadsIsReadWithoutThreadCommentsOnTheNextStatusRead() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try ready(github)

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, false])
  }

  /// The read before covered 100 of 150 threads, so an unread one may be open.
  @Test func readyPRWhoseLastReadMissedThreadsIsReadWithThreadCommentsAgain() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, resolved: Array(repeating: true, count: 100), totalCount: 150)
    let (sbd, _) = try ready(github)

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, true])
  }

  @Test func prThatGainsAnOpenThreadIsReadAgainWithThreadCommentsInTheSamePoll() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try ready(github)
    github.reviewThreads(MergeTests.number, resolved: [false])

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, false, true])
  }

  @Test func prThatGainsAnOpenThreadRecordsItsDetailAfterTheSecondRead() throws {
    let github = try FakeGitHub()
    let (sbd, s) = try ready(github)
    github.reviewThreads(MergeTests.number, details: [FakeGitHub.FakeThread(path: "values.yaml", line: 30)])

    try pollAgain(sbd)

    let threads = try #require(try sbd.recordedMergeDetails(s.id)?["threadDetails"]?.array)
    #expect(threads.map { $0["path"]?.string } == ["values.yaml"])
  }

  @Test func newHeadIsReadWithThreadComments() throws {
    let github = try FakeGitHub()
    let (sbd, _) = try ready(github)
    github.change(MergeTests.number) { $0["headRefOid"] = "0123456789abcdef0123456789abcdef01234567" }

    try pollAgain(sbd)

    #expect(github.threadsSent == [true, true])
  }

  @Test func nudgeReadNeverAsksForThreadCommentsEvenWithAnOpenThread() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    github.reviewThreads(MergeTests.number, resolved: [false])
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)

    try sbd.poll()

    #expect(try sbd.get(s.id).state != .readyToMerge)
    #expect(github.threadsSent == [false])
  }

  // MARK: What the pr event records

  @Test func openThreadDetailIsRecordedOnThePREvent() throws {
    let github = try FakeGitHub()
    github.reviewThreads(
      MergeTests.number,
      details: [
        FakeGitHub.FakeThread(resolved: true, path: "resolved.yaml"),
        FakeGitHub.FakeThread(
          path: "charts/posthog/values.yaml", line: 30, author: "greptile-apps[bot]",
          body: "This default\nchanges the replica count.", discussionId: 3_456_789_012),
      ])

    let (sbd, s) = try ready(github)

    let threads = try #require(try sbd.recordedMergeDetails(s.id)?["threadDetails"]?.array)
    #expect(threads.count == 1)
    let thread = try #require(threads.first)
    #expect(thread["rootId"]?.int == 3_456_789_012)
    #expect(
      thread["url"]?.string == "https://github.com/PostHog/charts/pull/18303#discussion_r3456789012")
    #expect(thread["path"]?.string == "charts/posthog/values.yaml")
    #expect(thread["line"]?.int == 30)
    #expect(thread["author"]?.string == "greptile-apps")
    #expect(thread["bot"]?.bool == true)
    #expect(thread["excerpt"]?.string == "This default changes the replica count.")
    #expect(thread["replied"]?.bool != true)
  }

  @Test func threadWhoseLastCommentTheViewerWroteIsRecordedAsReplied() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, details: [FakeGitHub.FakeThread(comments: 2, viewerWroteLast: true)])

    let (sbd, s) = try ready(github)

    let threads = try #require(try sbd.recordedMergeDetails(s.id)?["threadDetails"]?.array)
    #expect(threads.first?["replied"]?.bool == true)
  }

  @Test func nudgeReadRecordsNoThreadDetails() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    github.reviewThreads(MergeTests.number, resolved: [false])
    let sbd = try Instance.withMergeStub(github)
    let s = try MergeTests().readySession(sbd)

    let details = try #require(try sbd.recordedMergeDetails(s.id))

    #expect(details["openThreads"]?.int == 1)
    #expect(details["threadDetails"] == nil)
  }

  @Test func reviewDetailsRecordTheBodyAndTheCommitsSinceEachReview() throws {
    let github = try FakeGitHub()
    let head = MergeTests().head(github)
    github.commits(MergeTests.number, oids: [Self.earlier, Self.middle, head])
    github.reviews(
      MergeTests.number,
      [
        FakeGitHub.FakeReview(
          author: "stamphog", body: "Looks good.", commit: head,
          notes: [(path: "charts/posthog/values.yaml", line: 30, body: "Nit: a comment here.")]),
        FakeGitHub.FakeReview(author: "mariusandra", body: "Ship it.", commit: Self.earlier, reviewId: 3_400_000_101),
      ])

    let (sbd, s) = try ready(github)

    let reviews = try #require(try sbd.recordedMergeDetails(s.id)?["reviews"]?.array)
    let byAuthor = Dictionary(uniqueKeysWithValues: reviews.compactMap { r in r["author"]?.string.map { ($0, r) } })
    #expect(byAuthor["stamphog"]?["commitsSince"]?.int == 0)
    #expect(byAuthor["mariusandra"]?["commitsSince"]?.int == 2)
    #expect(byAuthor["stamphog"]?["body"]?.string == "Looks good.")
    #expect(byAuthor["stamphog"]?["noteCount"]?.int == 1)
    #expect(byAuthor["stamphog"]?["notes"]?.array?.first?["path"]?.string == "charts/posthog/values.yaml")
  }

  // MARK: The panel on the card

  static let threadPath = "charts/posthog/values.yaml"

  /// MergeSummaryTests.body without its test plan gaps.
  static let greenBody = """
    ## Problem

    - When a flag targets a dynamic cohort, the result depends on child order.

    ## Changes

    - A sibling now decides the result in either order.

    ## How did you test this code?

    New cases cover both orders.

    - [x] Tested by hand
    """

  /// stamphog's approval two commits before the head, with a body and one
  /// inline comment, an open thread that a bot started, and test plan gaps.
  func needsALook(_ github: FakeGitHub) {
    let head = MergeTests().head(github)
    github.commits(MergeTests.number, oids: [Self.earlier, Self.middle, head])
    github.reviews(
      MergeTests.number,
      [
        FakeGitHub.FakeReview(
          author: "stamphog", body: "Looks good apart from one nit.", commit: Self.earlier,
          notes: [(path: Self.threadPath, line: 30, body: "Nit: name this value.")])
      ])
    github.reviewThreads(
      MergeTests.number,
      details: [
        FakeGitHub.FakeThread(
          path: Self.threadPath, line: 30, author: "greptile-apps[bot]",
          body: "This default\nchanges the replica count.")
      ])
    github.change(MergeTests.number) { $0["body"] = .string(MergeSummaryTests.body) }
  }

  /// The session's Inbox item as `sb get --json` prints it under `triage.message`.
  func cardMessage(_ sbd: Instance, _ id: String) throws -> JSON {
    try #require(try sbd.getJSON(id)["triage"]?["message"])
  }

  @Test func amberRowsShowOnTheItemAndDemoteTheMergeOption() throws {
    let github = try FakeGitHub()
    needsALook(github)

    let (sbd, s) = try ready(github)

    let message = try cardMessage(sbd, s.id)
    let review = try #require(message["review"])
    #expect(review["amber"] == ["approval", "threads", "testPlan"])
    let thread = try #require(review["threads"]?["shown"]?.array?.first)
    #expect(thread["path"]?.string == Self.threadPath)
    #expect(thread["line"]?.int == 30)
    #expect(thread["bot"]?.bool == true)
    #expect(thread["excerpt"]?.string == "This default changes the replica count.")
    let approval = try #require(review["approvals"]?.array?.first)
    #expect(approval["author"]?.string == "stamphog")
    #expect(approval["commitsSince"]?.int == 2)
    #expect(approval["body"]?.string == "Looks good apart from one nit.")
    #expect(approval["notes"]?.array?.count == 1)
    #expect(message["action"]?["options"]?.array?.first?["label"]?.string == "Merge #18303 anyway")
    #expect(message["action"]?["primary"] == .null)
  }

  @Test func theReplacedCalloutsAreGoneFromTheItem() throws {
    let github = try FakeGitHub()
    needsALook(github)

    let (sbd, s) = try ready(github)

    #expect(try cardMessage(sbd, s.id)["summary"]?["callouts"]?.array?.isEmpty == true)
  }

  /// `Verdict ==` compares only the state and the reason, and the reason
  /// stays "approved by stamphog" across both polls. A review that such a
  /// comparison kept from the first poll would leave the rows amber.
  @Test func resolvingTheThreadApprovingTheHeadAndClearingTheGapTurnsEveryRowGreen() throws {
    let github = try FakeGitHub()
    needsALook(github)
    let (sbd, s) = try ready(github)
    let before = try sbd.getJSON(s.id)
    try #require(before["triage"]?["message"]?["review"]?["amber"]?.array?.isEmpty == false)

    github.reviewThreads(
      MergeTests.number,
      details: [
        FakeGitHub.FakeThread(resolved: true, path: Self.threadPath, line: 30, author: "greptile-apps[bot]")
      ])
    github.reviews(
      MergeTests.number,
      [FakeGitHub.FakeReview(author: "stamphog", body: "Looks good.", commit: MergeTests().head(github))])
    github.change(MergeTests.number) { $0["body"] = .string(Self.greenBody) }
    try pollAgain(sbd)

    let after = try sbd.getJSON(s.id)
    #expect(after["reason"] == before["reason"])
    let message = try #require(after["triage"]?["message"])
    #expect(message["review"]?["amber"] == [])
    #expect(message["action"]?["options"]?.array?.first?["label"]?.string == "Merge #18303")
    #expect(message["action"]?["primary"]?.int == 0)
  }

  @Test func sbTriagePrintsABeforeYouMergeBlockWithAnAmberLinePerAmberRow() throws {
    let github = try FakeGitHub()
    needsALook(github)
    let (sbd, _) = try ready(github)

    let text = try sbd.sb("triage")

    #expect(text.contains("Before you merge"), "\(text)")
    let lines = text.split(separator: "\n")
    #expect(lines.filter { $0.contains("[amber]") }.count == 3, "\(text)")
    #expect(!lines.contains { $0.contains("[ok]") }, "\(text)")
  }

  /// Green rows that the panel shows are the approval and the threads. The
  /// reviewers and test plan rows hide when green.
  @Test func sbTriageMarksTheShownGreenRowsOk() throws {
    let github = try FakeGitHub()
    github.change(MergeTests.number) { $0["body"] = .string(Self.greenBody) }
    let (sbd, s) = try ready(github)
    try #require(try cardMessage(sbd, s.id)["review"]?["amber"] == [])

    let text = try sbd.sb("triage")

    #expect(text.contains("Before you merge"), "\(text)")
    let lines = text.split(separator: "\n")
    #expect(lines.filter { $0.contains("[ok]") }.count == 2, "\(text)")
    #expect(!lines.contains { $0.contains("[amber]") }, "\(text)")
  }

  /// The session wrote its own card with `sb summary set`, so its draft
  /// reply resolves through gh and the Ready to merge rule adds the panel.
  @Test func aSessionCardsDraftThatAnswersAShownThreadShowsItsNumberOnTheThread() throws {
    let github = try FakeGitHub()
    let root: Int64 = 2_512_345_678
    github.reviewThreads(MergeTests.number, details: [FakeGitHub.FakeThread(discussionId: root)])
    let sbd = try Instance.withReplyStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/comments/\(root)", json: reviewCommentJSON(root))
    let s = try MergeTests().readySession(sbd)

    try sbd.setSummary(s.id, replyCard("https://github.com/PostHog/charts/pull/18303#discussion_r\(root)"))
    try sbd.waitForPost(s.id, "ready")

    let message = try cardMessage(sbd, s.id)
    let thread = try #require(message["review"]?["threads"]?["shown"]?.array?.first)
    #expect(thread["drafts"] == [1])
    #expect(message["summary"]?["drafts"]?.array?.map { $0["number"]?.int } == [1])
  }

  @Test func aSessionCardsDraftForAnotherCommentStaysOffTheThread() throws {
    let github = try FakeGitHub()
    github.reviewThreads(MergeTests.number, details: [FakeGitHub.FakeThread(discussionId: 2_512_345_678)])
    let sbd = try Instance.withReplyStub(github)
    try sbd.restart(setting: "triage", to: ["systemPrompt": "", "enabled": false])
    try sbd.ghRoute("GET", "repos/PostHog/charts/pulls/comments/1001", json: reviewCommentJSON(1001))
    let s = try MergeTests().readySession(sbd)

    try sbd.setSummary(s.id, replyCard("https://github.com/PostHog/charts/pull/18303#discussion_r1001"))
    try sbd.waitForPost(s.id, "ready")

    let thread = try #require(try cardMessage(sbd, s.id)["review"]?["threads"]?["shown"]?.array?.first)
    #expect(thread["drafts"] == [])
  }
}
