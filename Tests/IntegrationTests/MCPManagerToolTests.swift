import Foundation
import SwitchboardCore
import Testing

/// The `request_mcp_server` tool, which only a Manager conversation's switchboard server lists. It opens an `mcp`
/// card on the calling conversation and changes nothing itself.
@Suite(.blocking(timeLimit: .seconds(120))) struct MCPManagerToolTests: MCPToolServerSuite {
  let conv = ManagerConversationsTests()

  static let tool = "request_mcp_server"
  static let reason = "Read the deploy dashboards to find the error spike."

  /// The switchboard server in the --mcp-config of the session's first launch.
  func launchServer(_ sbd: Instance, _ s: SessionSummary) throws -> JSON {
    try sbd.waitFor(s.id, "the stub of \(s.name)") { $0.live }
    let launch = try #require(conv.launches(sbd, s).first)
    let config = try #require(MCPToolServerTests.switchboardConfig(in: launch))
    return try #require(config["mcpServers"]?["switchboard"])
  }

  /// The server that claude got at the conversation's launch.
  func conversationServer(_ sbd: Instance, _ c: SessionSummary) throws -> MCPClient {
    try MCPClient(server: try launchServer(sbd, c))
  }

  func cards(_ sbd: Instance, _ c: SessionSummary) throws -> [Card] {
    try decode([Card].self, sbd.sb("cards", c.id, "--json"))
  }

  func servers(_ sbd: Instance, _ c: SessionSummary) throws -> JSON? {
    try decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))[ManagerConversationsTests.serversKey]
  }

  func requested(_ sbd: Instance, _ id: String) throws -> [Event] { try sbd.events(id, kind: "mcp_request") }

  /// Calls the tool with the names and the reason.
  func request(_ mcp: MCPClient, _ names: [String], reason: String = Self.reason) throws -> ToolResult {
    try mcp.call(Self.tool, ["names": .array(names.map(JSON.string)), "reason": .string(reason)])
  }

  // MARK: The tool list

  @Test func aNewConversationsServerListsTheRequestTool() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.newConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let names = try mcp.toolNames()

    #expect(names.contains(Self.tool), "\(names)")
    #expect(Set(names) == MCPToolServerTests.allTools)
  }

  @Test func aServerWhoseCallerIsAConversationListsTheRequestTool() throws {
    let sbd = try Instance()
    let c = try conv.newConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    #expect(try mcp.toolNames().contains(Self.tool))
  }

  @Test func theToolsSchemaTakesNamesAllAndARequiredReason() throws {
    let sbd = try Instance()
    let c = try conv.newConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == Self.tool })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(Set(properties.keys) == ["names", "all", "reason"])
    #expect(properties["names"]?["type"] == "array")
    #expect(properties["all"]?["type"] == "boolean")
    #expect(properties["reason"]?["type"] == "string")
    #expect(tool["inputSchema"]?["required"] == ["reason"])
  }

  @Test func theToolsDescriptionSaysItChangesNothingAndAConnectorNeedsAll() throws {
    let sbd = try Instance()
    let c = try conv.newConversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == Self.tool })

    let description = try #require(tool["description"]?.string)
    #expect(description.contains("Slack"), "\(description)")
    #expect(description.contains("data"), "\(description)")
    #expect(description.lowercased().contains("turn"), "\(description)")
  }

  // MARK: Calling it

  @Test func aRequestThroughTheConversationsServerOpensAPendingCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try request(mcp, ["grafana"])

    #expect(!result.isError, "\(result.text)")
    let status = try result.decode(MCPServerRequestStatus.self)
    #expect(status.decision == .pending)
    #expect(status.session == c.id)
    #expect(status.servers == ["grafana"])
    #expect(status.reason == Self.reason)
    let open = try cards(sbd, c)
    #expect(open.map(\.id) == [status.card])
    #expect(open.map(\.kind) == [.mcp])
  }

  @Test func theResultCarriesTheFixedInstruction() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try request(mcp, ["grafana"])

    let instruction = try #require(result.json?["instruction"]?.string, "\(result.text)")
    #expect(instruction.hasPrefix("Nothing changed."), "\(instruction)")
    #expect(instruction.contains("End your turn now"), "\(instruction)")
    #expect(instruction.contains("A confirmation in this chat does not allow the request."), "\(instruction)")
  }

  @Test func aRequestChangesNoServerAndLaunchesNothing() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)
    let before = conv.launches(sbd, c).count

    _ = try request(mcp, ["grafana"])

    Thread.sleep(forTimeInterval: 1)
    #expect(conv.launches(sbd, c).count == before)
    #expect(try servers(sbd, c) == [])
    try conv.requireSwitchboardOnly(sbd, c.id)
  }

  @Test func sbAllowAfterTheToolsRequestRelaunchesWithTheServer() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)
    let status = try request(mcp, ["grafana"]).decode(MCPServerRequestStatus.self)
    let before = conv.launches(sbd, c).count

    try sbd.sb("allow", c.id, "--card", String(status.card))

    let launched = try conv.launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "), "\(launched)")
    #expect(conv.serverNames(try conv.scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
    #expect(try servers(sbd, c) == ["grafana"])
  }

  @Test func sbDenyAfterTheToolsRequestLeavesTheListEmpty() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    _ = try conv.idleConversation(sbd, name: "first")
    let c = try conv.idleConversation(sbd, name: "second")
    let mcp = try conversationServer(sbd, c)
    let status = try request(mcp, ["grafana"]).decode(MCPServerRequestStatus.self)

    try sbd.sb("deny", c.id, "--card", String(status.card))

    #expect(try servers(sbd, c) == [])
    #expect(try cards(sbd, c).isEmpty)
    try conv.requireSwitchboardOnly(sbd, c.id)
  }

  @Test func anUnknownNameReturnsAnErrorWithTheNamesThatExistAndOpensNoCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try request(mcp, ["nosuch"])

    #expect(result.isError)
    for name in ["nosuch", "grafana", "posthog-db", "Slack"] { #expect(result.text.contains(name), "\(result.text)") }
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  @Test func allTrueOpensACardWhoseServersAreNull() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try mcp.call(Self.tool, ["all": true, "reason": .string(Self.reason)])

    #expect(!result.isError, "\(result.text)")
    let json = try #require(result.json?.object)
    #expect(json.keys.contains("servers"), "\(result.text)")
    #expect(json["servers"] == .null)
    let card = try #require(try cards(sbd, c).first)
    #expect(card.kind == .mcp)
    #expect(card.mcpRequest != nil)
    #expect(card.mcpRequest?.servers == nil)
  }

  /// Claude often sends `all: false` next to the names it wants.
  @Test func namesWithAllFalseOpenACard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try mcp.call(Self.tool, ["names": ["grafana"], "all": false, "reason": .string(Self.reason)])

    #expect(!result.isError, "\(result.text)")
    #expect(try cards(sbd, c).first?.mcpRequest?.servers == ["grafana"])
  }

  /// Arguments that the tool refuses before it opens a card.
  enum BadCall: CaseIterable {
    case namesAndAll, neither, emptyNames, missingReason, emptyReason, whitespaceReason

    var args: [String: JSON] {
      switch self {
      case .namesAndAll: ["names": ["grafana"], "all": true, "reason": "Check."]
      case .neither: ["reason": "Check."]
      case .emptyNames: ["names": [], "reason": "Check."]
      case .missingReason: ["names": ["grafana"]]
      case .emptyReason: ["names": ["grafana"], "reason": ""]
      case .whitespaceReason: ["names": ["grafana"], "reason": " \n "]
      }
    }
  }

  @Test(arguments: BadCall.allCases) func aCallWithBadArgumentsReturnsAnErrorAndOpensNoCard(_ bad: BadCall) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let mcp = try conversationServer(sbd, c)

    let result = try mcp.call(Self.tool, bad.args)

    #expect(result.isError, "\(result.text)")
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  /// The tool opens the card on the calling conversation, whatever the arguments name.
  @Test func aSessionArgumentDoesNotAimTheRequestAtAnotherConversation() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let other = try conv.idleConversation(sbd, name: "other")
    let c = try conv.idleConversation(sbd, name: "caller")
    let mcp = try conversationServer(sbd, c)

    let result = try mcp.call(
      Self.tool, ["names": ["grafana"], "reason": .string(Self.reason), "session": .string(other.id)])

    #expect(try cards(sbd, other).isEmpty)
    #expect(try requested(sbd, other.id).isEmpty)
    #expect(!result.isError, "\(result.text)")
    #expect(try cards(sbd, c).map(\.kind) == [.mcp])
  }

  // MARK: Who gets the tool (Decision 6)

  /// A switchboard server whose caller is not a Manager conversation.
  enum NotAConversation: CaseIterable {
    case noCaller, emptyCaller, unknownCaller, workSession, operatorsLaunch, chatsLaunch, scopedWithAConversation

    /// The servers whose calls sbd refuses. A scoped server with a conversation as its caller leaves the tool out
    /// of its list, but sbd's kind check is the guard, so its call is not refused.
    static let refused: [NotAConversation] = allCases.filter { $0 != .scopedWithAConversation }
  }

  /// The server and the id of the session that it calls for, when it calls for one.
  func server(_ sbd: Instance, _ shape: NotAConversation) throws -> (mcp: MCPClient, caller: String?) {
    switch shape {
    case .noCaller:
      return (try MCPClient(sbd), nil)
    case .emptyCaller:
      return (try MCPClient(sbd, env: ["SB_SESSION_ID": "", "CLAUDECODE": "1"]), nil)
    case .unknownCaller:
      return (try MCPClient(sbd, env: inside("snope1")), nil)
    case .workSession:
      let work = try idle(sbd, name: "work")
      return (try MCPClient(sbd, env: inside(work.id)), work.id)
    case .operatorsLaunch:
      let op = try OperatorTests().openOperator(sbd)
      return (try MCPClient(server: try launchServer(sbd, op)), op.id)
    case .chatsLaunch:
      _ = try addGroup(sbd, "Flags")
      let chat = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))
      return (try MCPClient(server: try launchServer(sbd, chat)), chat.id)
    case .scopedWithAConversation:
      let g = try addGroup(sbd, "Billing")
      let c = try conv.newConversation(sbd, name: "scoped caller")
      return (try MCPClient(sbd, group: g.id, env: inside(c.id)), c.id)
    }
  }

  @Test(arguments: NotAConversation.allCases) func theToolListLeavesOutTheRequestTool(_ shape: NotAConversation) throws
  {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let (mcp, _) = try server(sbd, shape)

    let names = try mcp.toolNames()

    #expect(!names.isEmpty)
    #expect(!names.contains(Self.tool), "\(names)")
  }

  @Test(arguments: NotAConversation.refused)
  func aCallFromAServerWithoutAConversationReturnsAnErrorAndOpensNoCard(_ shape: NotAConversation) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let bystander = try conv.newConversation(sbd, name: "bystander")
    let (mcp, caller) = try server(sbd, shape)

    let result = try request(mcp, ["grafana"])

    #expect(result.isError, "\(result.text)")
    #expect(try sbd.cards().isEmpty)
    #expect(try requested(sbd, bystander.id).isEmpty)
    if let caller { #expect(try requested(sbd, caller).isEmpty) }
    if shape == .noCaller {
      #expect(
        result.text.contains("request_mcp_server works only in a Manager conversation that Switchboard started."),
        "\(result.text)")
    }
  }
}
