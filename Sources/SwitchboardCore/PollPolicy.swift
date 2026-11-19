import Foundation

/// How long a PR waits between two reads.
public struct PollRates: Equatable, Sendable {
  /// The wait while the PR's checks or review are pending, or while a wait or Trunk's queue needs the PR read at
  /// the pending rate.
  public var pendingMs: Int64
  /// The wait otherwise.
  public var idleMs: Int64

  public init(pendingMs: Int64, idleMs: Int64) {
    self.pendingMs = pendingMs
    self.idleMs = idleMs
  }
}

/// The rates at which each PR polls. The argument is the PR's last read, or nil before its first one.
public struct PollPolicy: Sendable {
  public var rates: @Sendable (PullRequest?) -> PollRates

  public init(rates: @escaping @Sendable (PullRequest?) -> PollRates) {
    self.rates = rates
  }

  /// The same rates for every PR.
  public static func uniform(_ rates: PollRates) -> PollPolicy {
    PollPolicy { _ in rates }
  }
}

extension GitHubSettings {
  /// Every PR polls at `pendingMs` and `idleMs`.
  public var pollPolicy: PollPolicy { .uniform(PollRates(pendingMs: pendingMs, idleMs: idleMs)) }
}

/// A PR that a poll may read, with what `GitHub.readTrigger` needs to know about it.
public struct ReadCandidate: Sendable {
  /// The PR's last read, or nil before its first one.
  public var pr: PullRequest?
  public var lastPolled: Int64?
  /// The newest wait, dependency edge, finished turn, or requested read that needs a read after it.
  public var waitedAt: Int64?
  /// Whether the PR polls at the pending rate whatever its state.
  public var pendingRate: Bool

  public init(pr: PullRequest?, lastPolled: Int64?, waitedAt: Int64?, pendingRate: Bool) {
    self.pr = pr
    self.lastPolled = lastPolled
    self.waitedAt = waitedAt
    self.pendingRate = pendingRate
  }
}

extension GitHub {
  /// Why a poll at `now` reads each due PR, by id. A PR that isn't due is left out. Each PR's intervals come from
  /// `policy`.
  public static func dueReads(_ candidates: [String: ReadCandidate], all: Bool, now: Int64, policy: PollPolicy)
    -> [String: ReadTrigger]
  {
    candidates.compactMapValues { c in
      let rates = policy.rates(c.pr)
      return readTrigger(
        c.pr, lastPolled: c.lastPolled, waitedAt: c.waitedAt, all: all, pendingRate: c.pendingRate, now: now,
        pendingMs: rates.pendingMs, idleMs: rates.idleMs)
    }
  }
}
