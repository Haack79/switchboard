import Foundation
import SwitchboardCore
import Testing

/// A move of a Manager conversation, the operator, or a group chat to another
/// account with `account-move` and a `sessions` list, as the app sends it.
/// Each session keeps the account it moved to. The result's `mcpDropped`
/// names the listed MCP servers that the target account lacks.
@Suite(.blocking(timeLimit: .seconds(180))) struct ManagerAccountMoveTests {
  let conversations = ManagerConversationsTests()
  let accountTests = AccountTests()
  let operatorTests = OperatorTests()

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A sbd with accounts A and B and A active, so new sessions record A.
  func instance() throws -> Instance {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  /// The last run of the stub claude for this session.
  func lastLaunch(_ sbd: Instance, _ s: SessionSummary) -> (account: String, agent: String, args: String)? {
    sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) }
  }

  /// Stops the session's claude and waits until sbd reports it stopped.
  func stop(_ sbd: Instance, _ s: SessionSummary) throws {
    try sbd.stopClaude(s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  /// The session's claude pid once its claude runs.
  func runningPid(_ sbd: Instance, _ s: SessionSummary) throws -> Int {
    try #require(try sbd.waitFor(s.id, "the claude of \(s.name)") { $0.live && $0.claudePid != nil }.claudePid)
  }

  // MARK: Manager conversations and the operator

  @Test func aStoppedManagerConversationMovesAndKeepsItsAccount() throws {
    let sbd = try instance()
    let c = try conversations.idleConversation(sbd, name: "c1")
    #expect(c.account == sbd.account("A"))
    try stop(sbd, c)
    let old = try #require(accountTests.transcript(sbd, "A", c))

    let result = try decode(AccountMove.self, sbd.sb("account", "move", "--json", "B", "--session", c.id))

    #expect(result.moved == [c.id])
    #expect(result.blocked.isEmpty)
    #expect(try decode(SessionSummary.self, sbd.sb("get", "--json", c.id)).account == sbd.account("B"))
    let copy = try #require(accountTests.transcript(sbd, "B", c))
    #expect((copy as NSString).lastPathComponent == (old as NSString).lastPathComponent)
    let text = try sbd.sb("get", c.id)
    #expect(text.contains("account: B"), "\(text)")

    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.sb("account", "use", "A", "--new-only")
    #expect(try sbd.get(c.id).account == sbd.account("B"))

    try sbd.sb("send", c.id, "again")
    try sbd.waitFor(c.id, "the reply to again", timeout: 30) { $0.lastReply == "Done: again" }

    let launch = try #require(lastLaunch(sbd, c))
    #expect(launch.account == sbd.account("B"))
    #expect(launch.args.contains("--resume \(c.claudeSessionId)"), "\(launch.args)")
    #expect(try sbd.get(c.id).account == sbd.account("B"))
  }

  /// A move with `--stop` stops only the named conversation's claude. The
  /// other conversation and the operator keep their account and their claude.
  @Test func theOperatorAndEachConversationKeepTheirOwnAccounts() throws {
    let sbd = try instance()
    let c1 = try conversations.idleConversation(sbd, name: "c1")
    let c2 = try conversations.idleConversation(sbd, name: "c2")
    let op = try operatorTests.idleOperator(sbd)
    for s in [c1, c2, op] { #expect(try sbd.get(s.id).account == sbd.account("A"), "\(s.name)") }
    _ = try runningPid(sbd, c1)
    let c2Pid = try runningPid(sbd, c2)
    let opPid = try runningPid(sbd, op)

    let result = try decode(AccountMove.self, sbd.sb("account", "move", "--json", "B", "--session", c1.id, "--stop"))

    #expect(result.moved == [c1.id])
    #expect(result.blocked.isEmpty)
    #expect(try sbd.get(c1.id).account == sbd.account("B"))
    let keptC2 = try sbd.get(c2.id)
    #expect(keptC2.account == sbd.account("A"))
    #expect(keptC2.claudePid == c2Pid)
    let keptOp = try sbd.get(op.id)
    #expect(keptOp.account == sbd.account("A"))
    #expect(keptOp.claudePid == opPid)
  }

  @Test func theOperatorMovesByName() throws {
    let sbd = try instance()
    let op = try operatorTests.idleOperator(sbd)
    #expect(op.name == Manager.operatorName)

    let result = try decode(
      AccountMove.self, sbd.sb("account", "move", "--json", "B", "--session", Manager.operatorName, "--stop"))

    #expect(result.moved == [op.id])
    #expect(result.blocked.isEmpty)
    #expect(try sbd.get(op.id).account == sbd.account("B"))
  }

  // MARK: Dropped MCP servers

  /// `mcpDropped` lists, for each conversation that moves, the servers in its
  /// `mcp` list that the target account lacks. A conversation with the full
  /// setup or with no listed server gets no entry. The launch after the move
  /// records an `mcp-missing` event that names the same servers.
  @Test func theDryRunNamesTheListedServersTheTargetLacks() throws {
    let sbd = try instance()
    let listed = try conversations.idleConversation(sbd, name: "c1")
    let full = try conversations.idleConversation(sbd, name: "c2")
    let none = try conversations.idleConversation(sbd, name: "c3")
    try conversations.addUserServers(
      sbd.account("A"),
      ["notes": ManagerConversationsTests.userServer, "grafana": ManagerConversationsTests.userServer])
    try conversations.addUserServers(sbd.account("B"), ["grafana": ManagerConversationsTests.userServer])
    try sbd.sb("manager", "mcp", listed.id, "--none")
    try conversations.changeServers(sbd, listed, "add", "notes", "grafana")
    try conversations.changeServers(sbd, full, "--all")
    for s in [listed, full, none] { _ = try runningPid(sbd, s) }
    try #require(try sbd.get(listed.id).mcp?.sorted() == ["grafana", "notes"])
    try #require(try sbd.get(full.id).mcp == nil)
    try #require(try sbd.get(none.id).mcp == [])

    let plan = try decode(
      AccountMove.self,
      sbd.sb(
        "account", "move", "--json", "B", "--dry-run", "--stop", "--session", listed.id, "--session", full.id,
        "--session", none.id))

    #expect(plan.moved == [listed.id, full.id, none.id].sorted())
    #expect(plan.mcpDropped == [listed.id: ["notes"]])
    let text = try sbd.sb("account", "move", "B", "--dry-run", "--stop", "--session", listed.id)
    #expect(text.contains("  drops MCP servers: \(listed.id): notes"), "\(text)")

    let result = try decode(
      AccountMove.self, sbd.sb("account", "move", "--json", "B", "--stop", "--session", listed.id))
    #expect(result.moved == [listed.id])
    #expect(result.mcpDropped == [listed.id: ["notes"]])
    try sbd.sb("send", listed.id, "again")
    try sbd.waitFor(listed.id, "the reply to again", timeout: 30) { $0.lastReply == "Done: again" }

    let missing = try #require(try sbd.events(listed.id).last { $0.kind == "mcp-missing" })
    #expect(missing.data["servers"] == ["notes"])
    #expect(missing.data["servers"] == .array((plan.mcpDropped?[listed.id] ?? []).map(JSON.string)))
  }

  /// A result with no dropped server leaves the field out of the JSON.
  @Test func aMoveThatDropsNoServerHasNoMCPDroppedField() throws {
    let sbd = try instance()
    let c = try conversations.idleConversation(sbd, name: "c1")
    try #require(try sbd.get(c.id).mcp == [])

    let text = try sbd.sb("account", "move", "--json", "B", "--dry-run", "--stop", "--session", c.id)

    let object = try #require(JSON.parse(text)?.object)
    #expect(object["moved"] == [.string(c.id)])
    #expect(object["mcpDropped"] == nil, "\(text)")
  }

  // MARK: Group chats

  /// A chat follows its group's account, so a move to another account is
  /// refused with the group's reason, and `--stop` leaves its claude running.
  @Test func aGroupChatFollowsItsGroupsAccount() throws {
    let sbd = try instance()
    _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
    _ = try decode(GroupSummary.self, sbd.sb("group", "account", "--json", "Flags", "B"))
    let chat = try ChatTests().chat(sbd, "Flags")
    #expect(chat.account == sbd.account("B"))
    let pid = try runningPid(sbd, chat)

    for extra in [["--dry-run"], [], ["--stop"]] {
      let r = try sbd.run(["account", "move", "--json", "A", "--session", chat.id] + extra)
      #expect(r.status != 0, "\(extra): \(r.stdout)")
      let result = try decode(AccountMove.self, r.stdout)
      #expect(result.moved.isEmpty, "\(extra)")
      #expect(result.blocked.map(\.session) == [chat.id], "\(extra)")
      let reason = result.blocked.first?.reason ?? ""
      #expect(reason.contains("its group Flags runs its sessions under the account B"), "\(extra): \(reason)")
    }

    let kept = try sbd.get(chat.id)
    #expect(kept.account == sbd.account("B"))
    #expect(kept.claudePid == pid)
  }

  // MARK: The app's dry run

  enum Running: CaseIterable { case work, manager }

  /// The app's dry run sends `stop` and `dryRun` together. sbd lists the
  /// running session as one that would move and stops nothing.
  @Test(arguments: Running.allCases) func theAppsDryRunLeavesARunningClaudeRunning(_ kind: Running) throws {
    let sbd = try instance()
    let s: SessionSummary
    switch kind {
    case .work: s = try sbd.idleSession(name: "w1")
    case .manager: s = try conversations.idleConversation(sbd, name: "c1")
    }
    let pid = try runningPid(sbd, s)
    let launches = conversations.launches(sbd, s).count

    let plan = try sbd.client.call(
      "account-move",
      ["account": .string(sbd.account("B")), "sessions": [.string(s.id)], "stop": true, "dryRun": true],
      as: AccountMove.self)

    #expect(plan.moved == [s.id])
    #expect(plan.blocked.isEmpty)
    Thread.sleep(forTimeInterval: 1)
    let kept = try sbd.get(s.id)
    #expect(kept.live)
    #expect(kept.claudePid == pid)
    #expect(kept.account == sbd.account("A"))
    #expect(accountTests.transcript(sbd, "B", s) == nil)
    #expect(conversations.launches(sbd, s).count == launches)
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "account-moved" })
  }
}
