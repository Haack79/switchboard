import Foundation
import SwitchboardCore
import Testing

/// Every interval here is 30 minutes or longer, except in the one test that
/// moves the clock to fire a 1m loop. A schedule comes due only in that test
/// and after a successful `run_schedule`.
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

  /// The tools that act on one schedule by its id.
  enum ScheduleTool: String, CaseIterable {
    case remove = "remove_schedule", edit = "edit_schedule", run = "run_schedule"

    func call(_ mcp: MCPClient, _ row: ScheduleRow) throws -> ToolResult {
      var args: [String: JSON] = ["schedule": .string(row.schedule.id)]
      if self == .edit { args["prompt"] = "check the flags" }
      return try mcp.call(rawValue, args)
    }
  }

  var runNow: ScheduleRunNowTests { ScheduleRunNowTests() }

  func edit(_ mcp: MCPClient, _ row: ScheduleRow, _ change: [String: JSON]) throws -> ToolResult {
    try mcp.call("edit_schedule", change.merging(["schedule": .string(row.schedule.id)]) { $1 })
  }

  func run(_ mcp: MCPClient, _ row: ScheduleRow) throws -> ToolResult {
    try mcp.call("run_schedule", ["schedule": .string(row.schedule.id)])
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

  @Test func editScheduleRequiresAScheduleIdAndTakesAnIntervalAndAPrompt() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let edit = try tool(mcp, "edit_schedule")

    #expect(properties(edit) == ["schedule", "every", "prompt"])
    #expect(required(edit) == ["schedule"])
  }

  @Test func runScheduleRequiresAScheduleId() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let run = try tool(mcp, "run_schedule")

    #expect(properties(run) == ["schedule"])
    #expect(required(run) == ["schedule"])
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

    #expect(listed.map(\.identity) == [added.identity])
    #expect(listed.map { $0.status?.state } == [.active])
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

    #expect(listed.map(\.identity) == [mine.identity])
    #expect(listed.map { $0.status?.state } == [.active])
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

  @Test func editScheduleChangesTheIntervalAndThePromptAndKeepsTheId() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let edited = try edit(mcp, row, ["every": "30m", "prompt": "check the flags"]).decode(ScheduleRow.self)

    #expect(edited.schedule.id == row.schedule.id)
    #expect(edited.schedule.every == MCPScheduleToolTests.thirtyMinutes)
    #expect(edited.schedule.prompt == "check the flags")
    #expect(try stored(sbd, s.id) == [edited.schedule])
  }

  @Test func editScheduleWithOnlyAnIntervalKeepsThePrompt() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let edited = try edit(mcp, row, ["every": "2h"]).decode(ScheduleRow.self)

    #expect(edited.schedule.every == 2 * MCPToolServerTests.hourMs)
    #expect(edited.schedule.prompt == row.schedule.prompt)
  }

  @Test func editScheduleWithOnlyAPromptKeepsTheIntervalAndTheNextRun() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let edited = try edit(mcp, row, ["prompt": "check the flags"]).decode(ScheduleRow.self)

    #expect(edited.schedule.prompt == "check the flags")
    #expect(edited.schedule.every == row.schedule.every)
    #expect(edited.schedule.next == row.schedule.next)
  }

  @Test(arguments: [[:], ["every": "30s"]] as [[String: JSON]])
  func editScheduleWithABadChangeReturnsAnErrorAndKeepsTheSchedule(_ change: [String: JSON]) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let result = try edit(mcp, row, change)

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == [row.schedule])
  }

  @Test(arguments: [["schedule": "rzzzzz", "prompt": "check"], ["prompt": "check"]] as [[String: JSON]])
  func editScheduleWithoutAKnownScheduleReturnsAnError(_ args: [String: JSON]) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("edit_schedule", args)

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == [row.schedule])
  }

  /// The tick may fire the due loop at once, so the test reads the returned row and not the stored one.
  @Test func runScheduleMakesTheLoopDueAndChangesOnlyItsNextRun() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let ran = try run(mcp, row).decode(ScheduleRow.self)

    #expect(ran.schedule.next <= (try sbd.now()))
    #expect(runNow.onlyNextMoved(row.schedule, ran.schedule))
    #expect(ran.status?.state == .due)
    #expect(try runNow.requested(sbd, s.id).count == 1)
  }

  @Test func runScheduleRefusesAPausedLoopAndKeepsItsNextRun() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    try sbd.sb("schedule", "pause", row.schedule.id)
    let paused = try stored(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let result = try run(mcp, row)

    #expect(result.isError)
    #expect(result.text.contains("is paused"), "\(result.text)")
    #expect(try stored(sbd, s.id) == paused)
    #expect(try runNow.requested(sbd, s.id).isEmpty)
  }

  @Test(arguments: [["schedule": "rzzzzz"], [:]] as [[String: JSON]])
  func runScheduleWithoutAKnownScheduleReturnsAnError(_ args: [String: JSON]) throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let row = try schedule(sbd, s.id)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("run_schedule", args)

    #expect(result.isError)
    #expect(try stored(sbd, s.id) == [row.schedule])
    #expect(try runNow.requested(sbd, s.id).isEmpty)
  }

  // MARK: A scoped server

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

    #expect(
      names.isSuperset(of: ["add_schedule", "list_schedules", "remove_schedule", "edit_schedule", "run_schedule"]))
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

  /// sbd refuses each tool through the same scope check, so the chat can't change a schedule outside its group.
  @Test(arguments: Outsider.allCases, ScheduleTool.allCases)
  func aScopedScheduleToolRefusesAScheduleOutsideTheGroup(_ outsider: Outsider, _ tool: ScheduleTool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let target = outsider.session(s)
    let row = try schedule(sbd, target.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let result = try tool.call(mcp, row)

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, target.id) == [row.schedule])
    #expect(try runNow.requested(sbd, target.id).isEmpty)
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
  @Test(arguments: Leave.allCases, ScheduleTool.allCases)
  func aScopedScheduleToolRefusesASessionThatLeftTheGroup(_ leave: Leave, _ tool: ScheduleTool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))
    let seen = try mcp.call("list_schedules").decode([ScheduleRow].self)
    try #require(seen.map(\.schedule.id).contains(row.schedule.id))
    _ = try sbd.client.call("group-move", leave.args(s))

    let result = try tool.call(mcp, row)

    #expect(result.isError)
    #expect(result.text.contains("not in group"), "\(result.text)")
    #expect(try stored(sbd, s.member.id) == [row.schedule])
    #expect(try runNow.requested(sbd, s.member.id).isEmpty)
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

  @Test func aScopedEditScheduleEditsAMembersSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let edited = try edit(mcp, row, ["prompt": "check the flags"]).decode(ScheduleRow.self)

    #expect(edited.schedule.id == row.schedule.id)
    #expect(try stored(sbd, s.member.id) == [edited.schedule])
  }

  /// The chat is never a member of its group, so only the `caller` the server sends lets it edit its own loop.
  @Test func aScopedEditScheduleEditsTheChatsOwnSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let row = try schedule(sbd, c.id)
    let mcp = try chatServer(sbd, s, c)

    let edited = try edit(mcp, row, ["prompt": "check the flags"]).decode(ScheduleRow.self)

    #expect(edited.schedule.id == row.schedule.id)
    #expect(try stored(sbd, c.id) == [edited.schedule])
  }

  @Test func aScopedRunScheduleRunsAMembersSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let row = try schedule(sbd, s.member.id)
    let mcp = try chatServer(sbd, s, try chat(sbd))

    let ran = try run(mcp, row).decode(ScheduleRow.self)

    #expect(ran.schedule.id == row.schedule.id)
    #expect(ran.status?.state == .due)
    #expect(try runNow.requested(sbd, s.member.id).count == 1)
  }

  /// The chat is never a member of its group, so only the `caller` the server sends lets it run its own loop.
  @Test func aScopedRunScheduleRunsTheChatsOwnSchedule() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let c = try chat(sbd)
    let row = try schedule(sbd, c.id)
    let mcp = try chatServer(sbd, s, c)

    let ran = try run(mcp, row).decode(ScheduleRow.self)

    #expect(ran.schedule.id == row.schedule.id)
    #expect(ran.status?.state == .due)
    #expect(try runNow.requested(sbd, c.id).count == 1)
  }

  // MARK: Status and history

  /// `list_schedules` returns the `schedules` rows, so each row's `status` and each fired loop's `runs` reach
  /// agents with no tool change.
  @Test func listSchedulesCarriesEachRowsStatusAndAFiredLoopsRuns() throws {
    let sbd = try Instance()
    let fired = try sbd.idleSession(name: "fired")
    let quiet = try sbd.new(name: "quiet")
    let loop = try decode(ScheduleRow.self, sbd.sb("schedule", fired.id, "--every", "1m", "tick mcp", "--json"))
    _ = try schedule(sbd, quiet.id)
    try sbd.advanceClock(61_000)
    try sbd.waitFor("the run of \(loop.schedule.id)") {
      try sbd.get(fired.id).schedules?.first { $0.id == loop.schedule.id }?.last != nil
    }
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("list_schedules")

    let objects = try #require(result.json?.array)
    #expect(objects.count == 2)
    #expect(objects.allSatisfy { $0["status"]?["state"]?.string != nil }, "\(objects)")
    let listed = try result.decode([ScheduleRow].self)
    let firedRow = try #require(listed.first { $0.schedule.id == loop.schedule.id })
    let quietRow = try #require(listed.first { $0.session == quiet.id })
    #expect(firedRow.schedule.runs?.count == 1)
    #expect(firedRow.schedule.runs?.first == firedRow.schedule.last)
    #expect(quietRow.schedule.runs == nil)
  }
}

extension ScheduleRow {
  /// The row without its status, whose text counts down between two requests.
  fileprivate var identity: ScheduleRow { ScheduleRow(session: session, name: name, schedule: schedule) }
}
