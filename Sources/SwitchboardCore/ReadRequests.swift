import Foundation

/// The PRs that the GitHub poller reads whether or not they are due. A PR is read either at the next poll, whenever
/// that runs, or from a set time, for which the poller schedules a wake that runs a poll.
///
/// The poller schedules one wake at a time. A timed request for a PR that is already requested keeps the earlier
/// time, and a request at or after the scheduled wake needs no wake of its own. A burst of requests therefore
/// shares one wake and one poll, and a stream of requests can't put a PR's read off.
public struct ReadRequests: Equatable, Sendable {
  /// The PRs that the next poll reads.
  public private(set) var nextPoll: Set<String> = []
  /// The PRs requested from a set time, by id, each with the time from which its read is due, in ms.
  public private(set) var timed: [String: Int64] = [:]
  /// The time of the wake that the poller scheduled, in ms, or nil when none is scheduled.
  public private(set) var wake: Int64?

  public init() {}

  /// Requests a read of each PR at the next poll. It schedules no wake.
  public mutating func readAtNextPoll(_ ids: some Sequence<String>) {
    nextPoll.formUnion(ids)
  }

  /// Requests a read of each PR at `at` or later. Returns `at` when the poller must schedule a wake for it, which is
  /// when no scheduled wake comes at or before `at`. The new wake replaces the scheduled one.
  public mutating func request(_ ids: some Sequence<String>, at: Int64) -> Int64? {
    for id in ids { timed[id] = min(timed[id] ?? at, at) }
    guard at < (wake ?? .max) else { return nil }
    wake = at
    return at
  }

  /// Removes and returns the PRs that a poll at `now` reads. A poll calls it once as it starts.
  public mutating func take(now: Int64) -> Set<String> {
    let ready = nextPoll.union(timed.filter { $0.value <= now }.keys)
    nextPoll = []
    timed = timed.filter { $0.value > now }
    return ready
  }

  /// Records that the scheduled wake fired at `now`, and returns whether a timed request is due. A poll that ran
  /// before the wake can have taken them all, and then the wake runs no poll.
  public mutating func fire(now: Int64) -> Bool {
    wake = nil
    return timed.values.contains { $0 <= now }
  }

  /// The time of a wake for the timed requests that remain, or nil when the scheduled wake comes no later than the
  /// first of them.
  public mutating func rearm() -> Int64? {
    guard let next = timed.values.min(), next < (wake ?? .max) else { return nil }
    wake = next
    return next
  }
}
