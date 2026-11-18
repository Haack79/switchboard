import Foundation
import SwitchboardCore
import Testing

/// A PR-kind wait's `wait-resolved` event records, as `changedAt` in ms, the
/// GitHub time of the change that resolved it when sbd knows one.
@Suite(.blocking(timeLimit: .seconds(120))) struct WaitResolvedAtTests {
  /// A session on the branch of PostHog/charts#18303, whose PR the poller has read.
  func chartsSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: PollerWaitTests.charts, branch: PollerWaitTests.branch)
    try sbd.poll()
    return s
  }

  /// The ms of a GitHub timestamp, which `stamp` writes in whole seconds.
  func ms(_ timestamp: String) throws -> Double {
    let date = try #require(ISO8601DateFormatter().date(from: timestamp))
    return (date.timeIntervalSince1970 * 1000).rounded()
  }

  func resolvedEvent(_ sbd: Instance, _ s: SessionSummary) throws -> Event {
    try #require(try sbd.events(s.id).last { $0.kind == "wait-resolved" })
  }

  @Test func aMergeWaitOnTheSessionsPRRecordsWhenThePRMerged() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "merge")
    let mergedAt = stamp(60)
    github.change(18303) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = .string(mergedAt)
    }

    try sbd.poll()

    try resumed(sbd, s, with: "the session's PR to merge: it merged.")
    #expect(try resolvedEvent(sbd, s).data["changedAt"]?.double == (try ms(mergedAt)))
  }

  /// PostHog/posthog#122179 merged weeks before the test runs, so the time
  /// can't be the time that sbd resolved the wait.
  @Test func aMergeWaitOnAnotherPRRecordsWhenThatPRMerged() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: PollerWaitTests.posthog, branch: PollerWaitTests.posthogBranch)
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "#122179")

    try sbd.poll()

    try resumed(sbd, s, with: "#122179 to merge: it merged.")
    // 2026-10-23T21:57:32Z
    #expect(try resolvedEvent(sbd, s).data["changedAt"]?.double == 1_792_792_652_000)
  }

  @Test func aReviewWaitRecordsWhenTheReviewerSubmittedTheReview() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    try sbd.sb("wait", s.id, "--kind", "review", "--who", "alex")
    github.review(18303, by: "sam", "APPROVED", at: stamp(30))
    let submittedAt = stamp(60)
    github.review(18303, by: "alex", "CHANGES_REQUESTED", at: submittedAt)

    try sbd.poll()

    try resumed(sbd, s, with: "a review from alex on the session's PR: alex requested changes.")
    #expect(try resolvedEvent(sbd, s).data["changedAt"]?.double == (try ms(submittedAt)))
  }

  /// The checks rollup carries no time, so sbd knows none for a `ci` wait.
  @Test func aCIWaitRecordsNoGitHubTime() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try chartsSession(sbd)
    github.checks(18303, "PENDING")
    try sbd.sb("wait", s.id, "--kind", "ci")
    github.checks(18303, "SUCCESS")
    try sbd.poll()

    try sbd.poll()

    try resumed(sbd, s, with: "CI on the session's PR: the checks passed.")
    #expect(try resolvedEvent(sbd, s).data["changedAt"] == nil)
  }
}
