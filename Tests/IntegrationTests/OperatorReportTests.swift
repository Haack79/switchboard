import Foundation
import SwitchboardCore
import Testing

/// The operator records reports with `sb operator report` or the MCP
/// `report` tool. A report with `needsYou` is the operator's Inbox item until
/// the user writes to the operator or acknowledges it. Nothing else that the
/// operator says reaches the Inbox, except a blocking prompt and the wait
/// rule's Needs you. `sb operator reports` lists every report.
@Suite(.blocking(timeLimit: .seconds(120))) struct OperatorReportTests {
  let operatorHelpers = OperatorTests()
  let conversationHelpers = ManagerConversationsTests()

  static let question = "PR #12 is green. Merge it?"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func inside(_ id: String) -> [String: String] { conversationHelpers.inside(id) }

  func idleOperator(_ sbd: Instance) throws -> SessionSummary { try operatorHelpers.idleOperator(sbd) }

  func operators(_ sbd: Instance) throws -> [SessionSummary] { try operatorHelpers.operators(sbd) }

  /// Runs `sb operator report` inside the session, as its Claude would, whatever its exit status.
  func report(
    _ sbd: Instance, from s: SessionSummary, _ text: String, needsYou: Bool = true, about: String? = nil
  ) throws -> CommandResult {
    var args = ["operator", "report"]
    if needsYou { args.append("--needs-you") }
    if let about { args += ["--session", about] }
    args.append(text)
    return try sbd.run(args, env: inside(s.id))
  }

  /// Records the report inside the operator and requires that sb accepted it.
  func reported(
    _ sbd: Instance, _ op: SessionSummary, _ text: String = question, needsYou: Bool = true, about: String? = nil
  ) throws {
    let r = try report(sbd, from: op, text, needsYou: needsYou, about: about)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
  }

  /// The operator's item. It also checks that the app's guard and `sb triage --json` agree with sbd's item.
  func inboxItem(_ sbd: Instance, _ op: SessionSummary) throws -> TriageItem? {
    let s = try sbd.get(op.id)
    let listed = try sbd.triage().contains { $0.id == op.id }
    let source = s.triage?.source.rawValue ?? "none"
    #expect(Triage.inInbox(s) == (s.triage != nil), "inInbox disagrees with the item from \(source)")
    #expect(listed == (s.triage != nil), "sb triage disagrees with the item from \(source)")
    return s.triage
  }

  /// `sb operator reports --json`.
  func reports(_ sbd: Instance, all: Bool = false) throws -> [JSON] {
    let text = try sbd.sb(["operator", "reports", "--json"] + (all ? ["--all"] : []))
    return try #require(JSON.parse(text)?.array, "\(text)")
  }

  /// The `report` events that any session holds.
  func reportEvents(_ sbd: Instance) throws -> [Event] {
    try sbd.client.call("ls", as: [SessionSummary].self).flatMap { try sbd.events($0.id) }.filter {
      $0.kind == "report"
    }
  }

  // MARK: A report that needs the user

  @Test func aNeedsYouReportPutsTheOperatorInNeedsYouWithItsText() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    _ = try sbd.new(name: "kid")

    try reported(sbd, op, about: "kid")

    let s = try sbd.get(op.id)
    #expect(s.state == .needsYou)
    #expect(s.reason == Self.question)
  }

  @Test func aNeedsYouReportGivesAReportItemWithAReplyOption() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    _ = try sbd.new(name: "kid")

    try reported(sbd, op, about: "kid")

    let item = try #require(try inboxItem(sbd, op))
    #expect(item.source == .report)
    #expect(item.options.contains { $0.action == .reply }, "\(item.options)")
    #expect(item.summary.contains(Self.question), "\(item.summary)")
  }

  @Test func sbTriageListsTheOperatorWithItsReport() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try reported(sbd, op)

    let listed = try #require(try sbd.triage().first { $0.id == op.id })
    #expect(listed.triage?.source == .report)
  }

  // MARK: What closes a report, and what doesn't

  @Test func aWaitMessageThatSbdSendsLeavesTheReportItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    try sbd.sb("wait", "Operator", "--kind", "date", "--until", "1h", "--then", "resume")
    let mark = try sbd.lastEventId(op.id)

    try sbd.advanceClock(2 * WaitTests.hourMs)

    try sbd.waitFor(op.id, "the operator's turn for the wait", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard:") == true
    }
    #expect(try !sbd.sbdMessages(op.id, after: mark).isEmpty)
    #expect(try inboxItem(sbd, op)?.source == .report)
  }

  @Test func sbSendFromATerminalClosesTheReport() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    try sbd.sb("send", "Operator", "yes")

    #expect(try inboxItem(sbd, op) == nil)
    try sbd.waitFor(op.id, "the reply to yes", timeout: 30) { $0.lastReply == "Done: yes" }
    #expect(try inboxItem(sbd, op) == nil)
  }

  /// A conversation's shell pane has `SB_SESSION_ID` but no `CLAUDECODE`, so the user typed the message.
  @Test func sbOperatorFromAShellPaneClosesTheReport() throws {
    let sbd = try Instance()
    let c = try conversationHelpers.idleConversation(sbd, name: "Queue work", "hello")
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    try sbd.sb(["operator", "yes"], env: ["SB_SESSION_ID": c.id])

    #expect(try inboxItem(sbd, op) == nil)
    try sbd.waitFor(op.id, "the reply to yes", timeout: 30) { $0.lastReply == "Done: yes" }
    #expect(try inboxItem(sbd, op) == nil)
  }

  /// How a conversation's Claude sends the operator a message. Each carries `from`.
  enum PeerRoute: CaseIterable { case mcpSend, sbSendInsideClaude, sbOperatorInsideClaude }

  @Test(arguments: PeerRoute.allCases) func aConversationsMessageToTheOperatorLeavesTheReportOpen(_ route: PeerRoute)
    throws
  {
    let sbd = try Instance()
    let c = try conversationHelpers.idleConversation(sbd, name: "Queue work", "hello")
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    let text = "Keep 10 sessions on the queue."

    switch route {
    case .mcpSend:
      let result = try MCPClient(sbd, env: inside(c.id)).call("send", ["session": "Operator", "text": .string(text)])
      try #require(!result.isError, "\(result.text)")
    case .sbSendInsideClaude:
      try sbd.sb(["send", "Operator", text], env: inside(c.id))
    case .sbOperatorInsideClaude:
      try sbd.sb(["operator", text], env: inside(c.id))
    }

    let sent = try #require(try sbd.events(op.id).last { $0.kind == "sent" })
    #expect(sent.data["from"]?.string == c.id, "\(sent.data.text)")
    try sbd.waitFor(op.id, "the operator's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }
    #expect(try inboxItem(sbd, op)?.source == .report)
  }

  /// A message that the operator sends itself is not the user's, so it leaves the report open.
  @Test func theOperatorsMessageToItselfLeavesTheReportOpen() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    let text = "Check the queue again."

    try sbd.sb(["send", "Operator", text], env: inside(op.id))

    let sent = try #require(try sbd.events(op.id).last { $0.kind == "sent" })
    #expect(sent.data["from"]?.string == op.id, "\(sent.data.text)")
    try sbd.waitFor(op.id, "the operator's reply", timeout: 30) { $0.lastReply == "Done: \(text)" }
    #expect(try inboxItem(sbd, op)?.source == .report)
  }

  /// A conversation's Claude can't answer the report for the user through `sb choose`.
  @Test func sbChooseInsideClaudeOnAReportIsRefused() throws {
    let sbd = try Instance()
    let c = try conversationHelpers.idleConversation(sbd, name: "Queue work", "hello")
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    let item = try #require(try sbd.get(op.id).triage)
    let reply = try #require(item.options.firstIndex { $0.action == .reply }, "\(item.options)")
    let sent = try sbd.count("sent", of: op.id)

    let r = try sbd.run(["choose", "Operator", "\(reply + 1)", "--text", "yes"], env: inside(c.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains("inside Claude Code"), "\(r.stderr)")
    #expect(try sbd.count("sent", of: op.id) == sent)
    #expect(try inboxItem(sbd, op)?.source == .report)
  }

  @Test func sbAckClosesTheReport() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    try sbd.sb("ack", "Operator")

    #expect(try inboxItem(sbd, op) == nil)
  }

  @Test func aReportRecordedAfterTheAckStaysOpen() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op, "PR alpha is green. Merge it?")
    try sbd.sb("ack", "Operator")

    try reported(sbd, op, "PR bravo is green. Merge it?")

    let item = try #require(try inboxItem(sbd, op))
    #expect(item.source == .report)
    #expect(item.summary.contains("PR bravo is green. Merge it?"), "\(item.summary)")
    #expect(!item.summary.contains("PR alpha"), "\(item.summary)")
    #expect(try sbd.get(op.id).reason == "PR bravo is green. Merge it?")
  }

  @Test func choosingTheReplyOptionSendsTheTextToTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    let item = try #require(try sbd.get(op.id).triage)
    let reply = try #require(item.options.firstIndex { $0.action == .reply }, "\(item.options)")

    _ = try sbd.client.call(
      "choose",
      [
        "session": .string(op.id), "option": .string("\(reply + 1)"), "text": "Yes, merge it.",
        "ref": .string(item.ref),
      ])

    let replied = try sbd.waitFor(op.id, "the reply to the choice", timeout: 30) {
      $0.lastReply == "Done: Yes, merge it."
    }
    let sent = try #require(try sbd.events(op.id).last { $0.kind == "sent" })
    #expect(sent.data["text"]?.string == "Yes, merge it.")
    #expect(sent.data["from"] == nil)
    #expect(sent.data["by"] == nil)
    #expect(replied.triage == nil)
  }

  @Test func sbChooseWithTheReplyOptionSendsTheText() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    let item = try #require(try sbd.get(op.id).triage)
    let reply = try #require(item.options.firstIndex { $0.action == .reply }, "\(item.options)")

    try sbd.sb("choose", "Operator", "\(reply + 1)", "--text", "Yes, merge it.")

    try sbd.waitFor(op.id, "the reply to the choice", timeout: 30) { $0.lastReply == "Done: Yes, merge it." }
  }

  // MARK: What doesn't reach the Inbox

  @Test func aReportWithoutNeedsYouCreatesNoItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try reported(sbd, op, "Removed the kid's worktree.", needsYou: false)

    #expect(try inboxItem(sbd, op) == nil)
    #expect(try sbd.get(op.id).reason != "Removed the kid's worktree.")
  }

  @Test func aQuestionLikeReplyWithNoReportCreatesNoItem() throws {
    let sbd = try Instance()

    let op = try operatorHelpers.idleOperator(sbd, "Which database should I use?")

    try #require(op.state == .needsYou, "\(op.state): \(op.reason)")
    #expect(try inboxItem(sbd, op) == nil)
  }

  @Test func anSbSummarySetCardWithNoReportCreatesNoItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let card = JSON.object([
      "summary": "It finished.\nIt needs a call.", "options": [["label": "Go on", "action": "send"]],
    ]).text

    let r = try sbd.setSummary([], card, env: inside(op.id))

    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try #require(try sbd.events(op.id).contains { $0.kind == "summary" })
    #expect(try inboxItem(sbd, op) == nil)
  }

  @Test func anOverdueWaitOnTheOperatorCreatesARuleItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    try sbd.sb("wait", "Operator", "--kind", "session", "--target", kid.id, "--state", "done")

    try sbd.advanceClock(25 * WaitTests.hourMs)

    try sbd.waitFor(op.id, "the recheck") { $0.state == .needsYou && $0.triage != nil }
    let item = try #require(try inboxItem(sbd, op))
    #expect(item.source == .rule)
  }

  // MARK: Only the operator reports

  /// A caller that is not the operator.
  enum Caller: CaseIterable { case conversation, work, terminal }

  func callerEnvironment(_ sbd: Instance, _ caller: Caller) throws -> [String: String] {
    switch caller {
    case .conversation:
      let c = try conversationHelpers.idleConversation(sbd, name: "Cache work", "hello")
      return inside(c.id)
    case .work:
      return inside(try sbd.new(name: "work").id)
    case .terminal:
      return [:]
    }
  }

  @Test(arguments: Caller.allCases) func sbOperatorReportOutsideTheOperatorIsRefused(_ caller: Caller) throws {
    let sbd = try Instance()
    let op = try operatorHelpers.openOperator(sbd)
    let env = try callerEnvironment(sbd, caller)
    let sent = try sbd.count("sent", of: op.id)

    let r = try sbd.run(["operator", "report", "--needs-you", Self.question], env: env)

    #expect(r.status != 0)
    #expect(try reportEvents(sbd).isEmpty)
    #expect(try sbd.count("sent", of: op.id) == sent)
    #expect(try sbd.get(op.id).triage == nil)
  }

  @Test(arguments: [Caller.conversation, .work]) func aRefusedReportCreatesNoOperator(_ caller: Caller) throws {
    let sbd = try Instance()
    let env = try callerEnvironment(sbd, caller)

    let r = try sbd.run(["operator", "report", "--needs-you", Self.question], env: env)

    #expect(r.status != 0)
    #expect(try operators(sbd).isEmpty)
    #expect(try reportEvents(sbd).isEmpty)
  }

  @Test(arguments: Caller.allCases) func theMCPReportToolOutsideTheOperatorIsRefused(_ caller: Caller) throws {
    let sbd = try Instance()
    _ = try operatorHelpers.openOperator(sbd)
    let env = try callerEnvironment(sbd, caller)

    let result = try MCPClient(sbd, env: env).call("report", ["text": .string(Self.question), "needsYou": true])

    #expect(result.isError, "\(result.text)")
    #expect(try reportEvents(sbd).isEmpty)
  }

  @Test func theMCPReportToolInTheOperatorRecordsTheReport() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    _ = try sbd.new(name: "kid")

    let result = try MCPClient(sbd, env: inside(op.id)).call(
      "report", ["text": .string(Self.question), "needsYou": true, "session": "kid"])

    #expect(!result.isError, "\(result.text)")
    #expect(try inboxItem(sbd, op)?.source == .report)
  }

  @Test func theReportToolIsListedWithItsFields() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "report" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["text"]?["type"]?.string == "string")
    #expect(properties["needsYou"]?["type"]?.string == "boolean")
    #expect(properties["session"]?["type"]?.string == "string")
    #expect(tool["description"]?.string?.contains("operator") == true, "\(tool.text)")
  }

  // MARK: The feed

  @Test func reportsListsAReportWithoutNeedsYou() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try reported(sbd, op, "Removed the kid's worktree.", needsYou: false)

    #expect(try reports(sbd).map { $0["text"]?.string } == ["Removed the kid's worktree."])
  }

  @Test func reportsListsEveryReportOldestFirst() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op, "first", needsYou: false)
    try reported(sbd, op, "second")
    try reported(sbd, op, "third", needsYou: false)

    let listed = try reports(sbd)

    #expect(listed.map { $0["text"]?.string } == ["first", "second", "third"])
  }

  @Test func reportsMarksAnOpenNeedsYouReportOpen() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try reported(sbd, op)

    #expect(try reports(sbd).map { $0["open"]?.bool } == [true])
  }

  @Test func reportsMarksAnAcknowledgedReportClosed() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    try sbd.sb("ack", "Operator")

    #expect(try reports(sbd).map { $0["open"]?.bool } == [false])
  }

  @Test func reportsNamesTheSessionThatAReportIsAbout() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    _ = try sbd.new(name: "flag-cache")
    try reported(sbd, op, about: "flag-cache")

    let text = try sbd.sb("operator", "reports")

    #expect(text.contains("flag-cache"), "\(text)")
    #expect(text.contains(Self.question), "\(text)")
  }

  @Test func reportsListsTheDefaultLimitAndAllListsEveryReport() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let mcp = try MCPClient(sbd, env: inside(op.id))
    let total = Event.defaultLimit + 1
    for n in 1...total {
      let result = try mcp.call("report", ["text": .string("report \(n)"), "needsYou": false])
      try #require(!result.isError, "\(result.text)")
    }

    let limited = try reports(sbd)
    let all = try reports(sbd, all: true)

    #expect(limited.count == Event.defaultLimit)
    #expect(all.count == total)
    #expect(all.first?["text"]?.string == "report 1")
    #expect(all.last?["text"]?.string == "report \(total)")
  }

  /// `report` and `reports` are reserved first words, so neither reaches the operator as a message.
  @Test func operatorReportsSendsNoMessage() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let sent = try sbd.count("sent", of: op.id)

    let r = try sbd.run(["operator", "reports"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try sbd.count("sent", of: op.id) == sent)
  }

  @Test func operatorReportInsideTheOperatorSendsNoMessage() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let sent = try sbd.count("sent", of: op.id)

    try reported(sbd, op)

    #expect(try sbd.count("sent", of: op.id) == sent)
    let texts = try sbd.events(op.id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
    #expect(!texts.contains { $0.hasPrefix("report") }, "\(texts)")
  }

  // MARK: A restart

  @Test func anOpenReportStaysOpenAfterAnSbdRestart() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    sbd.stopSbd()
    try sbd.startSbd()

    let item = try #require(try inboxItem(sbd, op))
    #expect(item.source == .report)
    #expect(try sbd.get(op.id).reason == Self.question)
  }

  @Test func anAcknowledgedReportStaysClosedAfterAnSbdRestart() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    try sbd.sb("ack", "Operator")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try inboxItem(sbd, op) == nil)
  }

  // MARK: rm is refused while a report is open (Risk 5)

  @Test func rmOnTheOperatorWithAnOpenReportAndNoWaitIsRefused() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    try #require(try sbd.get(op.id).waits.isEmpty)

    let refused = try sbd.run(["rm", "Operator"])

    #expect(refused.status != 0)
    #expect(refused.stderr.lowercased().contains("acknowledge"), "\(refused.stderr)")
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  @Test func theRmRequestByIdWithAnOpenReportIsRefused() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)

    let error = failure(sbd, "rm", ["session": .string(op.id)])

    #expect(error.lowercased().contains("acknowledge"), Comment(rawValue: error))
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  @Test func rmOnTheOperatorSucceedsAfterTheAck() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    try sbd.sb("ack", "Operator")

    try sbd.sb("rm", "Operator")

    #expect(try operators(sbd).isEmpty)
  }

  @Test func rmOnTheOperatorSucceedsAfterTheUserAnswers() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op)
    try sbd.sb("send", "Operator", "yes")
    try sbd.waitFor(op.id, "the reply to yes", timeout: 30) { $0.lastReply == "Done: yes" }

    try sbd.sb("rm", "Operator")

    #expect(try operators(sbd).isEmpty)
  }

  @Test func rmOnTheOperatorWithOnlyAReportWithoutNeedsYouSucceeds() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try reported(sbd, op, "Removed the kid's worktree.", needsYou: false)

    try sbd.sb("rm", "Operator")

    #expect(try operators(sbd).isEmpty)
  }
}
