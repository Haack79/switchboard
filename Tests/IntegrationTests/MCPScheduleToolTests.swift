import Foundation
import SwitchboardCore
import Testing

/// Every interval here is 30 minutes or longer. No test moves the clock. No
/// schedule comes due while a test runs.
@Suite(.blocking(timeLimit: .seconds(120))) struct MCPScheduleToolTests: MCPToolServerSuite {
  static let thirtyMinutes: Int64 = 1_800_000

  /// Adds a schedule through `sb schedule`, which the tools under test do not touch.
  func schedule(_ sbd: Instance, _ session: String, _ prompt: String = "check the queue") throws -> ScheduleRow {
    try decode(ScheduleRow.self, sbd.sb("schedule", session, "--every", "1h", prompt, "--json"))
  }

  func stored(_ sbd: Instance, _ session: String) throws -> [Schedule]? { try sbd.get(session).schedules }

  func tool(_ mcp: MCPClient, _ name: String) throws -> JSON {
    try #require(try mcp.tools().first { $0["name"]?.string == name }, "no tool \(name)")
  }

  func properties(_ tool: JSON) -> Set<String> { Set((tool["inputSchema"]?["properties"]?.object ?? [:]).keys) }

  func required(_ tool: JSON) -> Set<String> {
    Set((tool["inputSchema"]?["required"]?.array ?? []).compactMap(\.string))
  }

  // MARK: The tool definitions

  @Test func addScheduleTakesASessionAndRequiresAnIntervalAndAPrompt() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let add = try tool(mcp, "add_schedule")

    #expect(properties(add) == ["session", "every", "prompt"])
    #expect(required(add) == ["every", "prompt"])
  }

  @Test func listSchedulesTakesAnOptionalSession() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let list = try tool(mcp, "list_schedules")

    #expect(properties(list) == ["session"])
    #expect(required(list).isEmpty)
  }

  @Test func removeScheduleRequiresAScheduleId() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let remove = try tool(mcp, "remove_schedule")

    #expect(properties(remove) == ["schedule"])
    #expect(required(remove) == ["schedule"])
  }

  @Test func addScheduleDescriptionStatesTheShortestInterval() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let add = try tool(mcp, "add_schedule")

    #expect(add["description"]?.string?.contains("1m") == true)
  }

  // MARK: An unscoped server

  @Test func addScheduleWithoutASessionSchedulesTheCallerByClaude() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "manager")
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let row = try mcp.call("add_schedule", ["every": "30m", "prompt": "check the queue"]).decode(ScheduleRow.self)

    #expect(row.session == s.id)
    #expect(row.schedule.by == .claude)
    #expect(row.schedule.every == MCPScheduleToolTests.thirtyMinutes)
    #expect(row.schedule.prompt == "check the queue")
    #expect(try stored(sbd, s.id) == [row.schedule])
  }

  /// The server sets the author itself, so it does not depend on CLAUDECODE.
  @Test func addScheduleThatNamesASessionIsByClaudeOutsideASession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let row = try mcp.call("add_schedule", ["session": "alpha", "every": "1h", "prompt": "check"]).decode(
      ScheduleRow.self)

    #expect(row.session == s.id)
    #expect(row.schedule.by == .claude)
  }

  @Test func addScheduleKeepsASlashCommandPromptVerbatim() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let row = try mcp.call("add_schedule", ["every": "1h", "prompt": "/audit-waiting"]).decode(ScheduleRow.self)

    #expect(row.schedule.prompt == "/audit-waiting")
  }

  /// An unscoped server sends no `group`, so a grouped session takes a schedule.
  @Test func anUnscopedAddScheduleWorksOnASessionInAGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd)

    let row = try mcp.call("add_schedule", ["session": .string(s.outside.id), "every": "1h", "prompt": "check"])
      .decode(ScheduleRow.self)

    #expect(row.session == s.outside.id)
    #expect(try stored(sbd, s.outside.id) == [row.schedule])
  }

  @Test func addScheduleWithoutASessionOrACallerReturnsAnError() throws {
    let sbd = try Instance()
    _ = try sbd.new()
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("add_schedule", ["every": "1h", "prompt": "check"])

    #expect(result.isError)
    #expect(result.text.contains("session"), "\(result.text)")
    #expect(try sbd.client.call("schedules", as: [ScheduleRow].self).isEmpty)
  }

  @Test(arguments: ["30s", "59s", "0m", "soon", "30", "1h30m", "30M", "99999999999999w"])
  func addScheduleWithABadIntervalReturnsAnError(_ every: String) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("add_schedule", ["every": .string(every), "prompt": "check"])

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == nil)
  }

  @Test func addScheduleUnderOneMinuteReturnsTheShortestInterval() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("add_schedule", ["every": "30s", "prompt": "check"])

    #expect(result.isError)
    #expect(result.text.contains("the shortest interval is 1m"), "\(result.text)")
  }

  @Test(
    arguments: [
      ["prompt": "check"], ["every": "1h"], ["every": "1h", "prompt": ""], ["every": "1h", "prompt": " \n "],
    ]
      as [[String: JSON]])
  func addScheduleWithoutAnIntervalOrAPromptReturnsAnError(_ args: [String: JSON]) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))

    let result = try mcp.call("add_schedule", args)

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == nil)
  }

  @Test func listSchedulesShowsAScheduleThatAddScheduleAdded() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))
    let added = try mcp.call("add_schedule", ["every": "1h", "prompt": "check"]).decode(ScheduleRow.self)

    let listed = try mcp.call("list_schedules").decode([ScheduleRow].self)

    #expect(listed == [added])
  }

  /// Rows on grouped and ungrouped sessions, as `sb schedule ls --json` prints them.
  @Test func anUnscopedListSchedulesReturnsTheJSONThatSbPrints() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    for session in [s.member, s.outside, s.loose] { _ = try schedule(sbd, session.id) }
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("list_schedules")

    #expect(!result.isError)
    #expect(try result.decode([ScheduleRow].self).count == 3)
    #expect(result.json == JSON.parse(try sbd.sb("schedule", "ls", "--json")))
  }

  @Test(arguments: Naming.allCases) func listSchedulesWithASessionListsOnlyThatSessionsRows(_ how: Naming) throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let mine = try schedule(sbd, a.id)
    _ = try schedule(sbd, b.id)
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("list_schedules", ["session": .string(name(a.id, "alpha", how))]).decode(
      [ScheduleRow].self)

    #expect(listed == [mine])
  }

  @Test func removeScheduleRemovesTheScheduleAndReturnsIt() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let mcp = try MCPClient(sbd, env: inside(s.id))
    let added = try mcp.call("add_schedule", ["every": "1h", "prompt": "check"]).decode(ScheduleRow.self)

    let removed = try mcp.call("remove_schedule", ["schedule": .string(added.schedule.id)]).decode(ScheduleRow.self)

    #expect(removed.schedule.id == added.schedule.id)
    #expect(try stored(sbd, s.id) == nil)
    #expect(try mcp.call("list_schedules").decode([ScheduleRow].self).isEmpty)
  }

  @Test func removeScheduleKeepsTheSessionsOtherSchedules() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let gone = try schedule(sbd, s.id, "gone")
    let kept = try schedule(sbd, s.id, "kept")
    let mcp = try MCPClient(sbd)

    _ = try mcp.call("remove_schedule", ["schedule": .string(gone.schedule.id)]).decode(ScheduleRow.self)

    #expect(try stored(sbd, s.id) == [kept.schedule])
  }

  /// An unscoped server sends no `group`, so a grouped session's schedule can be removed.
  @Test func anUnscopedRemoveScheduleWorksOnASessionInAGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try MCPClient(sbd)

    let removed = try mcp.call("remove_schedule", ["schedule": .string(row.schedule.id)]).decode(ScheduleRow.self)

    #expect(removed.schedule.id == row.schedule.id)
    #expect(try stored(sbd, s.member.id) == nil)
  }

  @Test func removeScheduleOfAnUnknownIdReturnsAnError() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("remove_schedule", ["schedule": "rzzzzz"])

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == [row.schedule])
  }

  // MARK: A scoped server

  /// A session outside the scope's group Flags.
  enum Outsider: String, CaseIterable {
    case otherGroup, ungrouped

    func session(_ s: Scope) -> SessionSummary {
      switch self {
      case .otherGroup: s.outside
      case .ungrouped: s.loose
      }
    }
  }

  /// How `member` leaves the group Flags.
  enum Leave: String, CaseIterable {
    case toUngrouped, toAnotherGroup

    func args(_ s: Scope) -> [String: JSON] {
      switch self {
      case .toUngrouped: ["sessions": [.string(s.member.id)], "ungrouped": true]
      case .toAnotherGroup: ["sessions": [.string(s.member.id)], "group": .string(s.other.id)]
      }
    }
  }

  /// The group chat of Flags. A chat is never a member of its group.
  func chat(_ sbd: Instance) throws -> SessionSummary {
    try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))
  }

  /// The server that the chat of Flags runs.
  func chatServer(_ sbd: Instance, _ s: Scope, _ chat: SessionSummary) throws -> MCPClient {
    try MCPClient(sbd, group: s.group.id, env: inside(chat.id))
  }

  @Test func aScopedServerOffersTheScheduleTools() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let names = Set(try mcp.toolNames())

    #expect(names.isSuperset(of: ["add_schedule", "list_schedules", "remove_schedule"]))
  }

  @Test(arguments: Naming.allCases) func aScopedAddScheduleWorksOnAMember(_ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let row = try mcp.call(
      "add_schedule", ["session": .string(name(s.member.id, "member", how)), "every": "1h", "prompt": "check"]
    ).decode(ScheduleRow.self)

    #expect(row.session == s.member.id)
    #expect(row.schedule.by == .claude)
    #expect(try stored(sbd, s.member.id) == [row.schedule])
  }

  @Test(arguments: Outsider.allCases, Naming.allCases)
  func aScopedAddScheduleRefusesASessionOutsideTheGroup(_ outsider: Outsider, _ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let target = outsider.session(s)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let result = try mcp.call(
      "add_schedule", ["session": .string(name(target.id, target.name, how)), "every": "1h", "prompt": "check"])

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, target.id) == nil)
  }

  @Test func aScopedAddScheduleWithoutASessionSchedulesTheChatItself() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let mcp = try chatServer(sbd, s, c)

    let row = try mcp.call("add_schedule", ["every": "1h", "prompt": "check"]).decode(ScheduleRow.self)

    #expect(row.session == c.id)
    #expect(row.schedule.by == .claude)
    #expect(try stored(sbd, c.id) == [row.schedule])
  }

  @Test func aScopedAddScheduleThatNamesTheChatByIdSchedulesTheChat() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let mcp = try chatServer(sbd, s, c)

    let row = try mcp.call("add_schedule", ["session": .string(c.id), "every": "1h", "prompt": "check"]).decode(
      ScheduleRow.self)

    #expect(row.session == c.id)
  }

  @Test func aScopedListSchedulesHasOnlyTheMembersAndTheChatsRows() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let member = try schedule(sbd, s.member.id)
    let own = try schedule(sbd, c.id)
    _ = try schedule(sbd, s.outside.id)
    _ = try schedule(sbd, s.loose.id)
    let mcp = try chatServer(sbd, s, c)

    let listed = try mcp.call("list_schedules").decode([ScheduleRow].self)

    #expect(Set(listed.map(\.schedule.id)) == [member.schedule.id, own.schedule.id])
  }

  /// The server may refuse the session or list nothing. It never lists the session's rows.
  @Test(arguments: Outsider.allCases)
  func aScopedListSchedulesOfASessionOutsideTheGroupListsNoneOfItsRows(_ outsider: Outsider) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let target = outsider.session(s)
    let row = try schedule(sbd, target.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let result = try mcp.call("list_schedules", ["session": .string(target.id)])

    #expect(!result.text.contains(row.schedule.id), "\(result.text)")
    if !result.isError { #expect(try result.decode([ScheduleRow].self).isEmpty) }
  }

  @Test(arguments: Outsider.allCases)
  func aScopedRemoveScheduleRefusesAScheduleOutsideTheGroup(_ outsider: Outsider) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let target = outsider.session(s)
    let row = try schedule(sbd, target.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let result = try mcp.call("remove_schedule", ["schedule": .string(row.schedule.id)])

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, target.id) == [row.schedule])
  }

  @Test func aScopedRemoveScheduleRemovesAMembersSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let removed = try mcp.call("remove_schedule", ["schedule": .string(row.schedule.id)]).decode(ScheduleRow.self)

    #expect(removed.schedule.id == row.schedule.id)
    #expect(try stored(sbd, s.member.id) == nil)
  }

  @Test func aScopedRemoveScheduleRemovesTheChatsOwnSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let row = try schedule(sbd, c.id)
    let mcp = try chatServer(sbd, s, c)

    let removed = try mcp.call("remove_schedule", ["schedule": .string(row.schedule.id)]).decode(ScheduleRow.self)

    #expect(removed.schedule.id == row.schedule.id)
    #expect(try stored(sbd, c.id) == nil)
  }

  @Test func aScopedRemoveScheduleOfAnUnknownIdReturnsAnError() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let result = try mcp.call("remove_schedule", ["schedule": "rzzzzz"])

    #expect(result.isError)
    #expect(try stored(sbd, s.member.id) == [row.schedule])
  }

  /// The chat listed `member`'s schedule, and then `member` left the group.
  @Test(arguments: Leave.allCases)
  func aScopedRemoveScheduleRefusesASessionThatLeftTheGroup(_ leave: Leave) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))
    let seen = try mcp.call("list_schedules").decode([ScheduleRow].self)
    try #require(seen.map(\.schedule.id).contains(row.schedule.id))
    _ = try sbd.client.call("group-move", leave.args(s))

    let result = try mcp.call("remove_schedule", ["schedule": .string(row.schedule.id)])

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, s.member.id) == [row.schedule])
  }

  @Test(arguments: Leave.allCases)
  func aScopedListSchedulesLeavesOutASessionThatLeftTheGroup(_ leave: Leave) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))
    _ = try sbd.client.call("group-move", leave.args(s))

    let listed = try mcp.call("list_schedules").decode([ScheduleRow].self)

    #expect(!listed.map(\.schedule.id).contains(row.schedule.id))
  }

  @Test(arguments: Leave.allCases)
  func aScopedAddScheduleRefusesASessionThatLeftTheGroup(_ leave: Leave) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try chatServer(sbd, s, try chat(sbd))
    _ = try sbd.client.call("group-move", leave.args(s))

    let result = try mcp.call("add_schedule", ["session": .string(s.member.id), "every": "1h", "prompt": "check"])

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, s.member.id) == nil)
  }
}
