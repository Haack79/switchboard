import Foundation
import SwitchboardCore
import Testing

extension MCPToolServerSuite {
  fileprivate func managerID(_ sbd: Instance) throws -> String {
    try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))
  }
}

/// The `pause` and `resume` tools of an unscoped server, as the Manager has them.
@Suite(.blocking(timeLimit: .seconds(120))) struct MCPPauseToolTests: MCPToolServerSuite {
  @Test func pauseFromTheManagerLabelsTheSessionPausedByManager() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let manager = try managerID(sbd)
    let mcp = try MCPClient(sbd, env: inside(manager))

    let result = try mcp.call("pause", ["session": .string(s.id), "reason": "free CPU"])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["reason"]?.string == "Paused by Manager: free CPU", "\(result.text)")
    let pause = try #require(try sbd.pauseField(s.id))
    #expect(pause["by"] == "claude")
    #expect(pause["from"]?["id"]?.string == manager)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
  }

  @Test func resumeFromTheManagerResumesTheSession() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))
    _ = try mcp.call("pause", ["session": .string(s.id)]).decode(SessionSummary.self)
    try sbd.waitFor(s.id, "the stop") { !$0.live && $0.claudePid == nil }
    let mark = try sbd.lastEventId(s.id)

    let result = try mcp.call("resume", ["session": .string(s.id)])

    #expect(!result.isError, "\(result.text)")
    let prompts = try sbd.waitForPrompts(s.id, after: mark, count: 1)
    #expect(prompts == ["Switchboard: You were paused by Manager. Continue where you left off."])
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.launchEvents(s.id, after: mark).first?.data["trigger"] == "session")
    let unpaused = try #require(try sbd.events(s.id, after: mark).first { $0.kind == "unpaused" })
    #expect(unpaused.data["by"] == "claude")
  }

  @Test func resumeWithAMessageResumesWithIt() throws {
    let sbd = try Instance()
    let s = try sbd.pausedStopped()
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))
    let mark = try sbd.lastEventId(s.id)

    let result = try mcp.call("resume", ["session": .string(s.id), "message": "flags shipped, go on"])

    #expect(!result.isError, "\(result.text)")
    #expect(try sbd.waitForPrompts(s.id, after: mark, count: 1) == ["flags shipped, go on"])
  }

  /// The server passes `until`, `reason`, and `message` to sbd as the CLI does.
  @Test func pauseStoresTheConditionTheReasonAndTheMessage() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call(
      "pause", ["session": .string(s.id), "until": "1h", "reason": "free CPU", "message": "check the dashboard"])

    #expect(!result.isError, "\(result.text)")
    let pause = try #require(try sbd.pauseField(s.id))
    #expect(pause["until"]?["kind"] == "date", "\(pause.text)")
    #expect(pause["reason"] == "free CPU")
    #expect(pause["message"] == "check the dashboard")
  }

  @Test func pauseWithAGroupPausesItsMembers() throws {
    let sbd = try Instance()
    let a = try sbd.liveIdle("alpha")
    let b = try sbd.liveIdle("bravo")
    _ = try addGroup(sbd, "Flags", a.id, b.id)
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("pause", ["group": "Flags"])

    #expect(!result.isError, "\(result.text)")
    #expect(sbd.results(result.json) == [a.id: "paused", b.id: "paused"], "\(result.text)")
    #expect(try sbd.get(a.id).reason == "Paused by Manager")
    #expect(try sbd.get(b.id).reason == "Paused by Manager")
  }

  @Test(arguments: ["30", "soon", "session:", "pr:abc"])
  func pauseWithAnUntilThatSbCannotReadIsAnErrorAndLeavesTheSessionUnpaused(_ until: String) throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("pause", ["session": .string(s.id), "until": .string(until)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("until"), "\(result.text)")
    if until == "30" { #expect(result.text.contains("#30"), "\(result.text)") }
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.get(s.id).live)
  }

  /// The pause would stop the claude that runs the tool call.
  @Test func theCallerPausingItselfIsAnError() throws {
    let sbd = try Instance()
    let s = try sbd.liveIdle()
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("pause", ["session": .string(s.id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("can't pause itself"), "\(result.text)")
    #expect(try sbd.pauseField(s.id) == nil)
    #expect(try sbd.get(s.id).live)
  }

  /// The server sends `by: claude`. Only the user pauses a group chat.
  @Test func theManagerPausingAGroupChatIsAnError() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let chat = try sbd.chatOf("Flags")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("pause", ["session": .string(chat)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("only the user can pause"), "\(result.text)")
    #expect(try sbd.pauseField(chat) == nil)
  }

  /// Exactly one of `session` and `group` names the target.
  enum Target: String, CaseIterable, Sendable { case both, neither }

  @Test(arguments: ["pause", "resume"], Target.allCases)
  func aCallWithBothOrNeitherOfSessionAndGroupIsAnError(_ tool: String, _ target: Target) throws {
    let sbd = try Instance()
    let a = try sbd.pausedStopped("alpha")
    let b = try sbd.liveIdle("bravo")
    _ = try addGroup(sbd, "Flags", b.id)
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))
    let args: [String: JSON] = target == .both ? ["session": .string(a.id), "group": "Flags"] : [:]
    let mark = try sbd.lastEventId(a.id)

    let result = try mcp.call(tool, args)

    #expect(result.isError, "\(result.text)")
    #expect(!result.text.contains("no tool"), "\(result.text)")
    #expect(try sbd.pauseField(a.id) != nil)
    #expect(try sbd.pauseField(b.id) == nil)
    #expect(try sbd.launchEvents(a.id, after: mark).isEmpty)
  }

  @Test func theToolsTakeTheirTargetsAndOptions() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tools = try mcp.tools()

    let pause = try #require(tools.first { $0["name"] == "pause" })
    let resume = try #require(tools.first { $0["name"] == "resume" })
    let pauseKeys = Set((pause["inputSchema"]?["properties"]?.object ?? [:]).keys)
    let resumeKeys = Set((resume["inputSchema"]?["properties"]?.object ?? [:]).keys)
    #expect(pauseKeys.isSuperset(of: ["session", "group", "until", "reason", "message"]), "\(pauseKeys)")
    #expect(resumeKeys.isSuperset(of: ["session", "group", "message"]), "\(resumeKeys)")
  }

  /// The description says that a pause stops claude and holds every message. It also gives each `until` form.
  @Test func thePauseDescriptionSaysItHoldsMessagesAndGivesTheUntilForms() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let pause = try #require(try mcp.tools().first { $0["name"] == "pause" })

    let text = try #require(pause["description"]?.string)
    #expect(text.lowercased().contains("hold"), "\(text)")
    #expect(text.contains("session:"), "\(text)")
    #expect(text.contains("#"), "\(text)")
  }
}

