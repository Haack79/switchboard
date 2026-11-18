import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A service with a GitHub poller whose timer is off, so only the test runs polls.
final class PollerHarness {
  let home: Home
  let service: Service
  let poller: GitHubPoller

  init() throws {
    home = Home(path: try makeShortTempFolder())
    let gh = "\(home.path)/gh"
    try "#!/bin/sh\necho token\n".write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    let config: JSON = [
      "claude": "/usr/bin/false", "github": ["gh": .string(gh), "url": "http://127.0.0.1:9", "pollSeconds": 0],
      "depot": ["enabled": false], "trunk": ["path": .string("\(home.path)/trunk")],
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    service = try Service(home: home, sbPath: "/usr/bin/true")
    poller = GitHubPoller(
      service: service, settings: service.config.github, depot: service.config.depot, trunk: service.config.trunk)
    service.github = poller
  }

  deinit { try? FileManager.default.removeItem(atPath: home.path) }
}

func cachePR(base: String = "main", mergedBase: Int? = nil) -> PullRequest {
  PullRequest(
    id: "PR_7", number: 7, url: "https://github.com/acme/widgets/pull/7", repo: "acme/widgets", headSha: "head1",
    base: base, mergedBase: mergedBase)
}

/// What a status read that `store` caches keeps from the PR's last read.
@Suite struct GitHubPollerCacheTests {
  static let run = DepotRun(id: "run-1", headSha: "head1", status: "running")

  @Test func aReadKeepsTheMergedBaseWhileTheBaseStaysTheSame() throws {
    let h = try PollerHarness()
    h.poller.store(cachePR(base: "stack-1", mergedBase: 3), comments: [], polled: 1)
    h.poller.store(cachePR(base: "stack-1"), comments: [], polled: 2)
    #expect(h.poller.prs["PR_7"]?.pr.mergedBase == 3)
    #expect(h.poller.prs["PR_7"]?.polled == 2)
  }

  @Test func aReadOfANewBaseDropsTheMergedBase() throws {
    let h = try PollerHarness()
    h.poller.store(cachePR(base: "stack-1", mergedBase: 3), comments: [], polled: 1)
    h.poller.store(cachePR(base: "main"), comments: [], polled: 2)
    #expect(h.poller.prs["PR_7"]?.pr.mergedBase == nil)
  }

  /// Only the Depot poller sets a PR's run, so a status read keeps the cached one.
  @Test func aReadKeepsTheDepotRun() throws {
    let h = try PollerHarness()
    h.poller.store(cachePR(), comments: [], polled: 1)
    h.poller.prs["PR_7"]?.pr.depot = Self.run
    h.poller.store(cachePR(), comments: [], polled: 2)
    #expect(h.poller.prs["PR_7"]?.pr.depot == Self.run)
  }

  @Test func aReadKeepsTheFactTime() throws {
    let h = try PollerHarness()
    h.poller.store(cachePR(), comments: [], polled: 1)
    h.poller.prs["PR_7"]?.factAt = 5
    h.poller.store(cachePR(), comments: [], polled: 2)
    #expect(h.poller.prs["PR_7"]?.factAt == 5)
  }

  @Test func theFirstReadHasNoFactTime() throws {
    let h = try PollerHarness()
    h.poller.store(cachePR(), comments: [], polled: 1)
    #expect(h.poller.prs["PR_7"]?.factAt == nil)
  }
}
