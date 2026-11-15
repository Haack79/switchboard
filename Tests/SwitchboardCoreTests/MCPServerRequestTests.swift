import Foundation
import Testing

@testable import SwitchboardCore

/// The data of an `mcp_request` event. A nil `servers` is the full setup, which sbd records as an explicit null.
func mcpRequestData(_ servers: [String]? = ["grafana"], reason: String = "Read the deploy dashboards.")
  -> [String: JSON]
{
  ["servers": servers.map { .array($0.map(JSON.string)) } ?? .null, "reason": .string(reason)]
}

/// An `mcp_request` event 9, so its card's id is 9.
func mcpRequestEvent(
  _ servers: [String]? = ["grafana"], reason: String = "Read the deploy dashboards.", id: Int64 = 9, t: Int64 = 10
) -> Event {
  Event(id: id, session: "s1", t: t, kind: "mcp_request", data: .object(mcpRequestData(servers, reason: reason)))
}

/// The `mcp_decided` event that closes card `card`. `servers` is the conversation's list after the decision.
func mcpDecidedEvent(_ card: Int64, _ decision: String, servers: [String]? = [], t: Int64 = 20) -> Event {
  event(
    "mcp_decided", t,
    [
      "card": .number(Double(card)), "decision": .string(decision),
      "servers": servers.map { .array($0.map(JSON.string)) } ?? .null,
    ])
}

/// The card that an `mcp_request` event opens.
func mcpCard(_ servers: [String]? = ["grafana"], reason: String = "Read the deploy dashboards.") -> Card {
  facts([mcpRequestEvent(servers, reason: reason)]).cards[0]
}

@Suite struct MCPServerRequestPayload {
  // MARK: Card(mcpRequest:)

  @Test func aRequestForNamesGivesAnMCPCardWithTheNamesAndTheReason() throws {
    let card = try #require(Card(mcpRequest: mcpRequestEvent(["grafana", "posthog-db"], reason: "Check the flags.")))

    #expect(card.kind == .mcp)
    #expect(card.mcpRequest == MCPServerRequest(servers: ["grafana", "posthog-db"], reason: "Check the flags."))
  }

  @Test func aRequestForAllGivesACardWhoseServersAreNil() throws {
    let card = try #require(Card(mcpRequest: mcpRequestEvent(nil)))

    #expect(card.kind == .mcp)
    #expect(card.mcpRequest != nil)
    #expect(card.mcpRequest?.servers == nil)
  }

  @Test func theCardTakesItsIdSessionAndTimeFromTheEvent() throws {
    let card = try #require(Card(mcpRequest: mcpRequestEvent(id: 12, t: 34)))

    #expect(card.id == 12)
    #expect(card.session == "s1")
    #expect(card.since == 34)
  }

  /// Decision 1 fixes these fields, as `Card(groupMessage:)` fixes them for `send_group`.
  @Test func theCardNamesTheToolAndHoldsNoCallNoQuestionsAndNoMessage() throws {
    let card = try #require(Card(mcpRequest: mcpRequestEvent()))

    #expect(card.tool == "request_mcp_server")
    #expect(card.input == [:])
    #expect(card.questions.isEmpty)
    #expect(!card.deferred)
    #expect(!card.hookClosed)
    #expect(card.send == nil)
  }

  /// Data that is not an `MCPServerRequest`.
  static let notRequests: [JSON] = [
    [:],
    ["servers": ["grafana"]],
    ["servers": "grafana", "reason": "Check."],
    ["servers": [1, 2], "reason": "Check."],
    ["servers": ["grafana"], "reason": 42],
    .object(sendPendingData()),
    "add grafana",
    .null,
  ]

  @Test(arguments: notRequests) func dataThatIsNotARequestGivesNoCard(_ data: JSON) {
    let e = Event(id: 9, session: "s1", t: 10, kind: "mcp_request", data: data)

    #expect(Card(mcpRequest: e) == nil)
  }

  @Test func otherInitsLeaveTheRequestNil() {
    #expect(facts(permissionTurn()).cards.first?.mcpRequest == nil)
    #expect(facts(questionTurn()).cards.first?.mcpRequest == nil)
    #expect(facts([sendPending()]).cards.first?.mcpRequest == nil)
    #expect(trustCard().mcpRequest == nil)
  }

  // MARK: The reason

  /// Text where a decoder, a trim, or a JSON round trip could change what Claude wrote.
  static let reasons = [
    "Say \"hi\" then stop", "null", "  42  ", "{\"servers\": null}", "\u{1B}[2K\\u{1b}", "grafana, posthog-db",
  ]

  @Test(arguments: reasons) func theCardKeepsTheRecordedReasonExactly(_ reason: String) {
    #expect(Card(mcpRequest: mcpRequestEvent(reason: reason))?.mcpRequest?.reason == reason)
  }

  // MARK: Encoding

  @Test func theFullSetupEncodesItsServersAsAnExplicitNull() throws {
    let request = MCPServerRequest(servers: nil, reason: "Read Slack.")

    let json = try JSON(encoding: request)

    #expect(json.object?.keys.contains("servers") == true, "\(json.text)")
    #expect(json["servers"] == .null)
  }

  @Test func namesEncodeAsAnArray() throws {
    let json = try JSON(encoding: MCPServerRequest(servers: ["grafana"], reason: "Read the dashboards."))

    #expect(json["servers"] == ["grafana"])
    #expect(json["reason"] == "Read the dashboards.")
  }

  /// A server literally named "null" is a list, not the full setup.
  @Test(arguments: [nil, [], ["grafana"], ["null"], ["grafana", "posthog-db"]] as [[String]?])
  func aRequestSurvivesEncoding(_ servers: [String]?) throws {
    let request = MCPServerRequest(servers: servers, reason: "Read the dashboards.")

    let decoded = try JSONCoding.decode(MCPServerRequest.self, from: try JSONCoding.encode(request))

    #expect(decoded == request)
    #expect(decoded.servers == servers)
  }

