import Foundation
import Testing

@testable import SwitchboardCore

private let start: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let hour: Int64 = 60 * minute

private func read(_ trigger: ReadTrigger, _ owner: String) -> GitHubUsage.Read {
  GitHubUsage.Read(trigger: trigger, owner: owner)
}

@Suite struct GitHubUsageTests {
  // MARK: Sharing

  @Test func aNewUsageHasNoRequestsPointsOrReads() {
    let usage = GitHubUsage(since: start)

    #expect(usage.requests == 0)
    #expect(usage.points == 0)
    #expect(usage.reads.isEmpty)
  }

  @Test(arguments: ReadTrigger.allCases)
  func aRequestForOnePRCountsInItsTriggerAndOwner(_ trigger: ReadTrigger) {
    var usage = GitHubUsage(since: start)

    usage.share(requests: 1, points: 2, among: [read(trigger, "haacked")], countsReads: true)

    #expect(usage.reads == [trigger: ["haacked": GitHubUsage.Share(reads: 1, requests: 1, points: 2)]])
  }

  @Test func aRequestForSeveralPRsSharesItsCostEvenly() {
    var usage = GitHubUsage(since: start)

    usage.share(
      requests: 1, points: 4,
      among: [
        read(.idle, "haacked"), read(.idle, "posthog"), read(.pending, "haacked"),
        read(.pending, "haacked"),
      ], countsReads: true)

    #expect(usage.reads[.idle]?["haacked"] == GitHubUsage.Share(reads: 1, requests: 0.25, points: 1))
    #expect(usage.reads[.idle]?["posthog"] == GitHubUsage.Share(reads: 1, requests: 0.25, points: 1))
    #expect(usage.reads[.pending]?["haacked"] == GitHubUsage.Share(reads: 2, requests: 0.5, points: 2))
  }

  /// The shares of a request add back up to the request, so no request is lost or counted twice.
  @Test(arguments: [1, 2, 3, 7, 20])
  func theSharesOfARequestAddUpToTheRequest(_ prs: Int) {
    var usage = GitHubUsage(since: start)
    let owners = ["haacked", "posthog", "unknown"]
    let served = (0..<prs).map { read(ReadTrigger.allCases[$0 % ReadTrigger.allCases.count], owners[$0 % 3]) }

    usage.share(requests: 1, points: 3, among: served, countsReads: true)

    let shares = usage.reads.values.flatMap(\.values)
    #expect(abs(shares.map(\.requests).reduce(0, +) - 1) < 1e-9)
    #expect(abs(shares.map(\.points).reduce(0, +) - 3) < 1e-9)
    #expect(shares.map(\.reads).reduce(0, +) == prs)
  }

  @Test func sharingTwiceAddsToTheShare() {
    var usage = GitHubUsage(since: start)

    usage.share(requests: 1, points: 1, among: [read(.poll, "haacked")], countsReads: true)
    usage.share(requests: 1, points: 2, among: [read(.poll, "haacked")], countsReads: true)

    #expect(usage.reads[.poll]?["haacked"] == GitHubUsage.Share(reads: 2, requests: 2, points: 3))
  }

  /// A follow-up request, such as the comment bodies of a PR that a status request read, costs but reads no PR.
  @Test func aFollowUpRequestAddsCostButNoRead() {
    var usage = GitHubUsage(since: start)
    usage.share(requests: 1, points: 1, among: [read(.wait, "posthog")], countsReads: true)

    usage.share(requests: 1, points: 1, among: [read(.wait, "posthog")], countsReads: false)

    #expect(usage.reads[.wait]?["posthog"] == GitHubUsage.Share(reads: 1, requests: 2, points: 2))
  }

  @Test func aRequestThatServedNoPRChangesNoShare() {
    var usage = GitHubUsage(since: start)

    usage.share(requests: 1, points: 1, among: [], countsReads: true)

    #expect(usage.reads.isEmpty)
  }

  /// `send` and `request` count the totals. A share only splits them among the PR reads.
  @Test func sharingLeavesTheTotalsAlone() {
    var usage = GitHubUsage(since: start)
    usage.requests = 5
    usage.points = 7

    usage.share(requests: 1, points: 1, among: [read(.first, "haacked")], countsReads: true)

    #expect(usage.requests == 5)
    #expect(usage.points == 7)
  }

  // MARK: Report

  @Test func theReportGivesTheTimeSinceCountingStarted() {
    let usage = GitHubUsage(since: start)

    let report = usage.report(now: start + 90 * minute)

    #expect(report.since == start)
    #expect(report.hours == 1.5)
  }

