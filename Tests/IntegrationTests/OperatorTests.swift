import Foundation
import SwitchboardCore
import Testing

/// The operator: one background Manager session of kind `operator` in the
/// Manager folder. sbd creates it on demand. It launches with the switchboard
/// server only and with its role prompt appended. Conversation lookups leave
/// it out, `done` is refused on it, and `rm` is refused while it has an open wait.
@Suite(.blocking(timeLimit: .seconds(120))) struct OperatorTests {
  let conversationHelpers = ManagerConversationsTests()

  static let triagePrompt = "Ask with AskUserQuestion."

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// Runs `sb operator --json`, which opens the operator and creates it when none exists.
  func openOperator(_ sbd: Instance) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("operator", "--json"))
  }

  /// An operator whose turn for `text` has ended.
  func idleOperator(_ sbd: Instance, _ text: String = "hello") throws -> SessionSummary {
    let op = try openOperator(sbd)
    try sbd.waitFor(op.id, "the operator's claude") { $0.live }
    try sbd.sb("operator", text)
    return try sbd.waitFor(op.id, "the operator's reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  func operators(_ sbd: Instance) throws -> [SessionSummary] {
    try sbd.client.call("ls", as: [SessionSummary].self).filter { $0.kind == .operator }
  }

  /// The value of each `--append-system-prompt` in the session's claude.sh.
  func appendedPrompts(_ sbd: Instance, _ id: String) throws -> [String] {
    let args = try conversationHelpers.scriptArgs(sbd, id)
    return args.indices.dropLast().filter { args[$0] == "--append-system-prompt" }.map { args[$0 + 1] }
  }

  // MARK: Creation

  @Test func operatorCreatesOneOperatorSessionInTheManagerFolderWithSwitchboardOnly() throws {
    let sbd = try Instance()

    let op = try openOperator(sbd)

    #expect(op.kind == .operator)
    #expect(op.manager == true)
    #expect(op.name == Manager.operatorName)
    #expect(op.name == "Operator")
    #expect(op.cwd == sbd.home.managerFolder)
    #expect(op.mcp == [])
  }

  @Test func operatorOpensTheSameSessionAfterThat() throws {
    let sbd = try Instance()
    let first = try openOperator(sbd)
    try sbd.waitFor(first.id, "the operator's claude") { $0.live }

    let second = try openOperator(sbd)

    #expect(second.id == first.id)
    #expect(try operators(sbd).map(\.id) == [first.id])
  }

  @Test func operatorResumesAStoppedOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try sbd.stopClaude(op.id)
    let before = conversationHelpers.launches(sbd, op).count

    let opened = try openOperator(sbd)

    #expect(opened.id == op.id)
    let launched = try conversationHelpers.launch(sbd, op, after: before)
    #expect(launched.hasPrefix("--resume \(op.claudeSessionId) "), "\(launched)")
  }

  @Test func aWaitOnANewOperatorIsAccepted() throws {
    let sbd = try Instance()
    let op = try openOperator(sbd)

    let waiting = try decode(
      SessionSummary.self, sbd.sb("wait", "--json", op.id, "--kind", "manual", "--note", "check the queue"))

    #expect(waiting.id == op.id)
    #expect(waiting.waits.map(\.kind) == [.manual])
  }

  // MARK: Launch arguments

  @Test func theOperatorLaunchesWithStrictMCPConfigAndTheSwitchboardServerOnly() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)

    let op = try idleOperator(sbd)

    let args = try conversationHelpers.scriptArgs(sbd, op.id)
    #expect(args.contains("--strict-mcp-config"), "\(args)")
    #expect(!args.contains(sbd.home.mcpConfig), "\(args)")
    #expect(conversationHelpers.serverNames(args) == ["switchboard"], "\(args)")
  }

  @Test func theOperatorsAppendedPromptIsItsRolePromptThenTheTriagePrompt() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": .string(Self.triagePrompt)]])

    let op = try idleOperator(sbd)

    let prompts = try appendedPrompts(sbd, op.id)
    #expect(prompts == [Manager.operatorPrompt + "\n\n" + Self.triagePrompt], "\(prompts)")
  }

  @Test func theOperatorsAppendedPromptIsItsRolePromptAloneWhenTheTriagePromptIsEmpty() throws {
    let sbd = try Instance()

    let op = try idleOperator(sbd)

    #expect(try appendedPrompts(sbd, op.id) == [Manager.operatorPrompt])
  }

  @Test func theOperatorKeepsItsRolePromptWhenItResumes() throws {
    let sbd = try Instance(config: ["triage": ["systemPrompt": .string(Self.triagePrompt)]])
    let op = try idleOperator(sbd)
    try sbd.stopClaude(op.id)
    let before = conversationHelpers.launches(sbd, op).count

    _ = try openOperator(sbd)
    let launched = try conversationHelpers.launch(sbd, op, after: before)

    #expect(launched.hasPrefix("--resume \(op.claudeSessionId) "), "\(launched)")
    #expect(try appendedPrompts(sbd, op.id) == [Manager.operatorPrompt + "\n\n" + Self.triagePrompt])
  }

  /// A session that is not the operator.
  enum OtherKind: CaseIterable { case work, conversation, chat }

  func otherSession(_ sbd: Instance, _ kind: OtherKind) throws -> SessionSummary {
    let s: SessionSummary
    switch kind {
    case .work:
      s = try sbd.new(prompt: "hello", name: "work")
    case .conversation:
      s = try conversationHelpers.newConversation(sbd, "hello")
    case .chat:
      _ = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "Flags"))
      let id = try #require(try decode(JSON.self, sbd.sb("chat", "Flags", "--send", "hello", "--json"))["id"]?.string)
      s = try sbd.get(id)
    }
    return try sbd.waitFor(s.id, "the reply of \(kind)", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  /// Risk 8: the operator's branch changes no other session's launch.
  @Test(arguments: OtherKind.allCases, [true, false])
  func anotherSessionsAppendedPromptIsTheTriagePromptOnly(_ kind: OtherKind, _ triageSet: Bool) throws {
    let sbd = try Instance(config: triageSet ? ["triage": ["systemPrompt": .string(Self.triagePrompt)]] : [:])
    _ = try idleOperator(sbd)

    let s = try otherSession(sbd, kind)

    let prompts = try appendedPrompts(sbd, s.id)
    #expect(prompts == (triageSet ? [Self.triagePrompt] : []), "\(prompts)")
    let args = try conversationHelpers.scriptArgs(sbd, s.id)
    #expect(!args.contains { $0.contains(Manager.operatorPrompt) }, "\(args)")
  }

  // MARK: Conversation lookups leave the operator out (Risk 3)

  /// A conversation whose turn ended, and then an operator whose turn ended later.
  func conversationThenNewerOperator(_ sbd: Instance) throws -> (conversation: SessionSummary, op: SessionSummary) {
    let conversation = try conversationHelpers.idleConversation(sbd, name: "Cache work", "hello")
    let op = try idleOperator(sbd, "later")
    let newer = try sbd.get(op.id).lastActivity
    let older = try sbd.get(conversation.id).lastActivity
    try #require(newer > older, "the operator's activity \(newer) is not newer than \(older)")
    return (conversation, op)
  }

  @Test func managerLsLeavesOutAnOperatorWithTheNewestActivity() throws {
    let sbd = try Instance()
    let (conversation, _) = try conversationThenNewerOperator(sbd)

    let listed = try conversationHelpers.conversations(sbd)

    #expect(listed.map(\.id) == [conversation.id])
  }

  @Test func bareManagerOpensTheNewestConversationAndNotTheNewerOperator() throws {
    let sbd = try Instance()
    let (conversation, _) = try conversationThenNewerOperator(sbd)

    let opened = try decode(SessionSummary.self, sbd.sb("manager", "--json"))

    #expect(opened.id == conversation.id)
  }

  @Test func bareManagerWithOnlyAnOperatorStartsAConversation() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    let opened = try decode(SessionSummary.self, sbd.sb("manager", "--json"))

    #expect(opened.id != op.id)
    #expect(opened.kind == .manager)
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  /// How a command names the operator.
  enum Ref: CaseIterable { case name, id, idPrefix }

  func ref(_ s: SessionSummary, _ how: Ref) -> String {
    switch how {
    case .name: s.name
    case .id: s.id
    case .idPrefix: String(s.id.prefix(s.id.count - 1))
    }
  }

  @Test(arguments: Ref.allCases) func managerNamingTheOperatorFailsAsNoConversation(_ how: Ref) throws {
    let sbd = try Instance()
    let (_, op) = try conversationThenNewerOperator(sbd)
    let sent = try sbd.events(op.id).filter { $0.kind == "sent" }.count

    let refused = try sbd.run(["manager", ref(op, how), "are you there"])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("no Manager conversation"), "\(refused.stderr)")
    #expect(try sbd.events(op.id).filter { $0.kind == "sent" }.count == sent)
  }

  @Test func aNewConversationsStartDigestLeavesOutTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let work = try sbd.new(prompt: "hello", name: "work")
    try sbd.waitFor(work.id, "the work session's reply") { $0.lastReply == "Done: hello" }

    let conversation = try conversationHelpers.newConversation(sbd)

    let text = try conversationHelpers.startDigest(sbd, conversation)
    #expect(text.contains(work.id), "\(text)")
    #expect(!text.contains(op.id), "\(text)")
  }

  // MARK: The operator's start digest

  @Test func theOperatorsFirstStartGetsADigestWithoutTheConversationsOrItself() throws {
    let sbd = try Instance()
    let work = try sbd.new(prompt: "hello", name: "work")
    try sbd.waitFor(work.id, "the work session's reply") { $0.lastReply == "Done: hello" }
    let conversation = try conversationHelpers.idleConversation(sbd, name: "Cache work", "hello")

    let op = try openOperator(sbd)

    let text = try conversationHelpers.startDigest(sbd, op)
    #expect(text.contains(work.id), "\(text)")
    #expect(!text.contains(conversation.id), "\(text)")
    #expect(!text.contains(op.id), "\(text)")
    #expect(conversationHelpers.startContexts(sbd, op).count == 1)
  }

  @Test func aResumedOperatorGetsNoStartDigest() throws {
    let sbd = try Instance()
    _ = try sbd.new(prompt: "hello", name: "work")
    let op = try idleOperator(sbd)
    _ = try conversationHelpers.startDigest(sbd, op)
    try sbd.stopClaude(op.id)

    _ = try openOperator(sbd)

    try sbd.waitFor("the resume's SessionStart") {
      try sbd.hooks(op.id).filter { $0.kind == "SessionStart" }.count == 2
    }
    Thread.sleep(forTimeInterval: 0.5)
    #expect(conversationHelpers.startContexts(sbd, op).count == 1)
  }

  // MARK: Send and log

  /// Whether the operator exists before `sb operator <text>` runs.
  enum Before: CaseIterable { case exists, missing }

  @Test(arguments: Before.allCases) func operatorWithTextDeliversItToTheOperator(_ before: Before) throws {
    let sbd = try Instance()
    if before == .exists {
      let op = try openOperator(sbd)
      try sbd.waitFor(op.id, "the operator's claude") { $0.live }
    }

    let reply = try decode(JSON.self, sbd.sb("operator", "hello", "--json"))

    let id = try #require(reply["id"]?.string, "\(reply.text)")
    #expect(try operators(sbd).map(\.id) == [id])
    try sbd.waitFor(id, "the operator's reply", timeout: 30) { $0.lastReply == "Done: hello" }
  }

  @Test func operatorLogShowsTheOperatorsMessages() throws {
    let sbd = try Instance()
    _ = try conversationHelpers.idleConversation(sbd, name: "Cache work", "other")
    let op = try idleOperator(sbd, "hello")

    let log = try decode([ChatMessage].self, sbd.sb("operator", "--log", "--json"))

    #expect(log.map { "\($0.role): \($0.text)" } == ["user: hello", "assistant: Done: hello"])
    #expect(try sbd.get(op.id).name == Manager.operatorName)
  }

  @Test func theOperatorKeepsItsNameAfterItsFirstPrompt() throws {
    let sbd = try Instance()

    let op = try idleOperator(sbd, "Fix the cache")

    #expect(op.name == Manager.operatorName)
    #expect(try !sbd.events(op.id).contains { $0.kind == "renamed" })
  }

  // MARK: done is refused (Risk 5)

  @Test(arguments: Ref.allCases) func doneOnTheOperatorIsRefusedAndNamesRm(_ how: Ref) throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    let refused = try sbd.run(["done", ref(op, how)])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("sb rm"), "\(refused.stderr)")
    #expect(try sbd.get(op.id).markedDone == false)
  }

  @Test func theDoneRequestOnTheOperatorIsRefusedEvenWithAnOpenWait() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try sbd.sb("wait", op.id, "--kind", "date", "--until", "1h", "--note", "loop tick")

    let error = failure(sbd, "done", ["session": .string(op.id)])

    #expect(error.contains("sb rm"), Comment(rawValue: error))
    let after = try sbd.get(op.id)
    #expect(after.markedDone == false)
    #expect(after.waits.count == 1)
    #expect(try !sbd.events(op.id).contains { $0.kind == "done" })
  }

  // MARK: rm is refused while a wait is open (Risk 5)

  /// The wait flags of each wait shape that can sit on the operator.
  struct WaitShape: Sendable, CustomTestStringConvertible {
    let label: String
    let flags: [String]
    /// Whether Claude in the operator sets it. Otherwise it comes from a terminal.
    let byClaude: Bool
    var testDescription: String { label }
  }

  static let waitShapes: [WaitShape] = [
    WaitShape(label: "date from a terminal", flags: ["--kind", "date", "--until", "1h"], byClaude: false),
    WaitShape(label: "date by Claude", flags: ["--kind", "date", "--until", "1h"], byClaude: true),
    WaitShape(label: "manual", flags: ["--kind", "manual", "--note", "ask Alex"], byClaude: false),
    WaitShape(label: "notify", flags: ["--kind", "date", "--until", "1h", "--then", "notify"], byClaude: false),
    WaitShape(label: "session", flags: ["--kind", "session", "--state", "done", "--target"], byClaude: false),
  ]

  /// Sets the shape's wait on the operator. A session wait targets a new work session.
  func setWait(_ sbd: Instance, on op: SessionSummary, _ shape: WaitShape) throws {
    var flags = shape.flags
    if flags.last == "--target" { flags.append(try sbd.new(name: "kid").id) }
    let env = shape.byClaude ? ["SB_SESSION_ID": op.id, "CLAUDECODE": "1"] : [:]
    try sbd.sb(["wait", op.id] + flags, env: env)
    try #require(try sbd.get(op.id).waits.count == 1)
  }

  @Test(arguments: waitShapes) func rmOnTheOperatorWithAnOpenWaitIsRefusedAndNamesTheClear(_ shape: WaitShape) throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try setWait(sbd, on: op, shape)

    let refused = try sbd.run(["rm", "Operator"])

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("sb wait Operator --clear"), "\(refused.stderr)")
    #expect(try sbd.get(op.id).waits.count == 1)
  }

  @Test func theRmRequestByIdWithAnOpenWaitIsRefused() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try sbd.sb("wait", op.id, "--kind", "manual", "--note", "ask Alex")

    let error = failure(sbd, "rm", ["session": .string(op.id)])

    #expect(error.contains("sb wait Operator --clear"), Comment(rawValue: error))
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  @Test func rmOnTheOperatorSucceedsAfterTheClearAndTheNextOperatorIsNew() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try sbd.sb("wait", op.id, "--kind", "date", "--until", "1h")
    try sbd.sb("wait", "Operator", "--clear")

    try sbd.sb("rm", "Operator")

    #expect(try operators(sbd).isEmpty)
    let next = try openOperator(sbd)
    #expect(next.id != op.id)
    #expect(next.kind == .operator)
    #expect(try operators(sbd).map(\.id) == [next.id])
  }

  @Test func rmOnAnOperatorThatNeverHadAWaitSucceeds() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try sbd.sb("rm", op.id)

    #expect(try operators(sbd).isEmpty)
  }

  @Test func deleteAllDoneRemovesADoneWorkSessionAndLeavesTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let work = try sbd.new(prompt: "hello", name: "work")
    try sbd.waitFor(work.id, "the work session's reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("done", work.id)
    _ = try sbd.run(["done", op.id])

    let result = try sbd.client.call(
      "rm-done",
      ["worktree": false, "confirmed": true, "targets": .array([.string(work.id), .string(op.id)])],
      timeout: 300)

    let ids = Set(try sbd.client.call("ls", as: [SessionSummary].self).map(\.id))
    #expect(!ids.contains(work.id), "\(result.text)")
    #expect(ids.contains(op.id), "\(result.text)")
  }

  // MARK: MCP servers

  @Test func managerMCPNamingTheOperatorAddsASharedServer() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    _ = try sbd.waitForRunning("grafana")
    let op = try idleOperator(sbd)
    try conversationHelpers.requireSwitchboardOnly(sbd, op.id)
    let before = conversationHelpers.launches(sbd, op).count

    try sbd.sb("manager", "mcp", "Operator", "add", "grafana")

    let launched = try conversationHelpers.launch(sbd, op, after: before)
    #expect(launched.hasPrefix("--resume \(op.claudeSessionId) "), "\(launched)")
    let args = try conversationHelpers.scriptArgs(sbd, op.id)
    #expect(args.contains("--strict-mcp-config"))
    #expect(conversationHelpers.serverNames(args) == ["grafana", "switchboard"])
    #expect(try sbd.get(op.id).mcp == ["grafana"])
  }

  @Test func managerMCPNamingTheOperatorShowsItsServers() throws {
    let sbd = try Instance(config: ManagerConversationsTests.sharedServers)
    _ = try openOperator(sbd)

    let shown = try decode(JSON.self, sbd.sb("manager", "mcp", "Operator", "--json"))

    #expect(shown[ManagerConversationsTests.serversKey] == [], "\(shown.text)")
  }

  // MARK: One operator (Risk 4)

  @Test func operatorRunFourTimesAtOnceCreatesOneOperator() throws {
    let sbd = try Instance()

    let runs = try (0..<4).map { _ in try BackgroundSb(sbd, ["operator", "--json"]) }
    let results = try runs.map { try $0.finish(within: 60) }

    for r in results { try #require(r.status == 0, "\(r.stderr)") }
    let ids = try Set(results.map { try decode(SessionSummary.self, $0.stdout).id })
    #expect(ids.count == 1, "\(ids)")
    #expect(try operators(sbd).map(\.id) == Array(ids))
  }

  /// Stores two operators, with the newer one saved first and given the
  /// lexically smaller id, and starts sbd again. It replaces the database
  /// that the first start wrote.
  func seedTwoOperators(_ sbd: Instance) throws -> (older: String, newer: String) {
    let now = try sbd.now()
    sbd.stopSbd()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: sbd.home.database + suffix) }
    try FileManager.default.createDirectory(atPath: sbd.home.managerFolder, withIntermediateDirectories: true)
    func seeded(_ id: String, created: Int64) -> Session {
      var s = Session(
        id: id, name: Manager.operatorName, cwd: sbd.home.managerFolder,
        claudeSessionId: UUID().uuidString.lowercased(), created: created)
      s.manager = true
      s.isOperator = true
      s.mcp = []
      s.mcpScoped = true
      return s
    }
    let newer = seeded("saaaaa", created: now)
    let older = seeded("szzzzz", created: now - 60_000)
    do {
      let store = try Store(path: sbd.home.database)
      try store.save(newer)
      try store.save(older)
    }
    try sbd.startSbd()
    return (older.id, newer.id)
  }

  @Test func withTwoOperatorsStoredOperatorUsesTheOldestAndKeepsBoth() throws {
    let sbd = try Instance()
    let (older, newer) = try seedTwoOperators(sbd)

    let opened = try openOperator(sbd)

    #expect(opened.id == older)
    #expect(Set(try operators(sbd).map(\.id)) == [older, newer])
  }

  @Test func withTwoOperatorsStoredSbdLogsTheOtherOne() throws {
    let sbd = try Instance()
    let (_, newer) = try seedTwoOperators(sbd)

    _ = try openOperator(sbd)

    try sbd.waitFor("a log line that names \(newer)") {
      ((try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? "").contains(newer)
    }
  }
}
