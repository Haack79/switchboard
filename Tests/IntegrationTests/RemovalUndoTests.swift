import Foundation
import SwitchboardCore
import Testing

/// The undo window in these tests. sbd's test clock passes it with one `clock` request, and real time never does
/// within a test, so a removal that starts before the test advances the clock started before its `notBefore`.
private let undoWindowSeconds = 600

/// An sbd whose removal job waits `undoWindowSeconds` before it starts a queued session.
private func undoInstance() throws -> Instance {
  try Instance(idleStopSeconds: 3600, config: ["removalDelaySeconds": .number(Double(undoWindowSeconds))])
}

/// A Done session in its own worktree, and the pid of its claude.
private func doneSession(_ sbd: Instance, _ repo: String, branch: String) throws -> (SessionSummary, Int) {
  let s = try sbd.worktreeSession(repo, branch: branch)
  let claude = try #require(try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }.claudePid)
  try sbd.markSessionDone(s.id)
  return (s, claude)
}

extension Instance {
  /// The `rm-cancel` op with every id in one request.
  fileprivate func cancelRemoval(_ ids: [String]) throws -> JSON {
    try client.call("rm-cancel", ["sessions": .array(ids.map(JSON.string))])
  }

  /// Moves sbd's clock past every `notBefore` that `rm-queue` has set so far.
  fileprivate func passTheUndoWindow() throws { try advanceClock(Int64(undoWindowSeconds + 1) * 1000) }

  /// Waits in real time, then runs a tick, so a worker that ignored `notBefore` has had time to start.
  fileprivate func giveTheWorkerTime() throws {
    sleep(2)
    try advanceClock(1)
  }
}

/// The ids in an `rm-cancel` result's `cancelled`.
private func cancelled(_ result: JSON) -> [String] { result["cancelled"]?.array?.compactMap(\.string) ?? [] }

/// The `refused` entries of an `rm-cancel` result, by id.
private func refusals(_ result: JSON) -> [String: JSON] {
  Dictionary(
    (result["refused"]?.array ?? []).compactMap { r in r["id"]?.string.map { ($0, r) } },
    uniquingKeysWith: { a, _ in a })
}

extension RemovalJobTests {
  // MARK: Undo window