  /// The data that sbd records in `mcp_request` is the encoded request, and it reads back as the same request.
  @Test(arguments: [nil, ["grafana"], ["null"]] as [[String]?])
  func theRecordedDataIsTheEncodedRequest(_ servers: [String]?) throws {
    let request = MCPServerRequest(servers: servers, reason: "Check.")
    let recorded = JSON.object(mcpRequestData(servers, reason: "Check."))

    #expect(try JSON(encoding: request) == recorded)
    #expect(try JSONCoding.convert(recorded, to: MCPServerRequest.self) == request)
  }

  @Test func anMCPCardSurvivesEncoding() throws {
    for card in [mcpCard(), mcpCard(nil), mcpCard(["null"])] {
      #expect(try JSONCoding.decode(Card.self, from: try JSONCoding.encode(card)) == card)
    }
  }

  // MARK: The summary

  @Test(
    arguments: [
      (["grafana"], "add grafana to this conversation"),
      (["grafana", "posthog-db"], "add grafana and posthog-db to this conversation"),
      (["grafana", "posthog-db", "notes"], "add grafana, posthog-db, and notes to this conversation"),
      (nil, "load every MCP server in this conversation"),
    ] as [([String]?, String)])
  func theSummaryNamesTheServersOrTheFullSetup(_ servers: [String]?, _ summary: String) {
    #expect(MCPServerRequest(servers: servers, reason: "Check.").summary == summary)
  }

  @Test(arguments: [["grafana"], ["grafana", "posthog-db"], nil] as [[String]?])
  func theCardsReasonIsTheRequestsSummary(_ servers: [String]?) {
    let card = mcpCard(servers)

    #expect(card.reason == MCPServerRequest(servers: servers, reason: "Check.").summary)
  }

  // MARK: The status

  @Test(arguments: [("pending", MCPRequestDecision.pending), ("allowed", .allowed), ("denied", .denied)])
  func theDecisionUsesTheWireNames(_ raw: String, _ decision: MCPRequestDecision) throws {
    #expect(decision.rawValue == raw)
    #expect(try JSON(encoding: decision) == .string(raw))
  }

  @Test(arguments: [nil, ["grafana"]] as [[String]?])
  func aStatusSurvivesEncoding(_ servers: [String]?) throws {
    let status = MCPServerRequestStatus(
      card: 12, session: "m1", name: "Deploy watch", request: MCPServerRequest(servers: servers, reason: "Check."),
      decision: .pending)

    #expect(try JSONCoding.decode(MCPServerRequestStatus.self, from: try JSONCoding.encode(status)) == status)
  }

  @Test func aStatusForTheFullSetupEncodesItsServersAsAnExplicitNull() throws {
    let status = MCPServerRequestStatus(
      card: 12, session: "m1", name: "Deploy watch", request: MCPServerRequest(servers: nil, reason: "Read Slack."),
      decision: .allowed)

    let json = try JSON(encoding: status)

    #expect(json.object?.keys.contains("servers") == true, "\(json.text)")
    #expect(json["servers"] == .null)
    #expect(json["decision"] == "allowed")
    #expect(json["card"] == 12)
  }

  /// The MCP tool adds `instruction` to the status. A reader of the status ignores it.
  @Test func aStatusWithTheToolsInstructionStillDecodes() throws {
    let json: JSON = [
      "card": 12, "session": "m1", "name": "Deploy watch", "servers": ["grafana"], "reason": "Check.",
      "decision": "pending", "instruction": .string(MCPToolServer.requestRule),
    ]

    let status = try JSONCoding.convert(json, to: MCPServerRequestStatus.self)

    #expect(status.card == 12)
    #expect(status.decision == .pending)
  }
}

@Suite struct MCPRequestTool {
  func tool() throws -> MCPToolServer.Tool {
    try #require(MCPToolServer.allTools.first { $0.name == "request_mcp_server" })
  }

  @Test func theToolIsListedAmongAllTools() throws {
    _ = try tool()
  }

  @Test func onlyTheRequestToolIsManagerOnly() {
    #expect(MCPToolServer.managerOnly == ["request_mcp_server"])
  }

  @Test func theToolTakesNamesAllAndAReason() throws {
    let t = try tool()

    #expect(Set(t.properties.keys) == ["names", "all", "reason"])
    #expect(t.properties["names"]?["type"] == "array")
    #expect(t.properties["names"]?["items"]?["type"] == "string")
    #expect(t.properties["all"]?["type"] == "boolean")
    #expect(t.properties["reason"]?["type"] == "string")
  }

  @Test func onlyTheReasonIsRequired() throws {
    #expect(try tool().required == ["reason"])
  }

  /// The tool takes no session. sbd opens the card on the caller.
  @Test func theToolTakesNoSession() throws {
    #expect(try tool().properties["session"] == nil)
  }

  @Test func theDescriptionSaysAConnectorNeedsAllAndToEndTheTurn() throws {
    let description = try tool().description

    #expect(description.contains("Slack"), "\(description)")
    #expect(description.contains("`all`") || description.contains(" all "), "\(description)")
    #expect(description.lowercased().contains("end the turn") || description.lowercased().contains("end your turn"))
  }

  @Test func theRequestRuleSaysNothingChangedAndToEndTheTurn() {
    let rule = MCPToolServer.requestRule

    #expect(rule.hasPrefix("Nothing changed."), "\(rule)")
    #expect(rule.contains("End your turn now"), "\(rule)")
    #expect(rule.contains("A confirmation in this chat does not allow the request."), "\(rule)")
  }
}
