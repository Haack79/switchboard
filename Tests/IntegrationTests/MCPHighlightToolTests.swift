import Foundation
import SwitchboardCore
import Testing

extension MCPToolServerSuite {
  fileprivate func managerID(_ sbd: Instance) throws -> String {
    try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))
  }

  fileprivate func isHighlighted(_ sbd: Instance, _ id: String) throws -> Bool {
    try sbd.listed(id)["highlighted"] == .bool(true)
  }
}

/// The `highlight` tool of an unscoped server, as the Manager has it, and of a server scoped to group Flags.
@Suite(.blocking(timeLimit: .seconds(120))) struct MCPHighlightToolTests: MCPToolServerSuite {
  @Test func theManagerHighlightsASession() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("highlight", ["session": .string(s.id)])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["highlighted"] == .bool(true), "\(result.text)")
    #expect(try isHighlighted(sbd, s.id))
  }

  @Test func theToolRecordsTheHighlightAsClaudes() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    _ = try mcp.call("highlight", ["session": .string(s.id)])

    let events = try sbd.events(s.id, kind: "highlighted")
    #expect(events.count == 1)
    #expect(events.first?.data["by"] == "claude")
  }

  @Test func clearTrueRemovesTheHighlight() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))
    _ = try mcp.call("highlight", ["session": .string(s.id)])

    let result = try mcp.call("highlight", ["session": .string(s.id), "clear": true])

    #expect(!result.isError, "\(result.text)")
    #expect(try !isHighlighted(sbd, s.id))
    #expect(try sbd.events(s.id, kind: "unhighlighted").first?.data["by"] == "claude")
  }

  @Test func clearFalseHighlights() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("highlight", ["session": .string(s.id), "clear": false])

    #expect(!result.isError, "\(result.text)")
    #expect(try isHighlighted(sbd, s.id))
  }

  @Test func aSessionCantHighlightItselfThroughMCP() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("highlight", ["session": .string(s.id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("can't highlight itself"), "\(result.text)")
    #expect(try !isHighlighted(sbd, s.id))
  }

  @Test func aSessionCantClearItsOwnHighlightThroughMCP() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    try sbd.sb("highlight", s.id)
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("highlight", ["session": .string(s.id), "clear": true])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("can't change its own highlight"), "\(result.text)")
    #expect(try isHighlighted(sbd, s.id))
  }

  @Test func theManagerHighlightingADoneSessionIsAnError() throws {
    let sbd = try Instance()
    let s = try idle(sbd, name: "worker")
    try sbd.sb("done", s.id)
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("highlight", ["session": .string(s.id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("worker is done"), "\(result.text)")
    #expect(try sbd.count("highlighted", of: s.id) == 0)
  }

  @Test func theManagerHighlightingAGroupChatIsAnError() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let chat = try sbd.chatOf("Flags")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("highlight", ["session": .string(chat)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("only a work session can be highlighted"), "\(result.text)")
    #expect(try sbd.count("highlighted", of: chat) == 0)
  }

  // MARK: A server scoped to group Flags

  /// The scope and the Flags chat, whose claude runs the scoped server.
  private func scopedClient(_ sbd: Instance) throws -> (scope: Scope, mcp: MCPClient) {
    let s = try scope(sbd)
    let chat = try sbd.chatOf("Flags")
    return (s, try MCPClient(sbd, group: s.group.id, env: inside(chat)))
  }

  @Test(arguments: Naming.allCases)
  func aScopedServerHighlightsAMember(_ how: Naming) throws {
    let sbd = try Instance()
    let (s, mcp) = try scopedClient(sbd)

    let result = try mcp.call("highlight", ["session": .string(name(s.member.id, s.member.name, how))])

    #expect(!result.isError, "\(result.text)")
    #expect(try isHighlighted(sbd, s.member.id))
  }

  enum Outsider: String, CaseIterable, Sendable { case outside, loose }

  @Test(arguments: Outsider.allCases, Naming.allCases)
  func aScopedServerRefusesASessionOutsideItsGroup(_ who: Outsider, _ how: Naming) throws {
    let sbd = try Instance()
    let (s, mcp) = try scopedClient(sbd)
    let target = who == .outside ? s.outside : s.loose

    let result = try mcp.call("highlight", ["session": .string(name(target.id, target.name, how))])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not in group"), "\(result.text)")
    #expect(try !isHighlighted(sbd, target.id))
    #expect(try sbd.count("highlighted", of: target.id) == 0)
  }

  @Test func aScopedServerRefusesToClearASessionOutsideItsGroup() throws {
    let sbd = try Instance()
    let (s, mcp) = try scopedClient(sbd)
    try sbd.sb("highlight", s.outside.id)

    let result = try mcp.call("highlight", ["session": .string(s.outside.id), "clear": true])

    #expect(result.isError, "\(result.text)")
    #expect(try isHighlighted(sbd, s.outside.id))
  }
}
