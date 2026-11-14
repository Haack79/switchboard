import Foundation
import SwitchboardCore
import Testing

/// A wait that a conversation's Claude sets on the conversation goes to the
/// operator, when it resolves the same way there: it resumes, Claude set it,
/// `here` is not set, and its resolution reads nothing of the conversation.
/// The wait records the conversation in `handedFrom`, and only the operator
/// wakes. Clearing and resolving through the conversation follow the wait.
@Suite(.blocking(timeLimit: .seconds(120))) struct OperatorHandoffTests {
  let conversationHelpers = ManagerConversationsTests()
  let operatorHelpers = OperatorTests()
  let digest = DigestTests()

  static let handoffLine = "the operator follows this through"
  static let conversationName = "Plan the cache fix"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func inside(_ id: String) -> [String: String] { conversationHelpers.inside(id) }

  /// A conversation with a fixed name whose first turn has ended.
  func conversation(_ sbd: Instance, _ name: String = conversationName) throws -> SessionSummary {
    let c = try conversationHelpers.idleConversation(sbd, name: name, "hello")
    try #require(c.name == name, "the conversation is named \(c.name)")
    return c
  }

  func operators(_ sbd: Instance) throws -> [SessionSummary] { try operatorHelpers.operators(sbd) }

  /// The one operator.
  func theOperator(_ sbd: Instance) throws -> SessionSummary {
    let ops = try operators(sbd)
    try #require(ops.count == 1, "\(ops.count) operators")
    return ops[0]
  }

  /// Runs `sb wait --json` inside the session, as its Claude would, and returns sbd's answer.
  func waitInside(_ sbd: Instance, _ s: SessionSummary, _ args: [String]) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb(["wait", "--json"] + args, env: inside(s.id)))
  }

  /// The event of `kind` that sbd recorded for the wait, on the session.
  func waitEvent(_ sbd: Instance, _ id: String, _ kind: String, wait: String) throws -> Event? {
    try sbd.events(id).last { e in
      guard e.kind == kind else { return false }
      if e.data["wait"]?["id"]?.string == wait { return true }
      return e.data["waits"]?.array?.contains(.string(wait)) == true
    }
  }

  /// Requires that the answer is the operator's, and that the operator holds
  /// one wait handed from `conversation`, recorded with `from`. Returns that wait.
  @discardableResult
  func expectHandedOff(_ sbd: Instance, from conversation: SessionSummary, answer: SessionSummary) throws -> Wait {
    let op = try theOperator(sbd)
    #expect(answer.id == op.id)
    let handed = op.waits.filter { $0.handedFrom?.id == conversation.id }
    try #require(handed.count == 1, "\(op.waits)")
    let wait = handed[0]
    #expect(wait.handedFrom?.name == conversation.name)
    #expect(wait.by == .claude)
    #expect(try sbd.get(conversation.id).waits.isEmpty)
    let event = try #require(try waitEvent(sbd, op.id, "wait", wait: wait.id))
    #expect(event.data["from"]?.string == conversation.id, "\(event.data.text)")
    #expect(try waitEvent(sbd, conversation.id, "wait", wait: wait.id) == nil)
    return wait
  }

  /// Requires that the wait stayed on `s`, the session that the request named,
  /// with no `handedFrom`, and that no operator came into being for it.
  func expectStays(_ sbd: Instance, on s: SessionSummary, answer: SessionSummary) throws {
    #expect(answer.id == s.id)
    let waits = try sbd.get(s.id).waits
    #expect(waits.count == 1, "\(waits)")
    #expect(waits.allSatisfy { $0.handedFrom == nil })
    #expect(try operators(sbd).isEmpty)
  }

  // MARK: The handoff (success criteria)

  @Test func aConversationsSessionWaitGoesToTheOperatorWhichAloneGetsTheMessage() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let kid = try digest.child(sbd, of: c, name: "kid", prompt: "slow 2")
    try sbd.waitFor(kid.id, "the kid's turn") { $0.state == .working }
    let mark = try sbd.lastEventId(c.id)

    let answer = try waitInside(
      sbd, c, ["--kind", "session", "--target", "kid", "--state", "needs_you", "--note", "remove its worktree"])

    try expectHandedOff(sbd, from: c, answer: answer)
    let op = try theOperator(sbd)
    let resumed = try sbd.waitFor(op.id, "the operator's turn", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard: kid to reach Needs you: it did.") == true
    }
    #expect(resumed.waits.isEmpty)
    let messages = try sbd.sbdMessages(op.id)
    #expect(messages.count == 1)
    let text = messages.first?.data["text"]?.string ?? ""
    #expect(text.contains(#""\#(c.name)""#), "\(text)")
    #expect(text.hasSuffix("Your note: remove its worktree."), "\(text)")
    #expect(try sbd.sbdMessages(c.id, after: mark).isEmpty)
    #expect(try sbd.get(c.id).waits.isEmpty)
  }

  @Test func theHandedOffWaitResolvesOnceAndTheConversationHearsNothingLater() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let kid = try digest.child(sbd, of: c, name: "kid", prompt: "slow 2")
    try sbd.waitFor(kid.id, "the kid's turn") { $0.state == .working }
    let mark = try sbd.lastEventId(c.id)
    _ = try waitInside(sbd, c, ["--kind", "session", "--target", "kid", "--state", "needs_you"])
    let op = try theOperator(sbd)
    try sbd.waitFor(op.id, "the operator's turn", timeout: 30) { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }

    try digest.flip(sbd, kid)
    Thread.sleep(forTimeInterval: 1)

    #expect(try sbd.sbdMessages(op.id).count == 1)
    #expect(try sbd.sbdMessages(c.id, after: mark).isEmpty)
  }

  @Test func spawnWithWaitFromAConversationKeepsTheParentAndPutsTheWaitOnTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let kid = try mcp.call(
      "spawn",
      [
        "repository": .string(try sbd.makeRepo()), "branch": "kid", "name": "kid", "prompt": "hello", "wait": "done",
      ]
    ).decode(SessionSummary.self)

    #expect(kid.parent == c.id)
    #expect(try sbd.get(kid.id).parent == c.id)
    let op = try theOperator(sbd)
    let wait = try #require(op.waits.first)
    #expect(op.waits.count == 1)
    #expect(wait.kind == .session)
    #expect(wait.session?.id == kid.id)
    #expect(wait.state == .done)
    #expect(wait.handedFrom?.id == c.id)
    #expect(try sbd.get(c.id).waits.isEmpty)
  }

  @Test func theConversationsNextDigestStillListsTheChildWhoseWaitWentToTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))
    let kid = try mcp.call(
      "spawn",
      [
        "repository": .string(try sbd.makeRepo()), "branch": "kid", "name": "kid", "prompt": "hello", "wait": "done",
      ]
    ).decode(SessionSummary.self)
    try sbd.waitFor(kid.id, "the kid's reply", timeout: 30) { $0.lastReply == "Done: hello" && $0.state == .needsYou }
    let before = digest.contexts(sbd, c).count

    try digest.prompt(sbd, c, "what changed")

    let given = digest.contexts(sbd, c).dropFirst(before).joined()
    #expect(given.contains("kid (\(kid.id))"), "\(given)")
  }

  @Test func sbSpawnWithWaitInsideAConversationPutsTheWaitOnTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let repo = try sbd.makeRepo()

    let kid = try decode(
      SessionSummary.self,
      sbd.sb(
        ["spawn", "--json", "--repo", repo, "--branch", "kid", "--name", "kid", "--prompt", "hello", "--wait", "done"],
        env: inside(c.id)))

    #expect(kid.parent == c.id)
    let op = try theOperator(sbd)
    #expect(op.waits.map(\.session?.id) == [kid.id])
    #expect(op.waits.map(\.handedFrom?.id) == [c.id])
    #expect(try sbd.get(c.id).waits.isEmpty)
  }

  @Test func setWaitWithNoSessionFromAConversationHandsOff() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let answer = try mcp.call("set_wait", ["kind": "date", "until": "1h", "note": "loop tick"]).decode(
      SessionSummary.self)

    let wait = try expectHandedOff(sbd, from: c, answer: answer)
    #expect(wait.kind == .date)
    #expect(wait.note == "loop tick")
  }

  @Test func setWaitNamingAnotherConversationHandsItOffFromThatConversation() throws {
    let sbd = try Instance()
    let caller = try conversation(sbd, "Caller")
    let named = try conversation(sbd, "Named")
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let answer = try mcp.call("set_wait", ["session": .string(named.id), "kind": "date", "until": "1h"]).decode(
      SessionSummary.self)

    try expectHandedOff(sbd, from: named, answer: answer)
    #expect(try theOperator(sbd).waits.allSatisfy { $0.handedFrom?.id != caller.id })
    #expect(try sbd.get(caller.id).waits.isEmpty)
  }

  @Test func setWaitWithHereKeepsTheWaitOnTheConversationWhichResumesOnce() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let kid = try digest.child(sbd, of: c, name: "kid", prompt: "slow 2")
    try sbd.waitFor(kid.id, "the kid's turn") { $0.state == .working }
    let mark = try sbd.lastEventId(c.id)
    let mcp = try MCPClient(sbd, env: inside(c.id))

    let answer = try mcp.call(
      "set_wait", ["kind": "session", "target": "kid", "state": "needs_you", "here": true]
    ).decode(SessionSummary.self)

    try expectStays(sbd, on: c, answer: answer)
    try sbd.waitFor(c.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: kid to reach Needs you: it did."
    }
    try digest.flip(sbd, kid)
    Thread.sleep(forTimeInterval: 1)
    #expect(try sbd.sbdMessages(c.id, after: mark).count == 1)
    #expect(try operators(sbd).isEmpty)
  }

  @Test func sbWaitWithHereKeepsTheWaitOnTheConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try waitInside(sbd, c, ["--here", "--kind", "date", "--until", "1h"])

    try expectStays(sbd, on: c, answer: answer)
  }

  @Test func setWaitsSchemaTakesHere() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "set_wait" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["here"]?["type"]?.string == "boolean")
  }

  // MARK: Waits that stay on the conversation (Risk 1)

  /// A wait that Claude in a conversation sets on the conversation and that must stay there.
  struct StayShape: Sendable, CustomTestStringConvertible {
    let label: String
    let flags: [String]
    var testDescription: String { label }
  }

  static let stayShapes: [StayShape] = [
    StayShape(label: "then notify", flags: ["--kind", "date", "--until", "1h", "--then", "notify"]),
    StayShape(label: "manual with the default notify", flags: ["--kind", "manual", "--note", "ask Alex"]),
    StayShape(label: "manual by its note alone", flags: ["--note", "ask Alex"]),
    StayShape(label: "ci with no target", flags: ["--kind", "ci"]),
    StayShape(label: "review with no target", flags: ["--kind", "review", "--who", "alex"]),
    StayShape(label: "merge with no target", flags: ["--kind", "merge"]),
    StayShape(label: "deploy with no target", flags: ["--kind", "deploy"]),
    StayShape(label: "ci on 1204", flags: ["--kind", "ci", "--target", "1204"]),
    StayShape(label: "ci on #1204", flags: ["--kind", "ci", "--target", "#1204"]),
    StayShape(label: "review on 1204", flags: ["--kind", "review", "--who", "alex", "--target", "1204"]),
    StayShape(label: "merge on 1204", flags: ["--kind", "merge", "--target", "1204"]),
    StayShape(label: "deploy on 1204", flags: ["--kind", "deploy", "--target", "1204"]),
    StayShape(label: "here with a date", flags: ["--here", "--kind", "date", "--until", "1h"]),
    StayShape(
      label: "here with a qualified PR", flags: ["--here", "--kind", "merge", "--target", "PostHog/posthog#1204"]),
  ]

  @Test(arguments: stayShapes) func claudesWaitOnTheConversationStays(_ shape: StayShape) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try waitInside(sbd, c, shape.flags)

    try expectStays(sbd, on: c, answer: answer)
  }

  /// `sb wait --block` waits on the conversation's own `wait-resolved` event,
  /// so a date wait that would otherwise hand off stays, and sb returns.
  @Test func aBlockedWaitInsideAConversationStaysAndReturnsItsOutcome() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mark = try sbd.lastEventId(c.id)
    let blocked = try BackgroundSb(sbd, ["wait", "--block", "--kind", "date", "--until", "1h"], env: inside(c.id))
    let waiting = try sbd.waitFor(c.id, "the blocked wait") { $0.waits.count == 1 }
    try #require(blocked.isRunning, "sb wait --block exited before its wait resolved")
    #expect(waiting.waits.map(\.then) == [.caller])

    try sbd.advanceClock(2 * WaitTests.hourMs)
    let r = try blocked.finish(within: 15)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let e = try JSONCoding.decode(Event.self, from: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(e.kind == "wait-resolved")
    #expect(e.session == c.id)
    #expect(e.data["outcome"]?.string == "the time came")
    #expect(try sbd.sbdMessages(c.id, after: mark).isEmpty)
    #expect(try operators(sbd).isEmpty)
  }

  /// The wait names Done because an operator with no prompt, or an idle one, is already in Needs you. A wait
  /// for Needs you would resolve at the next tick. sbd refuses to mark the operator done.
  @Test func aSessionWaitWhoseTargetIsTheOperatorStaysOnTheConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let op = try operatorHelpers.openOperator(sbd)
    try #require(try sbd.get(op.id).state != .done)

    let answer = try waitInside(sbd, c, ["--kind", "session", "--target", "Operator", "--state", "done"])

    #expect(answer.id == c.id)
    let waits = try sbd.get(c.id).waits
    #expect(waits.map(\.session?.id) == [op.id])
    #expect(waits.allSatisfy { $0.handedFrom == nil })
    #expect(try sbd.get(op.id).waits.isEmpty)
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  /// How a command that names the conversation reaches sbd without Claude.
  enum Typed: CaseIterable { case terminal, shellPane }

  /// `DigestTests.aSessionWaitOnAChildResumesTheManagerOnce` runs the same command and expects the resume.
  @Test(arguments: Typed.allCases) func aWaitThatTheUserTypesStaysOnTheConversation(_ how: Typed) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let env = how == .shellPane ? ["SB_SESSION_ID": c.id] : [:]

    let answer = try decode(
      SessionSummary.self, sbd.sb(["wait", "--json", c.id, "--kind", "date", "--until", "1h"], env: env))

    try expectStays(sbd, on: c, answer: answer)
    #expect(try sbd.get(c.id).waits.map(\.by) == [.you])
  }

  // MARK: Waits that hand off (Risk 1)

  /// A wait that Claude in a conversation sets on the conversation and that goes to the operator.
  struct HandOffShape: Sendable, CustomTestStringConvertible {
    let label: String
    let flags: [String]
    var testDescription: String { label }
  }

  static let handOffShapes: [HandOffShape] = [
    HandOffShape(label: "date (the loop re-arm)", flags: ["--kind", "date", "--until", "30m", "--note", "loop tick"]),
    HandOffShape(label: "ci on owner/name#N", flags: ["--kind", "ci", "--target", "PostHog/posthog#1204"]),
    HandOffShape(
      label: "ci on a PR URL", flags: ["--kind", "ci", "--target", "https://github.com/PostHog/posthog/pull/1204"]),
    HandOffShape(
      label: "review on owner/name#N", flags: ["--kind", "review", "--who", "alex", "--target", "PostHog/posthog#1204"]),
    HandOffShape(label: "merge on owner/name#N", flags: ["--kind", "merge", "--target", "PostHog/posthog#1204"]),
    HandOffShape(label: "deploy on owner/name#N", flags: ["--kind", "deploy", "--target", "PostHog/posthog#1204"]),
    HandOffShape(
      label: "manual that resumes",
      flags: ["--kind", "manual", "--note", "ask Alex", "--until", "2h", "--then", "resume"]),
  ]

  @Test(arguments: handOffShapes) func claudesWaitOnTheConversationHandsOff(_ shape: HandOffShape) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let answer = try waitInside(sbd, c, shape.flags)

    try expectHandedOff(sbd, from: c, answer: answer)
  }

  @Test func aHandedOffDateWaitResolvesOnTheOperatorWithTheConversationsName() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let mark = try sbd.lastEventId(c.id)
    _ = try waitInside(sbd, c, ["--kind", "date", "--until", "1h", "--note", "check the dashboard"])
    let op = try theOperator(sbd)

    try sbd.advanceClock(2 * WaitTests.hourMs)

    let resumed = try sbd.waitFor(op.id, "the operator's turn", timeout: 30) {
      $0.lastReply?.hasPrefix("Done: Switchboard: until ") == true
    }
    #expect(
      resumed.lastReply?.hasSuffix(
        #": the time came. For Manager conversation "\#(c.name)". Your note: check the dashboard."#) == true,
      "\(resumed.lastReply ?? "")")
    #expect(resumed.waits.isEmpty)
    #expect(try sbd.sbdMessages(c.id, after: mark).isEmpty)
  }

  // MARK: The session that the wait names (Risk 1)

  /// A session that is not a conversation.
  enum Named: CaseIterable { case work, chat, `operator` }

  func namedSession(_ sbd: Instance, _ kind: Named) throws -> SessionSummary {
    switch kind {
    case .work:
      let s = try sbd.new(prompt: "hello", name: "work")
      return try sbd.waitFor(s.id, "the work session's reply") { $0.lastReply == "Done: hello" }
    case .chat:
      return try digest.parent(sbd, .chat)
    case .operator:
      return try operatorHelpers.idleOperator(sbd)
    }
  }

  @Test(arguments: Named.allCases) func aConversationsWaitNamedOnAnotherKindOfSessionStaysThere(_ kind: Named) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let s = try namedSession(sbd, kind)
    let opsBefore = try operators(sbd).map(\.id)

    let answer = try waitInside(sbd, c, [s.id, "--kind", "date", "--until", "1h"])

    #expect(answer.id == s.id)
    let waits = try sbd.get(s.id).waits
    #expect(waits.count == 1, "\(waits)")
    #expect(waits.allSatisfy { $0.handedFrom == nil })
    #expect(try sbd.get(c.id).waits.isEmpty)
    #expect(try operators(sbd).map(\.id) == opsBefore)
  }

  @Test(arguments: Named.allCases) func claudesWaitOnItsOwnSessionThatIsNotAConversationStays(_ kind: Named) throws {
    let sbd = try Instance()
    let s = try namedSession(sbd, kind)
    let opsBefore = try operators(sbd).map(\.id)

    let answer = try waitInside(sbd, s, ["--kind", "date", "--until", "1h"])

    #expect(answer.id == s.id)
    let waits = try sbd.get(s.id).waits
    #expect(waits.count == 1, "\(waits)")
    #expect(waits.allSatisfy { $0.handedFrom == nil })
    #expect(try operators(sbd).map(\.id) == opsBefore)
  }

  /// The loop's memory names an old conversation, so the operator re-arms its loop on that id.
  @Test func theOperatorReArmingADateWaitOnAConversationKeepsItOnTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    let op = try operatorHelpers.idleOperator(sbd)

    let answer = try waitInside(sbd, op, [c.id, "--kind", "date", "--until", "30m", "--note", "Manager loop tick"])

    #expect(answer.id == op.id)
    let wait = try expectHandedOff(sbd, from: c, answer: answer)
    #expect(wait.kind == .date)
    #expect(try operators(sbd).map(\.id) == [op.id])
  }

  // MARK: The three paths agree (Risk 1)

  /// What a handed-off session wait stores, without its id and times.
  struct Stored: Equatable, CustomStringConvertible {
    let kind: Wait.Kind
    let targetsTheChild: Bool
    let state: AttentionState?
    let by: Author
    let then: Wait.Then
    let note: String?
    let handedFromTheConversation: Bool
    let eventFromTheConversation: Bool
    let conversationWaits: Int
    var description: String {
      "\(kind) child:\(targetsTheChild) \(state.map(\.rawValue) ?? "nil") \(by) \(then) \(note ?? "nil") "
        + "handedFrom:\(handedFromTheConversation) from:\(eventFromTheConversation) left:\(conversationWaits)"
    }
  }

  func stored(_ sbd: Instance, _ c: SessionSummary, child: SessionSummary) throws -> Stored {
    let op = try theOperator(sbd)
    let wait = try #require(op.waits.first { $0.handedFrom?.id == c.id }, "\(op.waits)")
    let event = try #require(try waitEvent(sbd, op.id, "wait", wait: wait.id))
    return Stored(
      kind: wait.kind, targetsTheChild: wait.session?.id == child.id, state: wait.state, by: wait.by, then: wait.then,
      note: wait.note, handedFromTheConversation: wait.handedFrom?.name == c.name,
      eventFromTheConversation: event.data["from"]?.string == c.id, conversationWaits: try sbd.get(c.id).waits.count)
  }

  @Test func sbWaitSetWaitAndSpawnStoreTheSameWaitOnTheOperator() throws {
    let sbd = try Instance()
    let viaCLI = try conversation(sbd, "Via sb wait")
    let viaSetWait = try conversation(sbd, "Via set_wait")
    let viaSpawn = try conversation(sbd, "Via spawn")
    let cliKid = try digest.child(sbd, of: viaCLI, name: "cli-kid", prompt: "hello")
    let setWaitKid = try digest.child(sbd, of: viaSetWait, name: "set-wait-kid", prompt: "hello")

    let cliAnswer = try waitInside(sbd, viaCLI, ["--kind", "session", "--target", cliKid.id, "--state", "done"])
    let setWaitAnswer = try MCPClient(sbd, env: inside(viaSetWait.id)).call(
      "set_wait", ["kind": "session", "target": .string(setWaitKid.id), "state": "done"]
    ).decode(SessionSummary.self)
    let spawnKid = try MCPClient(sbd, env: inside(viaSpawn.id)).call(
      "spawn",
      [
        "repository": .string(try sbd.makeRepo()), "branch": "spawn-kid", "name": "spawn-kid", "prompt": "hello",
        "wait": "done",
      ]
    ).decode(SessionSummary.self)

    let op = try theOperator(sbd)
    #expect(cliAnswer.id == op.id)
    #expect(setWaitAnswer.id == op.id)
    let expected = Stored(
      kind: .session, targetsTheChild: true, state: .done, by: .claude, then: .resume, note: nil,
      handedFromTheConversation: true, eventFromTheConversation: true, conversationWaits: 0)
    #expect(try stored(sbd, viaCLI, child: cliKid) == expected)
    #expect(try stored(sbd, viaSetWait, child: setWaitKid) == expected)
    #expect(try stored(sbd, viaSpawn, child: spawnKid) == expected)
  }

  // MARK: The handoff line and the operator's creation

  @Test func sbWaitPrintsTheHandoffLineWhenTheWaitGoesToTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", "--kind", "date", "--until", "1h"], env: inside(c.id))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(r.stdout.contains(Self.handoffLine), "\(r.stdout)")
  }

  @Test(arguments: [["--here", "--kind", "date", "--until", "1h"], ["--kind", "ci"]])
  func sbWaitPrintsNoHandoffLineWhenTheWaitStays(_ flags: [String]) throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let r = try sbd.run(["wait"] + flags, env: inside(c.id))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!r.stdout.contains(Self.handoffLine), "\(r.stdout)")
  }

  @Test func sbWaitFromATerminalPrintsNoHandoffLine() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", c.id, "--kind", "date", "--until", "1h"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!r.stdout.contains(Self.handoffLine), "\(r.stdout)")
  }

  @Test func theFirstHandoffCreatesTheOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)
    try #require(try operators(sbd).isEmpty)

    _ = try waitInside(sbd, c, ["--kind", "date", "--until", "1h"])

    let op = try theOperator(sbd)
    #expect(op.name == Manager.operatorName)
    #expect(op.cwd == sbd.home.managerFolder)
  }

  /// Risk 4: a handoff and `sb operator` at once make one operator, and the wait is on it.
  @Test func aHandoffAndSbOperatorAtOnceMakeOneOperator() throws {
    let sbd = try Instance()
    let c = try conversation(sbd)

    let opening = try BackgroundSb(sbd, ["operator", "--json"])
    let handing = try BackgroundSb(sbd, ["wait", "--json", "--kind", "date", "--until", "1h"], env: inside(c.id))
    let opened = try opening.finish(within: 60)
    let handed = try handing.finish(within: 60)

    try #require(opened.status == 0, "\(opened.stderr)")
    try #require(handed.status == 0, "\(handed.stderr)")
    let openedId = try decode(SessionSummary.self, opened.stdout).id
    let handedId = try decode(SessionSummary.self, handed.stdout).id
    #expect(openedId == handedId)
    #expect(try operators(sbd).map(\.id) == [openedId])
    #expect(try sbd.get(openedId).waits.map(\.handedFrom?.id) == [c.id])
  }

  // MARK: Clearing and resolving follow a handed-off wait (Risk 1)

  /// Two waits handed from `a`, one from `b`, and one that the user set on the operator.
  struct Handed {
    let a: SessionSummary
    let b: SessionSummary
    let op: SessionSummary
    let fromA: [String]
    let fromB: String
    let own: String
  }

  func handed(_ sbd: Instance) throws -> Handed {
    let a = try conversation(sbd, "Conversation A")
    let b = try conversation(sbd, "Conversation B")
    _ = try waitInside(sbd, a, ["--kind", "date", "--until", "1h", "--note", "first"])
    _ = try waitInside(sbd, a, ["--kind", "date", "--until", "2h", "--note", "second"])
    _ = try waitInside(sbd, b, ["--kind", "date", "--until", "1h", "--note", "from b"])
    _ = try sbd.sb("wait", "Operator", "--kind", "date", "--until", "3h", "--note", "own")
    let op = try theOperator(sbd)
    let fromA = op.waits.filter { $0.handedFrom?.id == a.id }.map(\.id)
    let fromB = try #require(op.waits.first { $0.handedFrom?.id == b.id }?.id)
    let own = try #require(op.waits.first { $0.handedFrom == nil }?.id)
    try #require(fromA.count == 2 && op.waits.count == 4, "\(op.waits)")
    return Handed(a: a, b: b, op: op, fromA: fromA, fromB: fromB, own: own)
  }

  @Test func clearWaitWithNoSessionFromAConversationClearsOnlyTheWaitsItHandedOff() throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let mcp = try MCPClient(sbd, env: inside(h.a.id))

    let result = try mcp.call("clear_wait")

    #expect(!result.isError, "\(result.text)")
    #expect(Set(try sbd.get(h.op.id).waits.map(\.id)) == [h.fromB, h.own])
    #expect(try sbd.get(h.a.id).waits.isEmpty)
  }

  @Test func theAnswerToAConversationsClearListsTheClearedIds() throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let here = try waitInside(sbd, h.a, ["--here", "--kind", "date", "--until", "4h", "--note", "here"])
    let aOwn = try #require(here.waits.first { $0.note == "here" }?.id, "\(here.waits)")

    let answer = try #require(JSON.parse(try sbd.sb(["wait", "--json", h.a.id, "--clear"], env: inside(h.a.id))))

    let cleared = (answer["cleared"]?.array ?? []).compactMap(\.string)
    #expect(Set(cleared) == Set(h.fromA + [aOwn]), "\(answer.text)")
    #expect(cleared.count == h.fromA.count + 1)
    #expect(try sbd.get(h.a.id).waits.isEmpty)
  }

  /// How `sb wait --clear` names the conversation that Claude runs in.
  enum ClearNaming: CaseIterable { case byArgument, bySessionVariable }

  @Test(arguments: ClearNaming.allCases)
  func sbWaitClearInAConversationClearsTheWaitsItHandedOff(_ naming: ClearNaming) throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let args = naming == .byArgument ? ["wait", h.a.id, "--clear"] : ["wait", "--clear"]

    let r = try sbd.run(args, env: inside(h.a.id))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(Set(try sbd.get(h.op.id).waits.map(\.id)) == [h.fromB, h.own])
  }

  @Test func clearingAConversationsHandedOffWaitsRecordsTheClearOnTheOperatorWithFrom() throws {
    let sbd = try Instance()
    let h = try handed(sbd)

    _ = try sbd.sb(["wait", h.a.id, "--clear"], env: inside(h.a.id))

    for id in h.fromA {
      let event = try #require(try waitEvent(sbd, h.op.id, "wait-cleared", wait: id))
      #expect(event.data["from"]?.string == h.a.id, "\(event.data.text)")
    }
  }

  @Test func clearWaitNamingOneHandedOffWaitClearsOnlyThatOne() throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let mcp = try MCPClient(sbd, env: inside(h.a.id))

    let result = try mcp.call("clear_wait", ["wait": .string(h.fromA[0])])

    #expect(!result.isError, "\(result.text)")
    #expect(Set(try sbd.get(h.op.id).waits.map(\.id)) == [h.fromA[1], h.fromB, h.own])
  }

  /// A conversation clears only what it handed off, not what another conversation or the user put on the operator.
  @Test(arguments: [false, true]) func aConversationCannotClearAWaitItDidNotHandOff(_ own: Bool) throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let other = own ? h.own : h.fromB

    let error = failure(sbd, "clear-wait", ["session": .string(h.a.id), "wait": .string(other)])

    #expect(error.contains("has no wait"), Comment(rawValue: error))
    #expect(try sbd.get(h.op.id).waits.count == 4)
  }

  @Test func resolveNamingTheConversationResolvesTheHandedOffWaitOnTheOperator() throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let mark = try sbd.lastEventId(h.a.id)
    let target = h.fromA[0]

    try sbd.sb("wait", h.a.id, "--resolve", "the dashboard is green", "--id", target)

    let resumed = try sbd.waitFor(h.op.id, "the operator's turn", timeout: 30) {
      $0.lastReply?.contains("the dashboard is green") == true
    }
    #expect(resumed.lastReply?.contains(#""\#(h.a.name)""#) == true, "\(resumed.lastReply ?? "")")
    #expect(!resumed.waits.contains { $0.id == target })
    #expect(resumed.waits.count == 3)
    let event = try #require(try waitEvent(sbd, h.op.id, "wait-resolved", wait: target))
    #expect(event.data["from"]?.string == h.a.id, "\(event.data.text)")
    #expect(event.data["outcome"]?.string == "the dashboard is green")
    #expect(try sbd.sbdMessages(h.a.id, after: mark).isEmpty)
    #expect(try sbd.get(h.a.id).waits.isEmpty)
  }

  @Test(arguments: [false, true]) func aConversationCannotResolveAWaitItDidNotHandOff(_ own: Bool) throws {
    let sbd = try Instance()
    let h = try handed(sbd)
    let other = own ? h.own : h.fromB

    let error = failure(
      sbd, "resolve-wait", ["session": .string(h.a.id), "wait": .string(other), "outcome": "it happened"])

    #expect(error.contains("has no wait"), Comment(rawValue: error))
    #expect(try sbd.get(h.op.id).waits.count == 4)
  }

  // MARK: The guide

  @Test func theGuideNamesHereAndTheOperator() {
    #expect(Manager.guide.contains("--here"), "\(Manager.guide)")
    #expect(Manager.guide.contains("`here`"), "\(Manager.guide)")
    #expect(Manager.guide.contains("sb operator"), "\(Manager.guide)")
  }
}
