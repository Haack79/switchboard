import Foundation
import SwitchboardCore
import Testing

/// The `url` key of a session's JSON in `sb get --json`, `sb ls --json`, and the MCP `get_session` and
/// `list_sessions` tools. It holds the session's id link. The `link` key keeps the remote host's link state.
@Suite(.blocking(timeLimit: .seconds(180))) struct SessionJSONLinkTests: MCPToolServerSuite {
  private func url(_ id: String) -> JSON { .string(SessionLink.url(for: id).absoluteString) }

  private func listed(_ sbd: Instance) throws -> [JSON] {
    try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
  }

  private func entry(_ id: String, in list: [JSON]) throws -> JSON {
    try #require(list.first { $0["id"]?.string == id }, "\(id) is not in \(list)")
  }

  // MARK: sb

  @Test func sbGetJSONCarriesTheSessionsURL() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")

    let json = try sbd.summaryJSON(s.id)

    #expect(json["url"] == url(s.id), "\(json.text)")
  }

  @Test func sbLsJSONCarriesEachSessionsURL() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")

    let list = try listed(sbd)

    #expect(try entry(a.id, in: list)["url"] == url(a.id))
    #expect(try entry(b.id, in: list)["url"] == url(b.id))
  }

  /// Every session that `sb ls` lists, whatever its kind, carries its own id link.
  @Test func everySessionInSbLsJSONCarriesTheURLOfItsOwnId() throws {
    let sbd = try Instance()
    _ = try sbd.new(name: "alpha")
    _ = try sbd.new(name: "Fix CI chat")

    let list = try listed(sbd)

    for json in list {
      let id = try #require(json["id"]?.string)
      #expect(json["url"] == url(id), "\(json.text)")
    }
  }

  /// A name with a space or a slash does not change the URL, which always names the id.
  @Test(arguments: ["Fix CI chat", "posthog-code/flag-evaluations-table"])
  func theURLNamesTheIdWhateverTheName(_ name: String) throws {
    let sbd = try Instance()
    let s = try sbd.new(name: name)

    #expect(try sbd.summaryJSON(s.id)["url"] == url(s.id))
  }

  /// Decision 10: `sb get` and `sb ls` print the same human output as before.
  @Test func theHumanOutputOfSbGetAndSbLsDoesNotShowTheURL() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")

    let get = try sbd.sb("get", s.id)
    let ls = try sbd.sb("ls")

    #expect(!get.contains("switchboard://"), "\(get)")
    #expect(!ls.contains("switchboard://"), "\(ls)")
  }

  // MARK: MCP

  @Test func getSessionCarriesTheSessionsURL() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": .string(s.id)]).json)

    #expect(got["url"] == url(s.id), "\(got.text)")
  }

  @Test func getSessionByNameCarriesTheSessionsURL() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")
    let mcp = try MCPClient(sbd)

    let got = try #require(try mcp.call("get_session", ["session": "fix-cache"]).json)

    #expect(got["url"] == url(s.id), "\(got.text)")
  }

  @Test func listSessionsCarriesEachSessionsURL() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let mcp = try MCPClient(sbd)

    let list = try #require(try mcp.call("list_sessions").json?.array)

    #expect(try entry(a.id, in: list)["url"] == url(a.id))
    #expect(try entry(b.id, in: list)["url"] == url(b.id))
  }

  /// A scoped server filters sbd's list. The members it returns keep the key.
  @Test func aScopedListSessionsCarriesTheMembersURL() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try scopedClient(sbd, s, chat: try sbd.chatOf("Flags"))

    let list = try #require(try mcp.call("list_sessions").json?.array)

    #expect(try entry(s.member.id, in: list)["url"] == url(s.member.id))
  }

  // MARK: The link key

  /// A session on this Mac has no host link, so its JSON still has no `link` key beside the new `url`.
  @Test func aLocalSessionsJSONStillHasNoLinkKey() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "fix-cache")
    let mcp = try MCPClient(sbd)

    let jsons = [
      ("sb get", try sbd.summaryJSON(s.id)),
      ("sb ls", try entry(s.id, in: try listed(sbd))),
      ("get_session", try #require(try mcp.call("get_session", ["session": .string(s.id)]).json)),
      ("list_sessions", try entry(s.id, in: try #require(try mcp.call("list_sessions").json?.array))),
    ]

    for (source, json) in jsons {
      #expect(json.object?.keys.contains("link") == false, "\(source): \(json.text)")
      #expect(json["url"] == url(s.id), "\(source): \(json.text)")
    }
  }

  /// A session on a host keeps its link state under `link` and its id link under `url`.
  @Test func aRemoteSessionKeepsItsLinkStateBesideItsURL() throws {
    let sbd = try Instance.remote()
    try sbd.makeBoxFolder()
    let id = try sbd.id(of: try sbd.newOnHost("~/sb-box-repo", "--prompt", "hello"))
    try sbd.waitFor(id, "claude to run on the box") { $0.claudePid != nil }

    let json = try sbd.waitFor(
      "the summary to name the connected link", fetch: { try sbd.summaryJSON(id) },
      until: { $0["link"] == "connected" })
    let listedJSON = try entry(id, in: try listed(sbd))

    #expect(json["url"] == url(id), "\(json.text)")
    #expect(listedJSON["link"] == "connected", "\(listedJSON.text)")
    #expect(listedJSON["url"] == url(id), "\(listedJSON.text)")
  }
}
