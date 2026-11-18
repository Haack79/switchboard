import Foundation
import SwitchboardCore
import Testing

/// `sb ls --group` and `--ungrouped` filter the list by the session's group, and combine with `--org` and `--local`.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupFilterCLITests {
  /// Alpha holds a PostHog session and a haacked one, Beta a PostHog one, and a PostHog session is in no group.
  /// Alpha has a chat, and the Manager runs.
  struct Fixture {
    var sbd: Instance
    var alpha: GroupSummary
    var beta: GroupSummary
    /// The fixture's names by session id.
    var names: [String: String]
  }

  private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONCoding.decode(type, from: text)
  }

  /// A session named `gf-<name>`, so the plain list's text never matches a path or an id by accident.
  private func new(_ sbd: Instance, _ path: String, _ name: String) throws -> SessionSummary {
    try decode(SessionSummary.self, try sbd.sb("new", "--json", "--name", "gf-\(name)", path))
  }

  private func ls(_ sbd: Instance, _ args: [String] = []) throws -> [SessionSummary] {
    try decode([SessionSummary].self, try sbd.sb(["ls", "--json"] + args))
  }

  private func fixture(_ repos: Repos) throws -> Fixture {
    let sbd = try Instance()
    let posthog = try repos.make("PostHog/posthog")
    let haacked = try repos.make("haacked/switchboard")
    let a1 = try new(sbd, posthog, "a1")
    let a2 = try new(sbd, haacked, "a2")
    let b1 = try new(sbd, posthog, "b1")
    let u1 = try new(sbd, posthog, "u1")
    let alpha = try decode(GroupSummary.self, try sbd.sb("group", "add", "--json", "Alpha", a1.id, a2.id))
    let beta = try decode(GroupSummary.self, try sbd.sb("group", "add", "--json", "Beta", b1.id))
    let chat = try decode(SessionSummary.self, try sbd.sb("chat", "Alpha", "--json"))
    let manager = try decode(SessionSummary.self, try sbd.sb("manager", "--json"))
    let work = [a1.id, a2.id, b1.id, u1.id]
    _ = try sbd.waitFor("every folder's remotes to be read", fetch: { try ls(sbd) }) { list in
      work.allSatisfy { id in list.first { $0.id == id }?.repositoryRead == true }
    }
    let names = [
      a1.id: "a1", a2.id: "a2", b1.id: "b1", u1.id: "u1", chat.id: "alpha-chat", manager.id: "manager",
    ]
    return Fixture(sbd: sbd, alpha: alpha, beta: beta, names: names)
  }

  /// The fixture's names that `sb ls --json <args>` lists. A session the fixture didn't make, such as the
  /// operator, is left out.
  private func listed(_ f: Fixture, _ args: [String]) throws -> Set<String> {
    Set(try ls(f.sbd, args).compactMap { f.names[$0.id] })
  }

  @Test func lsFiltersByGroupAndUngrouped() throws {
    let repos = try Repos()
    let f = try fixture(repos)
    let cases: [([String], Set<String>)] = [
      (["--group", "Alpha"], ["a1", "a2", "alpha-chat", "manager"]),
      (["--group", f.alpha.id], ["a1", "a2", "alpha-chat", "manager"]),
      (["--group", "Beta"], ["b1", "manager"]),
      (["--ungrouped"], ["u1", "manager"]),
      (["--group", "Alpha", "--ungrouped"], ["a1", "a2", "u1", "alpha-chat", "manager"]),
      (["--group", "Alpha,Beta"], ["a1", "a2", "b1", "alpha-chat", "manager"]),
      (["--group", "Alpha", "--group", "Beta"], ["a1", "a2", "b1", "alpha-chat", "manager"]),
      (["--group", "Alpha", "--org", "posthog"], ["a1", "alpha-chat", "manager"]),
      (["--group", "Beta", "--org", "haacked"], ["manager"]),
      (["--ungrouped", "--org", "posthog"], ["u1", "manager"]),
      (["--group", "Alpha", "--local"], ["alpha-chat", "manager"]),
      ([], ["a1", "a2", "b1", "u1", "alpha-chat", "manager"]),
    ]

    for (args, names) in cases {
      let command = "sb ls --json \(args.joined(separator: " "))"
      do {
        #expect(try listed(f, args) == names, "\(command)")
      } catch {
        Issue.record("\(command): \(error)")
      }
    }
  }

  @Test func lsWithAnUnknownGroupNameExitsNonZero() throws {
    let repos = try Repos()
    let f = try fixture(repos)

    let result = try f.sbd.run(["ls", "--json", "--group", "Nope"])
    let withAKnownOne = try f.sbd.run(["ls", "--json", "--group", "Alpha,Nope"])

    #expect(result.status != 0)
    #expect(withAKnownOne.status != 0)
  }

  @Test func lsWithoutJsonListsOnlyTheGroupsSessions() throws {
    let repos = try Repos()
    let f = try fixture(repos)

    let text = try f.sbd.sb("ls", "--group", "Beta")

    #expect(text.contains("gf-b1"))
    #expect(!text.contains("gf-a1"))
    #expect(!text.contains("gf-u1"))
  }
}