  @Test(arguments: [
    // 30 requests and 12 points over 30 minutes.
    (30 * minute, 30, 12, 60.0, 24.0),
    // Fractional rates catch integer division.
    (2 * hour, 3, 5, 1.5, 2.5),
    (hour, 1, 0, 1.0, 0.0),
    (48 * hour, 96, 24, 2.0, 0.5),
  ])
  func theReportGivesTheTotalsAndTheirRatesAnHour(
    _ elapsed: Int64, _ requests: Int, _ points: Int, _ requestsPerHour: Double, _ pointsPerHour: Double
  ) {
    var usage = GitHubUsage(since: start)
    usage.requests = requests
    usage.points = points

    let report = usage.report(now: start + elapsed)

    #expect(report.requests == requests)
    #expect(report.points == points)
    #expect(report.requestsPerHour == requestsPerHour)
    #expect(report.pointsPerHour == pointsPerHour)
  }

  @Test func theReportGivesEachReadsShareAndItsRatesAnHour() {
    var usage = GitHubUsage(since: start)
    usage.share(requests: 3, points: 5, among: [read(.pending, "posthog")], countsReads: true)

    let report = usage.report(now: start + 2 * hour)

    #expect(
      report.reads["pending"]?["posthog"]
        == GitHubUsage.Report.Rates(reads: 1, requests: 3, points: 5, requestsPerHour: 1.5, pointsPerHour: 2.5))
  }

  @Test func theReportKeysTheReadsByTheTriggersName() {
    var usage = GitHubUsage(since: start)
    for trigger in ReadTrigger.allCases {
      usage.share(requests: 1, points: 1, among: [read(trigger, "haacked")], countsReads: true)
    }

    let report = usage.report(now: start + hour)

    #expect(Set(report.reads.keys) == Set(ReadTrigger.allCases.map(\.rawValue)))
  }

  @Test func theReportListsOnlyTheTriggersAndOwnersThatHadReads() {
    var usage = GitHubUsage(since: start)
    usage.share(requests: 1, points: 1, among: [read(.idle, "haacked")], countsReads: true)

    let report = usage.report(now: start + hour)

    #expect(Set(report.reads.keys) == ["idle"])
    #expect(report.reads["idle"].map { Set($0.keys) } == ["haacked"])
  }

  @Test func theTriggersHaveTheirDecidedNames() {
    #expect(
      Set(ReadTrigger.allCases.map(\.rawValue)).isSuperset(of: ["poll", "wait", "first", "pending", "idle"]))
  }

  /// A Double division by zero gives inf or NaN, which JSONEncoder refuses.
  @Test(arguments: [Int64(0), -1, -hour])
  func aReportWithNoElapsedTimeEncodesToJSON(_ elapsed: Int64) throws {
    var usage = GitHubUsage(since: start)
    usage.requests = 4
    usage.points = 2
    usage.share(requests: 4, points: 2, among: [read(.poll, "haacked")], countsReads: true)

    let data = try JSONEncoder().encode(usage.report(now: start + elapsed))

    #expect(!data.isEmpty)
  }

  @Test(arguments: [Int64(0), -1, -hour])
  func aReportWithNoElapsedTimeGivesZeroHoursAndRates(_ elapsed: Int64) {
    var usage = GitHubUsage(since: start)
    usage.requests = 4
    usage.points = 2
    usage.share(requests: 4, points: 2, among: [read(.poll, "haacked")], countsReads: true)

    let report = usage.report(now: start + elapsed)

    #expect(report.hours == 0)
    #expect(report.requestsPerHour == 0)
    #expect(report.pointsPerHour == 0)
    #expect(report.reads["poll"]?["haacked"]?.requestsPerHour == 0)
    #expect(report.reads["poll"]?["haacked"]?.pointsPerHour == 0)
  }

  @Test(arguments: [Int64(0), -1, -hour])
  func aReportWithNoElapsedTimeKeepsTheCounts(_ elapsed: Int64) {
    var usage = GitHubUsage(since: start)
    usage.requests = 4
    usage.points = 2
    usage.share(requests: 4, points: 2, among: [read(.poll, "haacked")], countsReads: true)

    let report = usage.report(now: start + elapsed)

    #expect(report.requests == 4)
    #expect(report.points == 2)
    #expect(report.reads["poll"]?["haacked"]?.requests == 4)
  }
}

/// Why the poller reads a PR, which decides the trigger of its share.
@Suite struct ReadTriggerTests {
  static let now: Int64 = 1_000_000_000
  static let pendingMs: Int64 = 30_000
  static let idleMs: Int64 = 300_000

  static let pending = samplePR(checks: "PENDING")
  static let awaitingReview = samplePR(reviewDecision: .reviewRequired, checks: "SUCCESS", reviewDecisionRead: true)
  static let settled = samplePR(reviewDecision: .approved, checks: "SUCCESS", reviewDecisionRead: true)

  func trigger(
    _ pr: PullRequest?, polledAgo: Int64?, waitedAgo: Int64? = nil, all: Bool = false, pendingRate: Bool = false
  ) -> ReadTrigger? {
    GitHub.readTrigger(
      pr, lastPolled: polledAgo.map { Self.now - $0 }, waitedAt: waitedAgo.map { Self.now - $0 }, all: all,
      pendingRate: pendingRate, now: Self.now, pendingMs: Self.pendingMs, idleMs: Self.idleMs)
  }