  /// sbd reads a null `removalDelaySeconds` as absent, so the window is the default 5 s. Both times come from sbd's clock.
  @Test func rmQueueSetsNotBeforeFiveSecondsAfterTheRequestByDefault() throws {
    let sbd = try Instance(config: ["removalDelaySeconds": .null])
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)

    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let removal = try #require(
      listed.first { $0["id"]?.string == a.id }?["removal"], Comment(rawValue: listed.description))
    let requested = try #require(removal["requested"]?.int, Comment(rawValue: removal.text))
    let notBefore = try #require(removal["notBefore"]?.int, Comment(rawValue: removal.text))
    #expect((5_000...5_250).contains(notBefore - requested), "notBefore - requested = \(notBefore - requested) ms")
  }

  @Test func rmQueueSetsNotBeforeTheConfiguredDelayAfterTheRequest() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)

    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    let removal = try #require(try sbd.removal(a.id))
    let requested = try #require(removal["requested"]?.int, Comment(rawValue: removal.text))
    let notBefore = try #require(removal["notBefore"]?.int, Comment(rawValue: removal.text))
    let window = undoWindowSeconds * 1000
    #expect(
      (window...window + 250).contains(notBefore - requested), "notBefore - requested = \(notBefore - requested) ms")
  }

  /// The worker sleeps until `notBefore` in real time when no test moves the clock.
  @Test func aQueuedRemovalStartsOnItsOwnOnceItsNotBeforePasses() throws {
    let sbd = try Instance(config: ["removalDelaySeconds": 2])
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)

    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    try sbd.waitUntilGone(a.id, timeout: 30)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
  }

  @Test func aQueuedRemovalDoesNotStartBeforeItsNotBefore() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let (a, claude) = try doneSession(sbd, repo, branch: "haacked/a")
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    try sbd.giveTheWorkerTime()

    #expect(try sbd.removalState(a.id) == "queued")
    #expect(try sbd.intact(a))
    #expect(try sbd.localBranch(repo, "haacked/a"))
    #expect(Processes.exists(claude), "the worker ended a's claude")
    #expect(try sbd.get(a.id).live)
  }

  /// The test clock moves past `notBefore` while real time does not, so the worker must wake when the clock moves.
  @Test func aQueuedRemovalRunsOnceTheClockPassesItsNotBefore() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])
    try sbd.giveTheWorkerTime()
    try #require(try sbd.removalState(a.id) == "queued")

    try sbd.passTheUndoWindow()

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
  }

  /// `resumeRemovals` starts the worker on its own path after a restart. The restart resets the test clock, so the
  /// stored `notBefore` is still ahead.
  @Test func aQueuedRemovalStillWaitsForItsNotBeforeAfterARestart() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])

    sbd.killSbd()
    try sbd.startSbd()
    try sbd.giveTheWorkerTime()

    #expect(try sbd.removalState(a.id) == "queued")
    #expect(try sbd.intact(a))
    try sbd.passTheUndoWindow()
    try sbd.waitUntilGone(a.id)
  }

  // MARK: rm-cancel

  /// Nothing stopped yet, so each session is as it was: Done, its claude running, its worktree and branch in place.
  @Test func rmCancelBeforeNotBeforeClearsEachRemovalAndClaudeIsNeverSignaled() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let (a, claudeA) = try doneSession(sbd, repo, branch: "haacked/a")
    let (b, claudeB) = try doneSession(sbd, repo, branch: "haacked/b")
    #expect(queued(try sbd.queueRemoval([a.id, b.id])) == [a.id, b.id])

    let result = try sbd.cancelRemoval([a.id, b.id])

    #expect(Set(cancelled(result)) == [a.id, b.id], Comment(rawValue: result.text))
    #expect(refusals(result).isEmpty, Comment(rawValue: result.text))
    for (s, claude, branch) in [(a, claudeA, "haacked/a"), (b, claudeB, "haacked/b")] {
      #expect(try sbd.removal(s.id) == nil, "\(s.id)")
      #expect(try sbd.get(s.id).state == .done, "\(s.id)")
      #expect(try sbd.intact(s), "\(s.id)")
      #expect(try sbd.localBranch(repo, branch), "\(s.id)")
      #expect(Processes.exists(claude), "sbd ended \(s.id)'s claude")
      #expect(try sbd.get(s.id).live, "\(s.id)")
    }
  }

  /// The worker sleeps until a's `notBefore`, the earliest. Once a is cancelled, it must wake for b's, and a stale
  /// timer or copy of a's removal must not delete a. The worker takes sessions in order, so a would go before b.
  @Test func cancellingTheRemovalTheWorkerWaitsForLeavesItAndTheNextOneStillRuns() throws {
    let sbd = try undoInstance()
    let repo = try sbd.repoWithOrigin()
    let (a, claude) = try doneSession(sbd, repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try sbd.markSessionDone(b.id)
    #expect(queued(try sbd.queueRemoval([a.id])) == [a.id])
    try sbd.advanceClock(Int64(undoWindowSeconds / 2) * 1000)
    #expect(queued(try sbd.queueRemoval([b.id])) == [b.id])

    #expect(cancelled(try sbd.cancelRemoval([a.id])) == [a.id])
    try sbd.passTheUndoWindow()

    try sbd.waitUntilGone(b.id)
    #expect(try sbd.removal(a.id) == nil)
    #expect(try sbd.intact(a))
    #expect(try sbd.localBranch(repo, "haacked/a"))
    #expect(Processes.exists(claude), "sbd ended a's claude")
  }

  /// One request carries a running, a failed, an unknown, a never-queued, and a queued session, the queued one
  /// last, so a request that stopped at the first refusal would leave it queued. q waits behind r at the gate, so
  /// it is still queued although its `notBefore` passed.
  @Test func rmCancelRefusesRunningFailedAndUnqueuedSessionsAndReportsEachOne() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let failed = try sbd.worktreeSession(repo, branch: "haacked/failed")
    let r = try sbd.worktreeSession(repo, branch: "haacked/running")
    let none = try sbd.worktreeSession(repo, branch: "haacked/none")
    let (q, claude) = try doneSession(sbd, repo, branch: "haacked/queued")
    for s in [failed, r] { try sbd.markSessionDone(s.id) }
    try "x".write(toFile: "\(failed.cwd)/notes.txt", atomically: true, encoding: .utf8)
    #expect(queued(try sbd.queueRemoval([failed.id])) == [failed.id])
    try sbd.waitForRemoval(failed.id, "failed")
    sbd.hold(holdRemoval)
    #expect(queued(try sbd.queueRemoval([r.id, q.id])) == [r.id, q.id])
    try sbd.waitForRemoval(r.id, "running")
    try #require(try sbd.removalState(q.id) == "queued")

    let result = try sbd.cancelRemoval([r.id, failed.id, "nope", none.id, q.id])

    #expect(cancelled(result) == [q.id], Comment(rawValue: result.text))
    let refused = refusals(result)
    #expect(Set(refused.keys) == [r.id, failed.id, "nope", none.id], Comment(rawValue: result.text))
    for s in [r, failed, none] {
      #expect(refused[s.id]?["name"]?.string == s.name, Comment(rawValue: result.text))
    }
    for id in refused.keys {
      #expect(refused[id]?["reason"]?.string?.isEmpty == false, "\(id) has no reason: \(result.text)")
    }
    #expect(try sbd.removalState(r.id) == "running")
    #expect(try sbd.removalState(failed.id) == "failed")
    #expect(try sbd.removal(q.id) == nil)
    #expect(try sbd.removal(none.id) == nil)
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(r.id)
    #expect(try sbd.intact(q))
    #expect(Processes.exists(claude), "sbd ended q's claude")
  }

  @Test func rmCancelWithoutSessionsIsRefused() throws {
    let sbd = try Instance()

    let message = failure(sbd, "rm-cancel", [:])

    #expect(message.contains("sessions"), Comment(rawValue: message))
  }
}