/// `pause` and `resume` in a server scoped to group Flags, and sbd's own check of the `scope` that such a server
/// sends. Flags holds `member`, Billing holds `outside`, and `loose` is in no group.
@Suite(.blocking(timeLimit: .seconds(120))) struct MCPPauseToolTestsInAScope: MCPToolServerSuite {
  /// The scope and the Flags chat, whose claude runs the scoped server.
  private func scopeWithChat(_ sbd: Instance) throws -> (scope: Scope, chat: String) {
    let s = try scope(sbd)
    return (s, try sbd.chatOf("Flags"))
  }

  private func scopedClient(_ sbd: Instance, _ s: Scope, chat: String) throws -> MCPClient {
    try MCPClient(sbd, group: s.group.id, env: inside(chat))
  }

  // MARK: The scoped tools

  @Test func aScopedPauseOfAMemberShowsPausedByTheGroupChat() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["session": .string(s.member.name)])

    #expect(!result.isError, "\(result.text)")
    #expect(try sbd.get(s.member.id).reason == "Paused by the Flags chat")
  }

  enum Outsider: String, CaseIterable, Sendable { case outside, loose }

  @Test(arguments: Outsider.allCases, Naming.allCases)
  func aScopedPauseRefusesASessionOutsideTheGroupHoweverItIsNamed(_ who: Outsider, _ how: Naming) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let target = who == .outside ? s.outside : s.loose
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["session": .string(name(target.id, target.name, how))])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not in group"), "\(result.text)")
    #expect(try sbd.pauseField(target.id) == nil)
  }

  /// A ref that matches no session gets the same refusal as one outside the group.
  @Test(arguments: ["outside", "loose", "no-such-session"])
  func aScopedPauseRefusesAnUntilSessionOutsideTheGroup(_ who: String) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let ref = who == "outside" ? s.outside.name : who == "loose" ? s.loose.name : who
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["session": .string(s.member.name), "until": .string("session:\(ref)")])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("--until \(ref) is not in group"), "\(result.text)")
    #expect(try sbd.pauseField(s.member.id) == nil)
  }

  @Test func aScopedPauseTakesAnUntilSessionThatIsTheCaller() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["session": .string(s.member.name), "until": .string("session:\(chat)")])

    #expect(!result.isError, "\(result.text)")
    #expect(try sbd.pauseField(s.member.id) != nil)
  }

  @Test func aScopedPauseRefusesTheManager() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let manager = try managerID(sbd)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["session": .string(manager)])

    #expect(result.isError, "\(result.text)")
    #expect(!result.text.contains("no tool"), "\(result.text)")
    #expect(try sbd.pauseField(manager) == nil)
  }

  @Test func aScopedPauseOfItsOwnGroupPausesOnlyTheMembers() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["group": "Flags"])

    #expect(!result.isError, "\(result.text)")
    #expect(sbd.results(result.json) == [s.member.id: "paused"], "\(result.text)")
    #expect(try sbd.pauseField(s.member.id) != nil)
    for id in [s.outside.id, s.loose.id, chat] {
      #expect(try sbd.pauseField(id) == nil, "\(id)")
    }
  }

  @Test(arguments: Naming.allCases)
  func aScopedPauseRefusesAnotherGroupHoweverItIsNamed(_ how: Naming) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("pause", ["group": .string(name(s.other.id, s.other.name, how))])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not group"), "\(result.text)")
    #expect(try sbd.pauseField(s.outside.id) == nil)
  }

  @Test func aScopedResumeResumesAMember() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    try sbd.pauseJSON(s.member.id)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("resume", ["session": .string(s.member.id)])

    #expect(!result.isError, "\(result.text)")
    #expect(try sbd.pauseField(s.member.id) == nil)
  }

  @Test(arguments: Outsider.allCases)
  func aScopedResumeRefusesASessionOutsideTheGroupAndLeavesItPaused(_ who: Outsider) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let target = who == .outside ? s.outside : s.loose
    try sbd.pauseJSON(target.id)
    let mark = try sbd.lastEventId(target.id)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("resume", ["session": .string(target.id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not in group"), "\(result.text)")
    #expect(try sbd.pauseField(target.id) != nil)
    #expect(try sbd.launchEvents(target.id, after: mark).isEmpty)
  }

  @Test func aScopedResumeRefusesAnotherGroupAndLeavesItsMembersPaused() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    try sbd.pauseJSON(s.outside.id)
    let mcp = try scopedClient(sbd, s, chat: chat)

    let result = try mcp.call("resume", ["group": "Billing"])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not group"), "\(result.text)")
    #expect(try sbd.pauseField(s.outside.id) != nil)
  }

  // MARK: sbd's own check of the scope

  /// A request as the scoped server sends it, with `scope`, `caller`, `from`, and `by`.
  private func scoped(_ s: Scope, caller: String, _ args: [String: JSON]) -> [String: JSON] {
    args.merging([
      "scope": .string(s.group.id), "caller": .string(caller), "from": .string(caller), "by": "claude",
    ]) { $1 }
  }

  /// The positive control of the refusals below: sbd acts on a member when the request carries the scope.
  @Test(arguments: ["pause", "resume"])
  func sbdActsOnAMemberForARequestWithTheScope(_ op: String) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    if op == "resume" { try sbd.pauseJSON(s.member.id) }

    _ = try sbd.client.call(op, scoped(s, caller: chat, ["session": .string(s.member.id)]))

    let paused = try sbd.pauseField(s.member.id) != nil
    #expect(paused == (op == "pause"))
  }

  /// Every way that a scoped request can reach a session outside the scope. The server's own check doesn't run
  /// here, so only sbd's check stands between the request and the session.
  enum OutOfScope: String, CaseIterable, Sendable {
    case outside, loose, manager
    /// The other group by its id, through `group`.
    case otherGroup
    /// The other group's name as a session ref, which no session has, so sbd falls back to the group.
    case otherGroupAsSessionRef
    /// A member that moved out of the group after the server looked it up.
    case memberMovedOut
    /// The caller is `loose`, which is outside the group. The caller's own id is in scope, and no other session is.
    case outsideWithAnUngroupedCaller
  }

  /// The request's args, its caller, and the sessions that it must leave alone.
  private func outOfScope(_ sbd: Instance, _ s: Scope, chat: String, _ shape: OutOfScope) throws -> (
    args: [String: JSON], caller: String, untouched: [String]
  ) {
    switch shape {
    case .outside: return (["session": .string(s.outside.id)], chat, [s.outside.id])
    case .loose: return (["session": .string(s.loose.id)], chat, [s.loose.id])
    case .manager:
      let manager = try managerID(sbd)
      return (["session": .string(manager)], chat, [manager])
    case .otherGroup: return (["group": .string(s.other.id)], chat, [s.outside.id])
    case .otherGroupAsSessionRef: return (["session": .string(s.other.name)], chat, [s.outside.id])
    case .memberMovedOut:
      try sbd.sb("group", "move", s.member.id, "--ungrouped")
      return (["session": .string(s.member.id)], chat, [s.member.id])
    case .outsideWithAnUngroupedCaller: return (["session": .string(s.outside.id)], s.loose.id, [s.outside.id])
    }
  }

  @Test(arguments: OutOfScope.allCases)
  func sbdRefusesAScopedPauseOutsideTheScope(_ shape: OutOfScope) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let request = try outOfScope(sbd, s, chat: chat, shape)

    let error = failure(sbd, "pause", scoped(s, caller: request.caller, request.args))

    #expect(error != "no error")
    #expect(
      !error.contains("no session") && !error.contains("name a session"),
      "the request failed before the scope check: \(error)")
    for id in request.untouched {
      #expect(try sbd.pauseField(id) == nil, "\(id): \(error)")
      #expect(try !sbd.events(id).contains { $0.kind == "paused" }, "\(id)")
    }
  }

  @Test(arguments: OutOfScope.allCases)
  func sbdRefusesAScopedResumeOutsideTheScope(_ shape: OutOfScope) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    let request = try outOfScope(sbd, s, chat: chat, shape)
    for id in request.untouched { try sbd.pauseJSON(id) }

    let error = failure(sbd, "resume", scoped(s, caller: request.caller, request.args))

    #expect(error != "no error")
    #expect(
      !error.contains("no session") && !error.contains("name a session"),
      "the request failed before the scope check: \(error)")
    for id in request.untouched {
      #expect(try sbd.pauseField(id) != nil, "\(id): \(error)")
      #expect(try !sbd.events(id).contains { $0.kind == "unpaused" }, "\(id)")
    }
  }

  /// A `scope` that isn't a group id fails closed rather than lifting the check.
  @Test(arguments: ["pause", "resume"])
  func sbdRefusesAScopeThatIsNotAString(_ op: String) throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    try sbd.pauseJSON(s.outside.id)
    var request = scoped(s, caller: chat, ["session": .string(op == "pause" ? s.loose.id : s.outside.id)])
    request["scope"] = .number(1)

    let error = failure(sbd, op, request)

    #expect(error.contains("scope"), "\(error)")
    #expect(try sbd.pauseField(s.loose.id) == nil)
    #expect(try sbd.pauseField(s.outside.id) != nil)
  }

  /// A request may act on its caller as well as on the members. The chat can't pause itself, so this applies only
  /// to a resume.
  @Test func sbdResumesTheCallerItselfForARequestWithTheScope() throws {
    let sbd = try Instance()
    let (s, chat) = try scopeWithChat(sbd)
    try sbd.pauseJSON(chat)

    _ = try sbd.client.call("resume", scoped(s, caller: chat, ["session": .string(chat)]))

    #expect(try sbd.pauseField(chat) == nil)
  }
}
