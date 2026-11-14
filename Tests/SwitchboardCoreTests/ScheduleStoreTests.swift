import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ScheduleStoreTests {
  static let created: Int64 = 1_800_000_000_000

  static func session() throws -> Session {
    var s = Session(id: "s1", name: "manager", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
    var ran = try ScheduleRequest(every: "30m", prompt: "/audit-waiting", by: "claude").makeSchedule(
      id: "rk3x9p", now: created)
    ran.last = Schedule.Run(t: created + 1, outcome: .failed, skipped: 2, error: "the folder /tmp/a is gone")
    var paused = try ScheduleRequest(every: "1h", prompt: "check the queue", by: nil).makeSchedule(
      id: "r2mzq4", now: created)
    paused.paused = true
    s.schedules = [ran, paused]
    return s
  }

  /// The text of every row in the database, as sqlite3 dumps it.
  static func dump(_ path: String) throws -> String {
    let r = try runCommand("/usr/bin/sqlite3", [path, ".dump"])
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    return r.stdout
  }

  @Test func savedSchedulesComeBackFromANewConnection() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let s = try Self.session()
    try Store(path: "\(dir)/sb.db").save(s)

    let sessions = try Store(path: "\(dir)/sb.db").sessions()

    #expect(sessions == [s])
    #expect(sessions.first?.schedules == s.schedules)
  }

  @Test func savingASessionWithNoSchedulesLeavesThemNil() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = try Self.session()
    s.schedules = nil
    try Store(path: "\(dir)/sb.db").save(s)

    #expect(try Store(path: "\(dir)/sb.db").sessions().first?.schedules == nil)
  }

  @Test func deletingTheSessionLeavesNoRowThatHoldsItsSchedules() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = try Self.session()
    try store.save(s)
    try #require(try Self.dump("\(dir)/sb.db").contains("rk3x9p"))

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    #expect(try store.sessions().isEmpty)
    let dump = try Self.dump("\(dir)/sb.db")
    for schedule in s.schedules ?? [] {
      #expect(!dump.contains(schedule.id))
      #expect(!dump.contains(schedule.prompt))
    }
  }

  @Test func deletingOneSessionKeepsAnotherSessionsSchedules() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = try Self.session()
    var other = Session(id: "s2", name: "flags", cwd: "/tmp/b", claudeSessionId: "u2", created: 6)
    other.schedules = [
      try ScheduleRequest(every: "2h", prompt: "look at the flags", by: nil).makeSchedule(
        id: "rp7hw3", now: Self.created)
    ]
    try store.save(s)
    try store.save(other)

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    #expect(try store.sessions() == [other])
  }
}
