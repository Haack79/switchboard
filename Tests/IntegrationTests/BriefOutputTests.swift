import Foundation
import SwitchboardCore
import Testing

/// The brief form of a session: `sb get --brief`, `sb ls --brief`, their `--json` forms, and the default of the MCP
/// `get_session` and `list_sessions` tools. Every path projects the same full data through `SessionBrief`, after scope
/// and filters.
@Suite(.blocking(timeLimit: .seconds(180))) struct BriefOutputTests: MCPToolServerSuite {
  // MARK: Helpers

  private func parse(_ text: String) throws -> JSON { try #require(JSON.parse(text), "not JSON: \(text)") }

  /// The JSON that a successful tool call returns.
  private func json(_ result: ToolResult) throws -> JSON {
    #expect(!result.isError, "\(result.text)")
    return try #require(result.json, "\(result.text)")
  }

  private func ids(_ list: JSON) throws -> [String] {
    try #require(list.array, "not a list: \(list.text)").compactMap { $0["id"]?.string }
  }

  private func briefJSON(_ sbd: Instance, _ id: String) throws -> JSON {
    try parse(try sbd.sb("get", id, "--brief", "--json"))
  }

  private func getSession(_ mcp: MCPClient, _ id: String, full: Bool? = nil) throws -> ToolResult {
    var args: [String: JSON] = ["session": .string(id)]
    if let full { args["full"] = .bool(full) }
    return try mcp.call("get_session", args)
  }

  private func listSessions(_ mcp: MCPClient, full: Bool? = nil) throws -> JSON {
    try json(mcp.call("list_sessions", full.map { ["full": .bool($0)] } ?? [:]))
  }

  /// The first token of each line of `sb ls --brief` or `sb get --brief`, which is the session's id.
  private func lineIds(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map { String($0.prefix { $0 != " " }) }
  }

  /// `SessionBrief` of a full entry. The unit tests check each of its keys against the full JSON.
  private func projected(_ full: JSON) throws -> JSON {
    try JSON(encoding: SessionBrief(JSONCoding.decode(SessionSummary.self, from: full.text)))
  }

  /// Each brief entry equals the projection of the full entry at the same place.
  private func briefListMatches(_ brief: JSON, _ full: JSON) -> Bool {
    guard let brief = brief.array, let full = full.array else { return false }
    return brief == full.compactMap { try? projected($0) }
  }

  /// A session on PostHog/charts#18303, whose PR the poller has read, with a date wait.
  private func readyWithWait(_ sbd: Instance) throws -> SessionSummary {
    let s = try MergeTests().readySession(sbd)
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "2h", "--note", "check")
    return try sbd.waitFor(s.id, "the date wait") { !$0.waits.isEmpty }
  }

  /// The ids of sessions of each kind that `sb get` and `get_session` show, by a label for the failure message.
  private func shapes(_ sbd: Instance) throws -> [(String, String)] {
    let ready = try readyWithWait(sbd)
    let plain = try sbd.new(name: "plain")
    let grouped = try sbd.new(name: "grouped")
    _ = try addGroup(sbd, "Flags", grouped.id)
    let chat = try sbd.chatOf("Flags")
    let manager = try decode(SessionSummary.self, try sbd.sb("manager", "--json"))
    let followup = try decode(
      SessionSummary.self,
      try sbd.sb(
        ["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache. It reads twice."],
        env: ["SB_SESSION_ID": plain.id]))
    try sbd.sb("snooze", plain.id, "--for", "2h")
    return [
      ("ready with a PR and a wait", ready.id), ("plain and snoozed", plain.id), ("grouped", grouped.id),
      ("group chat", chat), ("Manager conversation", manager.id), ("follow-up", followup.id),
    ]
  }

  /// One session read three ways: `sb get --brief --json`, the MCP `get_session` default, and `SessionBrief` of the
  /// summary that `sb get --json` prints.
  struct ThreeReads {
    var cli: JSON
    var tool: JSON
    var projected: JSON
  }

  private func threeReads(_ sbd: Instance, _ mcp: MCPClient, _ id: String) throws -> ThreeReads {
    let full = try decode(SessionSummary.self, try sbd.sb("get", id, "--json"))
    let projected = try JSON(encoding: SessionBrief(full))
    let cli = try briefJSON(sbd, id)
    let tool = try json(getSession(mcp, id))
    return ThreeReads(cli: cli, tool: tool, projected: projected)
  }

  // MARK: sb get --brief

  @Test func getBriefJSONCarriesThePRAndTheDateWait() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readyWithWait(sbd)

    let brief = try briefJSON(sbd, s.id)

    #expect(brief["pr"]?["number"] == .number(Double(MergeTests.number)), "\(brief.text)")
    #expect(brief["pr"]?["repo"] == .string(MergeTests.charts), "\(brief.text)")
    #expect(brief["waitLine"]?.string?.hasPrefix("until") == true, "\(brief.text)")
  }

  @Test func getBriefPrintsOneLineWithTheIdNameStateAndURL() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let s = try readyWithWait(sbd)

    let (text, full) = try sbd.waitFor(
      "the brief line to show the state", fetch: { (try sbd.sb("get", s.id, "--brief"), try sbd.get(s.id)) }
    ) { $0.0.contains($0.1.state.title) }

    let lines = text.split(whereSeparator: \.isNewline)
    #expect(lines.count == 1, "\(text)")
    let line = try #require(lines.first)
    #expect(line.hasPrefix("\(s.id)  "), "\(line)")
    #expect(line.contains(full.name), "\(line)")
    #expect(line.contains("\(full.state.title): "), "\(line)")
    #expect(line.contains("PR \(MergeTests.charts)#\(MergeTests.number)"), "\(line)")
    #expect(line.contains("waits: until"), "\(line)")
    #expect(line.hasSuffix(SessionLink.url(for: s.id).absoluteString), "\(line)")
  }

  /// `sb get` and `sb get --json` without `--brief` print the full form.
  @Test func getWithoutBriefStillPrintsTheFullForm() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")

    let json = try sbd.summaryJSON(s.id)
    let text = try sbd.sb("get", s.id)

    #expect(json["cwd"] != nil, "\(json.text)")
    #expect(!text.contains("switchboard://"), "\(text)")
  }

  // MARK: Parity between sb get --brief --json, get_session, and the full JSON

  /// `sb get --brief --json` and the MCP default both equal `SessionBrief` of the full summary that `sb get --json`
  /// prints, for each kind of session.
  @Test func getBriefJSONAndGetSessionAndTheProjectedFullAllAgree() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    let sessions = try shapes(sbd)
    let mcp = try MCPClient(sbd)

    for (label, id) in sessions {
      let r = try sbd.waitFor("\(label): the three reads to agree", fetch: { try threeReads(sbd, mcp, id) }) {
        $0.cli == $0.tool && $0.cli == $0.projected
      }

      #expect(r.cli == r.tool, "\(label): sb get --brief --json \(r.cli.text) but get_session \(r.tool.text)")
      #expect(
        r.cli == r.projected, "\(label): sb get --brief --json \(r.cli.text) but SessionBrief \(r.projected.text)")
    }
  }

  // MARK: sb ls --brief

  @Test func lsBriefWithNothingListedPrintsTheSameLineAsLs() throws {
    let sbd = try Instance()
    let listed = try ids(parse(try sbd.sb("ls", "--json")))
    try #require(listed.isEmpty, "a fresh sbd lists \(listed)")

    let brief = try sbd.sb("ls", "--brief")
    let plain = try sbd.sb("ls")

    #expect(brief == plain)
  }

  /// `sb ls --removed` ignores `--brief`, as it ignores `--org` and `--local`.
  @Test func lsRemovedIgnoresBrief() throws {
    let sbd = try Instance()
    let alpha = try sbd.new(name: "alpha")
    try sbd.sb("rm", alpha.id)

    let text = try sbd.sb("ls", "--removed", "--brief")
    let json = try sbd.sb("ls", "--removed", "--brief", "--json")
    let plainText = try sbd.sb("ls", "--removed")
    let plainJSON = try sbd.sb("ls", "--removed", "--json")

    #expect(json == plainJSON)
    #expect(json.contains(alpha.id))
    // The text ends with the time since removal in whole seconds, which can differ between the two runs.
    let prefix = "\(alpha.id)  alpha  removed "
    for output in [text, plainText] {
      #expect(output.split(whereSeparator: \.isNewline).map { $0.hasPrefix(prefix) } == [true], "\(output)")
    }
  }

  // MARK: The brief list holds the full list's sessions

  /// Alpha holds a PostHog session and a haacked one, Beta a PostHog one, and a PostHog session is in no group.
  /// Alpha has a chat, the Manager runs, and a follow-up waits to start.
  private func filterFixture(_ repos: Repos) throws -> Instance {
    let sbd = try Instance()
    let posthog = try repos.make("PostHog/posthog")
    let haacked = try repos.make("haacked/switchboard")
    func new(_ path: String, _ name: String) throws -> SessionSummary {
      try decode(SessionSummary.self, try sbd.sb("new", "--json", "--name", "bf-\(name)", path))
    }
    let a1 = try new(posthog, "a1")
    let a2 = try new(haacked, "a2")
    let b1 = try new(posthog, "b1")
    let u1 = try new(posthog, "u1")
    _ = try addGroup(sbd, "Alpha", a1.id, a2.id)
    _ = try addGroup(sbd, "Beta", b1.id)
    _ = try sbd.chatOf("Alpha")
    _ = try sbd.sb("manager", "--json")
    _ = try sbd.sb(
      ["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache. It reads twice."],
      env: ["SB_SESSION_ID": u1.id])
    let work = [a1.id, a2.id, b1.id, u1.id]
    _ = try sbd.waitFor(
      "every folder's remotes to be read", fetch: { try decode([SessionSummary].self, sbd.sb("ls", "--json")) }
    ) {
      list in work.allSatisfy { id in list.first { $0.id == id }?.repositoryRead == true }
    }
    return sbd
  }

  static let filters: [[String]] = [
    [], ["--group", "Alpha"], ["--group", "Beta"], ["--ungrouped"], ["--group", "Alpha", "--ungrouped"],
    ["--group", "Alpha,Beta"], ["--org", "posthog"], ["--org", "haacked"], ["--local"],
    ["--group", "Alpha", "--org", "posthog"], ["--ungrouped", "--org", "posthog"], ["--group", "Alpha", "--local"],
  ]

  /// For each filter, `sb ls --brief --json` lists the projection of each `sb ls --json` entry in the same order, and
  /// `sb ls --brief` prints one line for each, or the same line as `sb ls` when nothing is listed.
  @Test func lsBriefListsTheSameSessionsAsLsForEachFilter() throws {
    let repos = try Repos()
    let sbd = try filterFixture(repos)

    for args in Self.filters {
      let command = "sb ls \(args.joined(separator: " "))"
      let (json, text, full) = try sbd.waitFor(
        "\(command): the brief and full lists to agree",
        fetch: {
          (
            try parse(try sbd.sb(["ls", "--brief", "--json"] + args)), try sbd.sb(["ls", "--brief"] + args),
            try parse(try sbd.sb(["ls", "--json"] + args))
          )
        }
      ) { briefListMatches($0.0, $0.2) && lineIds($0.1) == $0.2.array?.compactMap { $0["id"]?.string } }

      #expect(briefListMatches(json, full), "\(command): \(json.text) but full \(full.text)")
      if try ids(full).isEmpty {
        #expect(text == (try sbd.sb(["ls"] + args)), "\(command): \(text)")
      } else {
        #expect(lineIds(text) == (try ids(full)), "\(command): \(text) but full \(full.text)")
      }
    }
  }

  // MARK: MCP

  @Test func listSessionsDefaultEqualsSbLsBriefJSON() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withMergeStub(github)
    _ = try shapes(sbd)
    let mcp = try MCPClient(sbd)

    let (tool, cli) = try sbd.waitFor(
      "list_sessions and sb ls --brief --json to agree",
      fetch: { (try listSessions(mcp), try parse(try sbd.sb("ls", "--brief", "--json"))) }
    ) { $0.0 == $0.1 }

    #expect(tool == cli, "list_sessions \(tool.text) but sb ls --brief --json \(cli.text)")
  }

  @Test func getSessionWithFullTrueDecodesAsASessionSummaryWithItsFolder() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")
    let mcp = try MCPClient(sbd)

    let result = try getSession(mcp, s.id, full: true)

    let got = try result.decode(SessionSummary.self)
    #expect(got.id == s.id)
    #expect(result.json?["cwd"] == .string(s.cwd), "\(result.text)")
  }

  @Test func listSessionsWithFullTrueDecodesAsSessionSummaries() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("list_sessions", ["full": true]).decode([SessionSummary].self)

    #expect(Set(listed.map(\.id)) == [a.id, b.id])
    #expect(listed.allSatisfy { !$0.cwd.isEmpty })
  }

  @Test func getSessionWithFullFalseReturnsTheBrief() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")
    let mcp = try MCPClient(sbd)

    let explicit = try #require(try getSession(mcp, s.id, full: false).json)
    let byDefault = try #require(try getSession(mcp, s.id).json)

    #expect(explicit == byDefault)
    #expect(explicit["cwd"] == nil, "\(explicit.text)")
  }

  // MARK: Scope

  @Test func aScopedListSessionsBriefListsOnlyTheGroupsMembers() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let brief = try ids(listSessions(mcp))
    let full = try ids(listSessions(mcp, full: true))

    #expect(brief == [s.member.id])
    #expect(brief == full)
  }

  /// The chat's server lists the group's chat as well as its member. The brief and the full list agree on both.
  @Test func aChatsScopedListSessionsBriefMatchesItsFullList() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try scopedClient(sbd, s, chat: try sbd.chatOf("Flags"))

    let brief = try ids(listSessions(mcp))
    let full = try ids(listSessions(mcp, full: true))

    #expect(brief == full)
    #expect(brief.contains(s.member.id))
    #expect(!brief.contains(s.outside.id))
    #expect(!brief.contains(s.loose.id))
  }

  /// The scope check runs on the full data before the projection, so the brief form never returns an outsider.
  @Test func aScopedGetSessionRefusesAnOutsiderHoweverItIsNamed() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    for outsider in Outsider.allCases {
      let session = outsider.session(s)
      for how in Naming.allCases {
        let label = "\(outsider.rawValue) by \(how)"

        let result = try getSession(mcp, name(session.id, session.name, how))

        #expect(result.isError, "\(label): \(result.text)")
        #expect(result.text.contains("is not in group"), "\(label): \(result.text)")
        #expect(!result.text.contains(SessionLink.url(for: session.id).absoluteString), "\(label): \(result.text)")
      }
    }
  }

  @Test func aScopedGetSessionBriefOfAMemberEqualsTheUnscopedBrief() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let scoped = try MCPClient(sbd, group: s.group.id)
    let unscoped = try MCPClient(sbd)

    let (inScope, anywhere) = try sbd.waitFor(
      "the scoped and unscoped briefs to agree",
      fetch: { (try json(getSession(scoped, s.member.id)), try json(getSession(unscoped, s.member.id))) }
    ) { $0.0 == $0.1 }

    #expect(inScope == anywhere)
  }

  // MARK: Usage

  @Test func sbHelpListsBriefOnLsAndGet() throws {
    let sbd = try Instance()

    let usage = try sbd.sb("help")

    let lines = usage.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    for command in ["ls", "get"] {
      #expect(lines.contains { $0.hasPrefix("\(command) ") && $0.contains("--brief") }, "\(command): \(usage)")
    }
  }
}
