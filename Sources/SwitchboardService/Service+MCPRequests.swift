import Foundation
import SwitchboardCore

/// MCP server requests from a Manager conversation. sbd changes the
/// conversation's servers only after the user allows its card in the app or
/// with `sb allow`.
extension Service {
  /// The `manager-mcp-request` request: opens an `mcp` card on the Manager conversation that asked, and changes
  /// nothing. It refuses a request that could not change the conversation's servers.
  func openMCPRequest(_ args: JSON) throws -> JSON {
    guard let id = args["session"]?.string, let session = entries[id]?.session, session.kind == .manager else {
      throw APIError(
        "only a Manager conversation asks for an MCP server. The user adds one with: sb manager mcp <conversation> add <server>"
      )
    }
    let all = args["all"]?.bool == true
    var names: [String] = []
    for name in args["servers"]?.array?.compactMap(\.string) ?? [] where !names.contains(name) { names.append(name) }
    guard all != !names.isEmpty else { throw APIError("ask for server names or for all, not both or neither") }
    let reason = oneLine(args["reason"]?.string ?? "", max: TriageCard.lineLength)
    guard !reason.isEmpty else { throw APIError("say in reason why this conversation needs the server") }
    if let open = entries[id]!.facts.cards.first(where: { $0.kind == .mcp }) {
      throw APIError("a request to \(open.summary) already waits for the user (card \(open.id)). End your turn.")
    }
    guard let current = session.mcp else { throw APIError("\(session.name) already loads every MCP server.") }
    var servers: [String]?
    if !all {
      let available = availableMCPServers(id)
      let unknown = names.filter { available[$0] == nil }
      if !unknown.isEmpty {
        throw APIError(
          "\(unknownMCPServers(unknown, available: available)) A claude.ai connector such as Slack needs all.")
      }
      let missing = names.filter { !current.contains($0) }
      guard !missing.isEmpty else { throw APIError("\(session.name) already loads \(englishList(names)).") }
      servers = missing
    }
    let request = MCPServerRequest(servers: servers, reason: reason)
    let event = record(id, "mcp_request", try JSON(encoding: request))
    return try JSON(
      encoding: MCPServerRequestStatus(
        card: event.id, session: id, name: session.name, request: request, decision: .pending, loaded: current))
  }

  /// Applies an `mcp` card's request through the same change as `sb manager mcp`, or drops it. An Allow
  /// reads the conversation's servers again. It changes nothing on a conversation that already loads
  /// every server. A server that no config holds any more refuses the Allow and leaves the card open.
  func decideMCPRequest(_ card: Card, _ request: MCPServerRequest, allow: Bool) throws -> JSON {
    let id = card.session
    if allow, entries[id]!.session.mcp != nil {
      _ = try changeMCPServers(
        id, add: request.servers ?? [], remove: [], all: request.servers == nil, none: false)
    }
    let decision: MCPRequestDecision = allow ? .allowed : .denied
    let session = entries[id]!.session
    record(
      id, "mcp_decided",
      [
        "card": .number(Double(card.id)), "decision": .string(decision.rawValue),
        "servers": session.mcp.map { .array($0.map(JSON.string)) } ?? .null,
      ])
    return try JSON(
      encoding: MCPServerRequestStatus(
        card: card.id, session: id, name: session.name, request: request, decision: decision, loaded: session.mcp))
  }
}
