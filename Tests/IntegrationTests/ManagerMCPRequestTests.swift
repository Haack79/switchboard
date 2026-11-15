import Foundation
import SwitchboardCore
import Testing

/// A Manager conversation asks for MCP servers with `manager-mcp-request`,
/// which opens an `mcp` card on it and changes nothing. Allow applies the
/// change through the same code as `sb manager mcp`, which relaunches claude
/// with `--resume`. Deny leaves the servers alone.
@Suite(.blocking(timeLimit: .seconds(120))) struct ManagerMCPRequestTests {
  let conv = ManagerConversationsTests()

  static let reason = "Read the deploy dashboards to find the error spike."

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  /// Sends `manager-mcp-request` as a conversation's switchboard server sends it.
  func request(_ sbd: Instance, _ args: [String: JSON]) throws -> MCPServerRequestStatus {
    try sbd.client.call("manager-mcp-request", args, as: MCPServerRequestStatus.self)
  }

  /// Asks for the named servers on the conversation's behalf.
  func ask(_ sbd: Instance, _ c: SessionSummary, _ servers: [String], reason: String = Self.reason) throws
    -> MCPServerRequestStatus
  {
    try request(
      sbd, ["session": .string(c.id), "servers": .array(servers.map(JSON.string)), "reason": .string(reason)])
  }

  /// Asks for the full setup on the conversation's behalf.
  func askAll(_ sbd: Instance, _ c: SessionSummary, reason: String = Self.reason) throws -> MCPServerRequestStatus {
    try request(sbd, ["session": .string(c.id), "all": true, "reason": .string(reason)])
  }

  /// The `servers` of `sb manager mcp <conv> --json`: an array, or null for the full setup.
  func servers(_ sbd: Instance, _ c: SessionSummary) throws -> JSON? {
    try conv.decode(JSON.self, sbd.sb("manager", "mcp", c.id, "--json"))[ManagerConversationsTests.serversKey]
  }

  /// The open cards of the conversation, as `sb cards <conv> --json` lists them.
  func cards(_ sbd: Instance, _ c: SessionSummary) throws -> [Card] {
    try conv.decode([Card].self, sbd.sb("cards", c.id, "--json"))
  }

  /// The text of each message that reached the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id, kind: "sent").compactMap { $0.data["text"]?.string }
  }

  /// Who decides: `sb allow` or `sb deny` in a terminal, or the app's `answer` request.
  enum Decider: CaseIterable { case cli, app }

  func decide(_ sbd: Instance, _ how: Decider, _ c: SessionSummary, _ card: Int64, allow: Bool) throws {
    switch how {
    case .cli:
      try sbd.sb(allow ? "allow" : "deny", c.id, "--card", String(card))
    case .app:
      _ = try sbd.client.call(
        "answer",
        ["session": .string(c.id), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny")])
    }
  }

  /// Allows the card and waits for the relaunch that applies it. It returns the arguments in claude.sh.
  @discardableResult
  func allowAndRelaunch(_ sbd: Instance, _ c: SessionSummary, _ card: Int64, by how: Decider = .cli) throws
    -> [String]
  {
    let before = conv.launches(sbd, c).count
    try decide(sbd, how, c, card, allow: true)
    let launched = try conv.launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "), "\(launched)")
    return try conv.scriptArgs(sbd, c.id)
  }

  /// Waits a second and checks that the conversation's claude did not launch again.
  func expectNoLaunch(_ sbd: Instance, _ c: SessionSummary, since before: Int) {
    Thread.sleep(forTimeInterval: 1)
    #expect(conv.launches(sbd, c).count == before)
  }

  func decided(_ sbd: Instance, _ c: SessionSummary) throws -> [Event] { try sbd.events(c.id, kind: "mcp_decided") }

  func requested(_ sbd: Instance, _ id: String) throws -> [Event] { try sbd.events(id, kind: "mcp_request") }

  // MARK: Opening the card

  @Test func aRequestAnswersPendingWithTheCardAndTheRequest() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try ask(sbd, c, ["grafana"])

    #expect(status.decision == .pending)
    #expect(status.session == c.id)
    #expect(status.name == c.name)
    #expect(status.servers == ["grafana"])
    #expect(status.reason == Self.reason)
  }

  @Test func aRequestOpensOneMCPCardOnTheConversation() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try ask(sbd, c, ["grafana"])

    let open = try cards(sbd, c)
    #expect(open.map(\.id) == [status.card])
    #expect(open.map(\.kind) == [.mcp])
    #expect(open.first?.session == c.id)
    #expect(open.first?.mcpRequest == MCPServerRequest(servers: ["grafana"], reason: Self.reason))
  }

  @Test func aRequestChangesNoServerAndLaunchesNothing() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.requireSwitchboardOnly(sbd, c.id)
    let before = conv.launches(sbd, c).count

    _ = try ask(sbd, c, ["grafana"])

    expectNoLaunch(sbd, c, since: before)
    #expect(try servers(sbd, c) == [])
    try conv.requireSwitchboardOnly(sbd, c.id)
    #expect(try sbd.get(c.id).live)
  }

  @Test func aRequestRecordsAnMCPRequestEventWhoseIdIsTheCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try ask(sbd, c, ["grafana"])

    let events = try requested(sbd, c.id)
    #expect(events.map(\.id) == [status.card])
    #expect(events.first?.data["servers"] == ["grafana"])
    #expect(events.first?.data["reason"]?.string == Self.reason)
  }

  @Test func anAllRequestRecordsAnExplicitNullAndAnswersNilServers() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try askAll(sbd, c)

    #expect(status.servers == nil)
    let data = try #require(try requested(sbd, c.id).first?.data.object)
    #expect(data.keys.contains("servers"), "\(data)")
    #expect(data["servers"] == .null)
    #expect(try cards(sbd, c).first?.mcpRequest?.servers == nil)
  }

  @Test func theConversationNeedsYouWithTheCardsReason() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    _ = try ask(sbd, c, ["grafana"])

    let asking = try sbd.get(c.id)
    #expect(asking.state == .needsYou)
    #expect(asking.reason == "add grafana to this conversation")
  }

  @Test func theConversationIsInTheInboxWithTheRequestsTitle() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    _ = try ask(sbd, c, ["grafana"])

    let triaged = try sbd.client.call("triage", as: [SessionSummary].self)
    let item = try #require(triaged.first { $0.id == c.id }?.triage)
    #expect(item.title == "Add grafana to this conversation")
    #expect(item.options.map(\.action) == [.allow, .deny])
  }

  @Test func sbCardsPrintsTheRequestTheReasonEscapedAndWhatAllowDoes() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"], reason: "Read the \u{1B}[2K dashboards.")

    let text = try sbd.sb("cards", c.id)

    #expect(text.contains(String(status.card)), "\(text)")
    #expect(text.contains("add grafana to this conversation"), "\(text)")
    #expect(text.contains("Read the \\u{1b}[2K dashboards."), "\(text)")
    #expect(!text.contains("\u{1B}"), "\(text)")
    #expect(text.contains("allow restarts claude with it, deny leaves the servers as they are"), "\(text)")
  }

  // MARK: Who may ask

  /// The `session` of a request that does not name a Manager conversation.
  enum Asker: CaseIterable { case missing, empty, unknown, work, chat, operatorById, operatorByName }

  /// The session that the request names, or nil when it names none, with the id to check for events.
  func asker(_ sbd: Instance, _ who: Asker) throws -> (ref: String?, id: String?) {
    switch who {
    case .missing: return (nil, nil)
    case .empty: return ("", nil)
    case .unknown: return ("snope1", nil)
    case .work:
      let s = try sbd.new(prompt: "hello", name: "work")
      try sbd.waitFor(s.id, "the work session's reply") { $0.lastReply == "Done: hello" }
      return (s.id, s.id)
    case .chat:
      _ = try conv.decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
      let id = try #require(
        try conv.decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))["id"]?.string)
      try sbd.waitFor(id, "the chat's reply") { $0.lastReply == "Done: hello" }
      return (id, id)
    case .operatorById:
      let op = try OperatorTests().openOperator(sbd)
      return (op.id, op.id)
    case .operatorByName:
      let op = try OperatorTests().openOperator(sbd)
      return (Manager.operatorName, op.id)
    }
  }

  @Test(arguments: Asker.allCases) func aRequestThatNamesNoManagerConversationIsRefused(_ who: Asker) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let (ref, id) = try asker(sbd, who)
    var args: [String: JSON] = ["servers": ["grafana"], "reason": .string(Self.reason)]
    if let ref { args["session"] = .string(ref) }

    let error = failure(sbd, "manager-mcp-request", args)

    #expect(error != "no error")
    #expect(try sbd.cards().isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
    if let id { #expect(try requested(sbd, id).isEmpty) }
  }

  @Test(arguments: Asker.allCases) func anAllRequestThatNamesNoManagerConversationIsRefused(_ who: Asker) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let (ref, id) = try asker(sbd, who)
    var args: [String: JSON] = ["all": true, "reason": .string(Self.reason)]
    if let ref { args["session"] = .string(ref) }

    let error = failure(sbd, "manager-mcp-request", args)

    #expect(error != "no error")
    #expect(try sbd.cards().isEmpty)
    if let id { #expect(try requested(sbd, id).isEmpty) }
  }

  // MARK: Arguments

  /// Arguments that break a rule of Decision 7 before any name is checked.
  enum BadArgs: CaseIterable {
    case serversAndAll, neither, allFalse, emptyServers, emptyServersAndAllFalse, missingReason, emptyReason,
      whitespaceReason, reasonNotAString

    var args: [String: JSON] {
      switch self {
      case .serversAndAll: ["servers": ["grafana"], "all": true, "reason": "Check."]
      case .neither: ["reason": "Check."]
      case .allFalse: ["all": false, "reason": "Check."]
      case .emptyServers: ["servers": [], "reason": "Check."]
      case .emptyServersAndAllFalse: ["servers": [], "all": false, "reason": "Check."]
      case .missingReason: ["servers": ["grafana"]]
      case .emptyReason: ["servers": ["grafana"], "reason": ""]
      case .whitespaceReason: ["servers": ["grafana"], "reason": "  \n\t  "]
      case .reasonNotAString: ["servers": ["grafana"], "reason": 42]
      }
    }
  }

  @Test(arguments: BadArgs.allCases) func aRequestWithBadArgumentsIsRefusedAndOpensNoCard(_ bad: BadArgs) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let error = failure(sbd, "manager-mcp-request", bad.args.merging(["session": .string(c.id)]) { $1 })

    #expect(error != "no error")
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  /// Claude often sends `all: false` next to the names it wants.
  @Test func serversWithAllFalseOpenACard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try request(
      sbd, ["session": .string(c.id), "servers": ["grafana"], "all": false, "reason": .string(Self.reason)])

    #expect(status.servers == ["grafana"])
    #expect(try cards(sbd, c).map(\.id) == [status.card])
  }

  @Test func aLongReasonWithANewlineIsStoredAsOneLineOfAtMost200Characters() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let long = String(repeating: "a", count: 250) + "\n" + String(repeating: "b", count: 249)
    try #require(long.count == 500)

    let status = try ask(sbd, c, ["grafana"], reason: long)

    let newlines = status.reason.filter(\.isNewline)
    #expect(newlines.isEmpty, "\(status.reason)")
    #expect(status.reason.count <= TriageCard.lineLength, "\(status.reason.count)")
    #expect(status.reason.hasPrefix("aaaa"))
    #expect(try cards(sbd, c).first?.mcpRequest?.reason == status.reason)
    #expect(try requested(sbd, c.id).first?.data["reason"]?.string == status.reason)
  }

  @Test func theReasonIsTrimmed() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try ask(sbd, c, ["grafana"], reason: "  \n Read the dashboards.  \n")

    #expect(status.reason == "Read the dashboards.")
  }

  // MARK: Names

  @Test func anUnknownNameIsRefusedWithEveryServerAndTheConnectorHint() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.addUserServers(try conv.accountFolder(sbd, c), ["notes": ManagerConversationsTests.userServer])

    let error = failure(
      sbd, "manager-mcp-request", ["session": .string(c.id), "servers": ["nosuch"], "reason": .string(Self.reason)])

    #expect(error.contains("no MCP server named nosuch"), Comment(rawValue: error))
    for name in ["grafana", "posthog-db", "notes"] { #expect(error.contains(name), Comment(rawValue: error)) }
    #expect(error.contains("A claude.ai connector such as Slack needs all."), Comment(rawValue: error))
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  /// A name that `sb manager mcp add` refuses gives the same text from the request, with one more sentence.
  @Test func theUnknownNameTextMatchesSbManagerMCPAdd() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let cli = try sbd.run(["manager", "mcp", c.id, "add", "nosuch"])
    try #require(cli.status != 0)
    let cliText = cli.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let core = try #require(cliText.range(of: "no MCP server named nosuch").map { String(cliText[$0.lowerBound...]) })

    let error = failure(
      sbd, "manager-mcp-request", ["session": .string(c.id), "servers": ["nosuch"], "reason": .string(Self.reason)])

    #expect(error.contains(core), "\(error) vs \(core)")
  }

  @Test func switchboardIsRefusedEvenWhenAConfigListsIt() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.addUserServers(try conv.accountFolder(sbd, c), ["switchboard": ManagerConversationsTests.userServer])

    let error = failure(
      sbd, "manager-mcp-request",
      ["session": .string(c.id), "servers": ["switchboard"], "reason": .string(Self.reason)])

    #expect(error.contains("no MCP server named switchboard"), Comment(rawValue: error))
    #expect(try cards(sbd, c).isEmpty)
  }

  @Test func oneUnknownNameAmongKnownOnesOpensNoCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let error = failure(
      sbd, "manager-mcp-request",
      ["session": .string(c.id), "servers": ["grafana", "nosuch"], "reason": .string(Self.reason)])

    #expect(error.contains("nosuch"), Comment(rawValue: error))
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  @Test func aUserScopeServerCanBeRequested() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.addUserServers(try conv.accountFolder(sbd, c), ["notes": ManagerConversationsTests.userServer])

    let status = try ask(sbd, c, ["notes"])

    #expect(status.servers == ["notes"])
  }

  @Test func repeatedNamesCollapseToOneAndKeepTheirOrder() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)

    let status = try ask(sbd, c, ["posthog-db", "grafana", "posthog-db", "grafana"])

    #expect(status.servers == ["posthog-db", "grafana"])
    #expect(try cards(sbd, c).first?.mcpRequest?.servers == ["posthog-db", "grafana"])
  }

  // MARK: Servers the conversation already loads

  /// What the request asks for.
  enum Asked: CaseIterable { case names, all }

  @Test(arguments: Asked.allCases) func aConversationOnTheFullSetupIsRefused(_ asked: Asked) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.changeServers(sbd, c, "--all")
    var args: [String: JSON] = ["session": .string(c.id), "reason": .string(Self.reason)]
    switch asked {
    case .names: args["servers"] = ["grafana"]
    case .all: args["all"] = true
    }

    let error = failure(sbd, "manager-mcp-request", args)

    #expect(error.contains("\(c.name) already loads every MCP server."), Comment(rawValue: error))
    #expect(try cards(sbd, c).isEmpty)
    #expect(try requested(sbd, c.id).isEmpty)
  }

  @Test func aRequestForOnlyLoadedServersIsRefused() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.changeServers(sbd, c, "add", "grafana")

    let error = failure(
      sbd, "manager-mcp-request", ["session": .string(c.id), "servers": ["grafana"], "reason": .string(Self.reason)])

    #expect(error.contains("\(c.name) already loads grafana."), Comment(rawValue: error))
    #expect(try cards(sbd, c).isEmpty)
  }

  @Test func aLoadedServerIsDroppedFromTheRequest() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try conv.changeServers(sbd, c, "add", "grafana")

    let status = try ask(sbd, c, ["grafana", "posthog-db"])

    #expect(status.servers == ["posthog-db"])
    #expect(try cards(sbd, c).first?.mcpRequest?.servers == ["posthog-db"])
    #expect(try cards(sbd, c).first?.reason == "add posthog-db to this conversation")
  }

  // MARK: One open request

  @Test(arguments: Asked.allCases) func aSecondRequestWhileOneIsOpenIsRefusedAndNamesTheCard(_ second: Asked) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let first = try ask(sbd, c, ["grafana"])
    var args: [String: JSON] = ["session": .string(c.id), "reason": .string(Self.reason)]
    switch second {
    case .names: args["servers"] = ["posthog-db"]
    case .all: args["all"] = true
    }

    let error = failure(sbd, "manager-mcp-request", args)

    #expect(
      error.contains("a request to add grafana to this conversation already waits for the user"),
      Comment(rawValue: error))
    #expect(error.contains("(card \(first.card))"), Comment(rawValue: error))
    #expect(try cards(sbd, c).map(\.id) == [first.card])
    #expect(try requested(sbd, c.id).count == 1)
  }

  @Test func aNewRequestOpensOnceTheFirstIsDenied() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let first = try ask(sbd, c, ["grafana"])
    try decide(sbd, .cli, c, first.card, allow: false)

    let second = try ask(sbd, c, ["posthog-db"])

    #expect(second.card != first.card)
    #expect(try cards(sbd, c).map(\.id) == [second.card])
  }

  @Test func anOpenRequestOnOneConversationLeavesAnotherFreeToAsk() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let a = try conv.idleConversation(sbd, name: "a")
    let b = try conv.idleConversation(sbd, name: "b")
    _ = try ask(sbd, a, ["grafana"])

    let other = try ask(sbd, b, ["grafana"])

    #expect(try cards(sbd, b).map(\.id) == [other.card])
  }

  // MARK: Allow

  @Test(arguments: Decider.allCases) func allowRelaunchesWithTheServerAndResumes(_ how: Decider) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    _ = try sbd.waitForRunning("grafana")
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let args = try allowAndRelaunch(sbd, c, status.card, by: how)

    #expect(args.contains("--strict-mcp-config"))
    #expect(conv.serverNames(args) == ["grafana", "switchboard"])
    #expect(conv.entry(args, "grafana") == (try conv.sharedEntry(sbd, "grafana")))
    #expect(try servers(sbd, c) == ["grafana"])
  }

  @Test(arguments: Decider.allCases) func allowClosesTheCardAndRecordsAllowed(_ how: Decider) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    try decide(sbd, how, c, status.card, allow: true)

    #expect(try cards(sbd, c).isEmpty)
    let events = try decided(sbd, c)
    #expect(events.count == 1)
    #expect(events.first?.data["card"]?.int == Int(status.card))
    #expect(events.first?.data["decision"]?.string == "allowed")
    #expect(events.first?.data["servers"] == ["grafana"])
  }

  @Test func allowRecordsTheSameMCPEventAsSbManagerMCP() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    try decide(sbd, .cli, c, status.card, allow: true)

    #expect(try sbd.events(c.id, kind: "mcp").last?.data["servers"] == ["grafana"])
  }

  @Test func theAppsAllowAnswersTheStatusWithAllowed() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let answer = try sbd.client.call(
      "answer", ["session": .string(c.id), "card": .number(Double(status.card)), "behavior": "allow"],
      as: MCPServerRequestStatus.self)

    #expect(answer.card == status.card)
    #expect(answer.session == c.id)
    #expect(answer.decision == .allowed)
    #expect(answer.servers == ["grafana"])
  }

  @Test func sbAllowPrintsTheDecisionAndTheConversationsServers() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let text = try sbd.sb("allow", c.id, "--card", String(status.card))

    #expect(text.contains("allowed"), "\(text)")
    #expect(text.contains(Manager.serversText(["grafana"])), "\(text)")
  }

  @Test func sbAllowJSONPrintsTheStatus() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let printed = try conv.decode(
      MCPServerRequestStatus.self, sbd.sb("allow", c.id, "--card", String(status.card), "--json"))

    #expect(printed.card == status.card)
    #expect(printed.decision == .allowed)
  }

  @Test func allowOfAnAllRequestLaunchesWithTheFullSetup() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try askAll(sbd, c)

    let args = try allowAndRelaunch(sbd, c, status.card)

    #expect(!args.contains("--strict-mcp-config"))
    #expect(args.contains(sbd.home.mcpConfig))
    #expect(try servers(sbd, c) == .null)
    #expect(try decided(sbd, c).first?.data["servers"] == .null)
  }

  /// Decision 11: nothing is pasted or sent to the conversation on Allow or Deny.
  @Test(arguments: [true, false]) func aDecisionSendsTheConversationNothing(allow: Bool) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let before = try sent(sbd, c.id)
    let status = try ask(sbd, c, ["grafana"])

    if allow {
      try allowAndRelaunch(sbd, c, status.card)
    } else {
      try decide(sbd, .cli, c, status.card, allow: false)
    }

    Thread.sleep(forTimeInterval: 1)
    #expect(try sent(sbd, c.id) == before)
  }

  @Test func allowDuringARunningTurnRelaunchesOnlyAfterTheTurnEnds() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    try sbd.sb("send", c.id, "slow 4")
    try sbd.waitFor(c.id, "the slow turn") { $0.state == .working }
    // Claude calls the tool during its turn.
    let status = try ask(sbd, c, ["grafana"])
    let before = conv.launches(sbd, c).count

    try decide(sbd, .cli, c, status.card, allow: true)

    expectNoLaunch(sbd, c, since: before)
    try sbd.waitFor(c.id, "the end of the slow turn", timeout: 30) { $0.lastReply == "Slept 4 s." }
    let launched = try conv.launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "))
    #expect(conv.serverNames(try conv.scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  @Test func theCardSurvivesTheNextTurn() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    try sbd.sb("send", c.id, "Carry on.")
    try sbd.waitFor(c.id, "the next reply") { $0.lastReply == "Done: Carry on." }

    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try sbd.get(c.id).state == .needsYou)
  }

  @Test func theCardSurvivesSbStopAndAllowAppliesAtTheNextLaunch() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    try sbd.stopClaude(c.id)
    try #require(try cards(sbd, c).map(\.id) == [status.card])
    let before = conv.launches(sbd, c).count

    try decide(sbd, .cli, c, status.card, allow: true)
    _ = try sbd.sb("manager", c.id, "--json")

    let launched = try conv.launch(sbd, c, after: before)
    #expect(launched.hasPrefix("--resume \(c.claudeSessionId) "))
    #expect(conv.serverNames(try conv.scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  /// Decision 15: the idle stop ignores the card, and Allow applies at the next launch.
  @Test func theCardSurvivesTheIdleStopAndAllowAppliesAtTheNextLaunch() throws {
    let sbd = try Instance(idleStopSeconds: 2, config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    try sbd.waitFor(c.id, "the idle stop", timeout: 15) { !$0.live }

    #expect(try cards(sbd, c).map(\.id) == [status.card])
    let before = conv.launches(sbd, c).count
    try decide(sbd, .cli, c, status.card, allow: true)
    _ = try sbd.sb("manager", c.id, "--json")
    _ = try conv.launch(sbd, c, after: before)
    #expect(conv.serverNames(try conv.scriptArgs(sbd, c.id)) == ["grafana", "switchboard"])
  }

  @Test func theCardSurvivesARestartOfSbdAndAllowStillApplies() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try cards(sbd, c).map(\.id) == [status.card])
    try decide(sbd, .cli, c, status.card, allow: true)
    #expect(try servers(sbd, c) == ["grafana"])
    #expect(try cards(sbd, c).isEmpty)
  }

  @Test(arguments: [true, false], [true, false]) func aSecondDecisionIsRefused(first: Bool, second: Bool) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    try decide(sbd, .cli, c, status.card, allow: first)

    for how in Decider.allCases {
      #expect(throws: (any Error).self) { try decide(sbd, how, c, status.card, allow: second) }
    }

    let expected: JSON = first ? ["grafana"] : []
    #expect(try decided(sbd, c).count == 1)
    #expect(try servers(sbd, c) == expected)
  }

  // MARK: Allow re-validates

  @Test func allowAfterTheUserSwitchedToTheFullSetupClosesTheCardWithoutARelaunch() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    try conv.changeServers(sbd, c, "--all")
    let before = conv.launches(sbd, c).count

    try decide(sbd, .cli, c, status.card, allow: true)

    #expect(try cards(sbd, c).isEmpty)
    #expect(try decided(sbd, c).first?.data["decision"]?.string == "allowed")
    expectNoLaunch(sbd, c, since: before)
    #expect(try servers(sbd, c) == .null)
  }

  @Test func allowAfterTheUserAddedTheServerClosesTheCardWithoutARelaunch() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    try conv.changeServers(sbd, c, "add", "grafana")
    let before = conv.launches(sbd, c).count

    try decide(sbd, .cli, c, status.card, allow: true)

    #expect(try cards(sbd, c).isEmpty)
    #expect(try decided(sbd, c).first?.data["decision"]?.string == "allowed")
    expectNoLaunch(sbd, c, since: before)
    #expect(try servers(sbd, c) == ["grafana"])
  }

  @Test func allowAfterTheUserAddedOneOfTwoServersAddsTheOther() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana", "posthog-db"])
    try conv.changeServers(sbd, c, "add", "grafana")

    let args = try allowAndRelaunch(sbd, c, status.card)

    #expect(conv.serverNames(args) == ["grafana", "posthog-db", "switchboard"])
    #expect(try servers(sbd, c) == ["grafana", "posthog-db"])
  }

  @Test func allowOfAnAllRequestAfterTheUserAddedAServerAppliesTheFullSetup() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try askAll(sbd, c)
    try conv.changeServers(sbd, c, "add", "grafana")

    let args = try allowAndRelaunch(sbd, c, status.card)

    #expect(!args.contains("--strict-mcp-config"))
    #expect(try servers(sbd, c) == .null)
  }

  /// Decision 9: a refused Allow records nothing and leaves the card open, so the user can still deny it.
  @Test func allowOfAServerRemovedFromConfigIsRefusedAndLeavesTheCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let folder = try conv.accountFolder(sbd, c)
    try conv.addUserServers(folder, ["notes": ManagerConversationsTests.userServer])
    let status = try ask(sbd, c, ["notes"])
    let path = "\(folder)/.claude.json"
    var config = try #require(JSON.parse(try String(contentsOfFile: path, encoding: .utf8))?.object)
    config["mcpServers"] = [:]
    try JSON.object(config).text.write(toFile: path, atomically: true, encoding: .utf8)
    let before = conv.launches(sbd, c).count
    let changes = try sbd.events(c.id, kind: "mcp").count

    let refused = try sbd.run(["allow", c.id, "--card", String(status.card)])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("no MCP server named notes"), "\(refused.stderr)")
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try decided(sbd, c).isEmpty)
    #expect(try sbd.events(c.id, kind: "mcp").count == changes)
    #expect(try servers(sbd, c) == [])
    expectNoLaunch(sbd, c, since: before)
    try decide(sbd, .cli, c, status.card, allow: false)
    #expect(try cards(sbd, c).isEmpty)
  }

  // MARK: Parity with sb manager mcp

  /// A request and the `sb manager mcp` change that must give the same result.
  enum ParityCase: CaseIterable {
    case add, addOverLoaded, all, userServer

    /// The servers that the request names, or nil for `all`.
    var requested: [String]? {
      switch self {
      case .add: ["grafana"]
      case .addOverLoaded: ["grafana", "posthog-db"]
      case .all: nil
      case .userServer: ["notes"]
      }
    }
    /// The arguments of the matching `sb manager mcp` change.
    var cli: [String] {
      switch self {
      case .add: ["add", "grafana"]
      case .addOverLoaded: ["add", "grafana", "posthog-db"]
      case .all: ["--all"]
      case .userServer: ["add", "notes"]
      }
    }
  }

  /// Whether claude runs when the change arrives.
  enum ClaudeRuns: CaseIterable { case idle, stopped }

  @Test(arguments: ParityCase.allCases, ClaudeRuns.allCases)
  func allowGivesTheSameLaunchAndListAsSbManagerMCP(_ shape: ParityCase, _ runs: ClaudeRuns) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    _ = try sbd.waitForRunning("grafana")
    _ = try sbd.waitForRunning("posthog-db")
    let byCard = try conv.idleConversation(sbd, name: "by card")
    let byCLI = try conv.idleConversation(sbd, name: "by cli")
    if shape == .userServer {
      try conv.addUserServers(try conv.accountFolder(sbd, byCard), ["notes": ManagerConversationsTests.userServer])
    }
    if shape == .addOverLoaded { for c in [byCard, byCLI] { try conv.changeServers(sbd, c, "add", "grafana") } }
    if runs == .stopped { for c in [byCard, byCLI] { try sbd.stopClaude(c.id) } }
    let status = try shape.requested.map { try ask(sbd, byCard, $0) } ?? askAll(sbd, byCard)
    let beforeCard = conv.launches(sbd, byCard).count
    let beforeCLI = conv.launches(sbd, byCLI).count

    try sbd.sb("allow", byCard.id, "--card", String(status.card))
    try sbd.sb(["manager", "mcp", byCLI.id] + shape.cli)
    if runs == .stopped { for c in [byCard, byCLI] { _ = try sbd.sb("manager", c.id, "--json") } }
    try conv.launch(sbd, byCard, after: beforeCard)
    try conv.launch(sbd, byCLI, after: beforeCLI)

    let cardArgs = try conv.scriptArgs(sbd, byCard.id)
    let cliArgs = try conv.scriptArgs(sbd, byCLI.id)
    #expect(conv.serverNames(cardArgs) == conv.serverNames(cliArgs))
    #expect(cardArgs.contains("--strict-mcp-config") == cliArgs.contains("--strict-mcp-config"))
    #expect(cardArgs.contains(sbd.home.mcpConfig) == cliArgs.contains(sbd.home.mcpConfig))
    for name in conv.serverNames(cardArgs) where name != "switchboard" {
      #expect(conv.entry(cardArgs, name) == conv.entry(cliArgs, name), "\(name)")
    }
    #expect(try servers(sbd, byCard) == (try servers(sbd, byCLI)))
    let cardEvent = try sbd.events(byCard.id, kind: "mcp").last?.data["servers"]
    let cliEvent = try sbd.events(byCLI.id, kind: "mcp").last?.data["servers"]
    #expect(cardEvent != nil)
    #expect(cardEvent == cliEvent)
  }

  // MARK: Deny

  @Test(arguments: Decider.allCases) func denyClosesTheCardAndRecordsDenied(_ how: Decider) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    try decide(sbd, how, c, status.card, allow: false)

    #expect(try cards(sbd, c).isEmpty)
    let events = try decided(sbd, c)
    #expect(events.count == 1)
    #expect(events.first?.data["card"]?.int == Int(status.card))
    #expect(events.first?.data["decision"]?.string == "denied")
    #expect(events.first?.data["servers"] == [])
  }

  @Test(arguments: Decider.allCases) func denyLeavesTheServersAndClaudeAlone(_ how: Decider) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    let script = try conv.scriptArgs(sbd, c.id)
    let before = conv.launches(sbd, c).count
    let changes = try sbd.events(c.id, kind: "mcp").count

    try decide(sbd, how, c, status.card, allow: false)

    expectNoLaunch(sbd, c, since: before)
    #expect(try conv.scriptArgs(sbd, c.id) == script)
    #expect(try servers(sbd, c) == [])
    #expect(try sbd.get(c.id).live)
    #expect(try sbd.events(c.id, kind: "mcp").count == changes)
  }

  @Test func denyOfAnAllRequestLeavesTheSwitchboardServerOnly() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try askAll(sbd, c)

    try decide(sbd, .cli, c, status.card, allow: false)

    #expect(try servers(sbd, c) == [])
    try conv.requireSwitchboardOnly(sbd, c.id)
  }

  @Test func aDenyMessageIsIgnored() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let before = try sent(sbd, c.id)
    let status = try ask(sbd, c, ["grafana"])

    try sbd.sb("deny", c.id, "--card", String(status.card), "Use", "curl", "instead.")

    #expect(try cards(sbd, c).isEmpty)
    #expect(try decided(sbd, c).first?.data["decision"]?.string == "denied")
    Thread.sleep(forTimeInterval: 1)
    #expect(try sent(sbd, c.id) == before)
  }

  @Test func theAppsDenyAnswersTheStatusWithDenied() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let answer = try sbd.client.call(
      "answer", ["session": .string(c.id), "card": .number(Double(status.card)), "behavior": "deny"],
      as: MCPServerRequestStatus.self)

    #expect(answer.card == status.card)
    #expect(answer.decision == .denied)
  }

  @Test func sbDenyPrintsTheDecisionAndTheConversationsServers() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let text = try sbd.sb("deny", c.id, "--card", String(status.card))

    #expect(text.contains("denied"), "\(text)")
    #expect(text.contains(Manager.serversText([])), "\(text)")
  }

  // MARK: Other answers

  @Test func anAnswerWithAnswersIsRefusedAndLeavesTheCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let error = failure(
      sbd, "answer", ["session": .string(c.id), "card": .number(Double(status.card)), "answers": ["yes"]])

    #expect(error.contains("card \(status.card) asks to add an MCP server"), Comment(rawValue: error))
    #expect(error.contains("Allow it or deny it"), Comment(rawValue: error))
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try servers(sbd, c) == [])
  }

  @Test func sbAnswerIsRefusedAndLeavesTheCard() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])

    let r = try sbd.run(["answer", c.id, "--card", String(status.card), "Allow"])

    #expect(r.status != 0)
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try decided(sbd, c).isEmpty)
  }

  @Test(arguments: AllowExtra.allCases) func allowWithAnExtraIsRefusedAndLeavesTheCard(_ extra: AllowExtra) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    let before = conv.launches(sbd, c).count

    let r = try sbd.run(["allow", c.id, "--card", String(status.card), extra.flag])

    #expect(r.status != 0)
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try servers(sbd, c) == [])
    expectNoLaunch(sbd, c, since: before)
  }

  @Test func chooseAllowOutsideClaudeAppliesTheRequest() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    _ = try ask(sbd, c, ["grafana"])
    let before = conv.launches(sbd, c).count

    try sbd.sb("choose", c.id, "Allow")

    _ = try conv.launch(sbd, c, after: before)
    #expect(try servers(sbd, c) == ["grafana"])
    #expect(try cards(sbd, c).isEmpty)
  }

  // MARK: Inside Claude Code (Risk 1)

  /// The SB_SESSION_ID of a command that runs inside Claude Code with CLAUDECODE set.
  enum InsideAs: CaseIterable { case theConversation, anotherSession, noSession }

  func env(_ sbd: Instance, _ c: SessionSummary, _ who: InsideAs) throws -> [String: String] {
    switch who {
    case .theConversation: return inside(c.id)
    case .anotherSession: return inside(try sbd.new(name: "other").id)
    case .noSession: return ["CLAUDECODE": "1"]
    }
  }

  @Test(arguments: [true, false], InsideAs.allCases)
  func aDecisionInsideClaudeIsRefusedAndLeavesTheCard(allow: Bool, _ who: InsideAs) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    let environment = try env(sbd, c, who)
    let before = conv.launches(sbd, c).count

    let r = try sbd.run([allow ? "allow" : "deny", c.id, "--card", String(status.card)], env: environment)

    #expect(r.status != 0)
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try decided(sbd, c).isEmpty)
    #expect(try servers(sbd, c) == [])
    expectNoLaunch(sbd, c, since: before)
  }

  @Test(arguments: InsideAs.allCases) func chooseAllowInsideClaudeIsRefusedAndLeavesTheCard(_ who: InsideAs) throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    let c = try conv.idleConversation(sbd)
    let status = try ask(sbd, c, ["grafana"])
    let environment = try env(sbd, c, who)

    let r = try sbd.run(["choose", c.id, "Allow"], env: environment)

    #expect(r.status != 0)
    #expect(try cards(sbd, c).map(\.id) == [status.card])
    #expect(try servers(sbd, c) == [])
  }
}