  @Test(
    arguments: [
      (nil, nil), (ReadTriggerTests.settled, 0), (ReadTriggerTests.pending, 0),
      (ReadTriggerTests.settled, ReadTriggerTests.idleMs),
    ] as [(PullRequest?, Int64?)])
  func sbPollAllReadsEveryPRAsPoll(_ pr: PullRequest?, _ polledAgo: Int64?) {
    #expect(trigger(pr, polledAgo: polledAgo, all: true) == .poll)
  }

  @Test func sbPollAllWinsOverANewerWait() {
    #expect(trigger(Self.settled, polledAgo: 10, waitedAgo: 5, all: true) == .poll)
  }

  @Test(arguments: [ReadTriggerTests.settled, ReadTriggerTests.pending, ReadTriggerTests.awaitingReview])
  func aWaitNewerThanTheLastReadReadsThePRAsWait(_ pr: PullRequest) {
    #expect(trigger(pr, polledAgo: 10, waitedAgo: 5) == .wait)
  }

  @Test func aWaitOnAPRThatWasNeverReadReadsItAsWait() {
    #expect(trigger(nil, polledAgo: nil, waitedAgo: 5) == .wait)
  }

  @Test(arguments: [Int64(10), 11, 1_000])
  func aWaitNoNewerThanTheLastReadReadsNothingWhileThePRIsNotDue(_ waitedAgo: Int64) {
    #expect(trigger(Self.settled, polledAgo: 10, waitedAgo: waitedAgo) == nil)
  }

  @Test func aPRThatWasNeverReadReadsAsFirst() {
    #expect(trigger(nil, polledAgo: nil) == .first)
  }

  @Test(arguments: [ReadTriggerTests.pending, ReadTriggerTests.awaitingReview])
  func aPendingPRReadsAsPendingOnceThePendingIntervalPasses(_ pr: PullRequest) {
    #expect(trigger(pr, polledAgo: Self.pendingMs - 1) == nil)
    #expect(trigger(pr, polledAgo: Self.pendingMs) == .pending)
  }

  /// A wait that needs its PR read at the pending rate, or Trunk's queue, sets `pendingRate`.
  @Test func aSettledPRAtThePendingRateReadsAsPendingOnceThePendingIntervalPasses() {
    #expect(trigger(Self.settled, polledAgo: Self.pendingMs - 1, pendingRate: true) == nil)
    #expect(trigger(Self.settled, polledAgo: Self.pendingMs, pendingRate: true) == .pending)
  }

  @Test func aSettledPRReadsAsIdleOnceTheIdleIntervalPasses() {
    #expect(trigger(Self.settled, polledAgo: Self.idleMs - 1) == nil)
    #expect(trigger(Self.settled, polledAgo: Self.idleMs) == .idle)
  }

  @Test(arguments: [Int64(0), ReadTriggerTests.pendingMs, ReadTriggerTests.idleMs - 1])
  func aSettledPRBeforeTheIdleIntervalReadsNothing(_ polledAgo: Int64) {
    #expect(trigger(Self.settled, polledAgo: polledAgo) == nil)
  }

  /// The trigger reads a PR exactly when `all`, a newer wait, or the PR's interval says to. The expected value
  /// states the rule without `readTrigger`, so the test fails when `readTrigger` departs from it.
  @Test(
    arguments: [nil, ReadTriggerTests.pending, ReadTriggerTests.awaitingReview, ReadTriggerTests.settled]
      as [PullRequest?],
    [
      nil, 0, 1, ReadTriggerTests.pendingMs - 1, ReadTriggerTests.pendingMs, ReadTriggerTests.idleMs - 1,
      ReadTriggerTests.idleMs,
    ] as [Int64?])
  func theTriggerReadsExactlyThePRsThatAreDue(_ pr: PullRequest?, _ polledAgo: Int64?) {
    let lastPolled = polledAgo.map { Self.now - $0 }
    for all in [false, true] {
      for pendingRate in [false, true] {
        for waitedAgo in [nil, 0, 5, 10_000_000] as [Int64?] {
          let idleMs = pendingRate ? Self.pendingMs : Self.idleMs
          let due =
            pr.map {
              GitHub.elapsed(
                since: lastPolled, $0.isPending || $0.awaitsReview ? Self.pendingMs : idleMs, now: Self.now)
            } ?? true
          let read = all || (waitedAgo.map { Self.now - $0 } ?? 0) > (lastPolled ?? 0) || due

          #expect(
            (trigger(pr, polledAgo: polledAgo, waitedAgo: waitedAgo, all: all, pendingRate: pendingRate) != nil)
              == read, "all \(all), pendingRate \(pendingRate), waitedAgo \(String(describing: waitedAgo))")
        }
      }
    }
  }
}
