import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

// These tests never move `Clock`, because it is global to the test process. An acknowledgment expires here because
// its time is set further back than `acknowledgedMs`.

private let sessionId = "s1"
private let repo = "acme/widgets"

/// A `Service` in a temporary home that never loads, with a GitHub poller that never polls, so nothing empties the
/// poller's `recheck` set but the test.
private final class AckHarness {
  let home: Home
  let service: Service
  let poller: GitHubPoller

  init() throws {
    home = Home(path: try makeShortTempFolder())
    let config: JSON = [
      "claude": "/usr/bin/false", "tmux": "/usr/bin/true",
      "github": ["gh": "/usr/bin/false", "url": "http://127.0.0.1:9", "pollSeconds": 0],
      "depot": ["enabled": false], "trunk": ["path": .string("\(home.path)/trunk")],
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    service = try Service(home: home, sbPath: "/usr/bin/true")
    poller = GitHubPoller(
      service: service, settings: service.config.github, depot: service.config.depot, trunk: service.config.trunk)
    service.github = poller
  }

  deinit { try? FileManager.default.removeItem(atPath: home.path) }

  var acknowledgedMs: Int64 { service.config.recheck.acknowledgedMs }

  /// A session whose turn ended and whose PR conflicts with main, so the conflict rule raises an Inbox item.
  func addSessionWithAConflict(_ pr: PullRequest = conflictingPR()) throws {
    let cwd = "\(home.path)/work/\(sessionId)"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    var s = Session(id: sessionId, name: "widgets", cwd: cwd, claudeSessionId: "c-\(sessionId)", created: 5)
    s.started = true
    try service.store.save(s)
    service.queue.sync { service.entries[sessionId] = Service.Entry(session: s) }
    record("UserPromptSubmit", ["hook_event_name": "UserPromptSubmit", "prompt": "Open the PR."])
    record("Stop", ["hook_event_name": "Stop", "last_assistant_message": "Opened #42."])
    record("pr", ["pr": try JSON(encoding: pr), "comments": []])
  }

  func record(_ kind: String, _ data: JSON = [:]) {
    service.queue.sync { _ = service.record(sessionId, kind, data) }
  }

  /// The verdict that `evaluate` gives now, before the Acknowledge layer.
  func evaluated() -> Verdict { service.queue.sync { evaluatedOnQueue() } }

  /// The verdict that the app and `sb` show now.
  func shown() -> Verdict { service.queue.sync { service.shown(sessionId, evaluatedOnQueue(), now: nowMs()) } }

  private func evaluatedOnQueue() -> Verdict {
    let e = service.entries[sessionId]!
    return Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: service.lastState)
  }

  /// Records an `ack` of the current item, as the app's Acknowledge does, and moves its time `age` ms back.
  func acknowledge(age: Int64) throws {
    let verdict = evaluated()
    let facts = service.queue.sync { service.entries[sessionId]!.facts }
    record("ack", try JSON(encoding: Acknowledgment(verdict, facts)))
    service.queue.sync { service.entries[sessionId]!.facts.acknowledgment?.at = nowMs() - age }
  }

  /// What a tick does for the session: it tracks the verdict and runs `afterTrack`.
  func tick() {
    service.queue.sync {
      guard var e = service.entries[sessionId] else { return }
      let verdict = Attention.track(e.session, &e.facts, now: nowMs(), stateOf: service.lastState)
      service.entries[sessionId] = e
      service.afterTrack(sessionId, verdict)
    }
  }

  /// The poller's `recheck` set. The poller's queue is serial, so this read runs after every change that sbd sent
  /// to it before.
  var recheck: Set<String> { poller.queue.sync { poller.recheck } }

  /// Empties `recheck`, as a poll that read the PRs does.
  func poll() { poller.queue.sync { poller.recheck = [] } }
}

private func conflictingPR(id: String = "PR_42") -> PullRequest {
  PullRequest(
    id: id, number: 42, url: "https://github.com/\(repo)/pull/42", repo: repo, title: "Count the DLQ lookups",
    head: "haacked/dlq", headSha: "abc123", mergeable: .conflicting, checks: "SUCCESS", author: "haacked")
}

/// When the acknowledgment of a PR rule item expires, sbd puts the PR in the poller's `recheck` set once, so the
/// next poll reads the PR whether or not it is due, and the re-raised item shows GitHub's current state.
@Suite struct AckExpiryRecheckTests {
  @Test func anExpiredAcknowledgmentPutsThePRInRecheck() throws {
    let h = try AckHarness()
    try h.addSessionWithAConflict()
    try #require(h.evaluated().reason.contains("conflicts with main"), "\(h.evaluated().reason)")
    try h.acknowledge(age: h.acknowledgedMs + 60_000)
    try #require(h.shown().reason.contains("time to recheck"), "\(h.shown().reason)")

    h.tick()

    #expect(h.recheck.contains("PR_42"))
  }

  @Test func anAcknowledgmentThatHasNotExpiredLeavesRecheckAlone() throws {
    let h = try AckHarness()
    try h.addSessionWithAConflict()
    try h.acknowledge(age: 0)
    try #require(h.shown().acknowledged)

    h.tick()

    #expect(h.recheck.isEmpty)
  }

  /// A poll empties `recheck`. The same expired acknowledgment does not put the PR back, so the PR returns to its
  /// own poll rate.
  @Test func oneAcknowledgmentPutsThePRInRecheckOnce() throws {
    let h = try AckHarness()
    try h.addSessionWithAConflict()
    try h.acknowledge(age: h.acknowledgedMs + 60_000)
    h.tick()
    try #require(h.recheck.contains("PR_42"))
    h.poll()

    h.tick()
    h.tick()

    #expect(h.recheck.isEmpty)
  }

  @Test func aLaterAcknowledgmentThatExpiresPutsThePRInRecheckAgain() throws {
    let h = try AckHarness()
    try h.addSessionWithAConflict()
    try h.acknowledge(age: h.acknowledgedMs + 120_000)
    h.tick()
    try #require(h.recheck.contains("PR_42"))
    h.poll()
    try h.acknowledge(age: h.acknowledgedMs + 60_000)
    try #require(h.shown().reason.contains("time to recheck"))

    h.tick()

    #expect(h.recheck.contains("PR_42"))
  }

  /// The PR in `recheck` is the one the expired item is about, by its node id.
  @Test func theRecheckNamesTheSessionsPR() throws {
    let h = try AckHarness()
    try h.addSessionWithAConflict(conflictingPR(id: "PR_kwDOabc"))
    try h.acknowledge(age: h.acknowledgedMs + 60_000)

    h.tick()

    #expect(h.recheck == ["PR_kwDOabc"])
  }
}
