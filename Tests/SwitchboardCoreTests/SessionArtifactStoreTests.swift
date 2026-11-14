import Foundation
import Testing

@testable import SwitchboardCore

/// A removal whose session kept artifacts saves its group in the same transaction that deletes the session.
/// `checkDeletable` runs the same statements, so a group save that fails stops `sb rm` before it stops any pane or
/// removes the worktree (Risk 4).
@Suite struct SessionArtifactRemovalStoreTests {
  static let session = Session(id: "s1", name: "flags-cache", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)

  static let before: SessionGroup = {
    var g = SessionGroup(id: "g1", name: "Flags", created: 1)
    g.artifacts = [
      GroupArtifact(
        url: "https://claude.ai/artifact/OlderPage", artifactId: nil, title: "Older", published: 100, updated: 200,
        removed: nil, session: "gone", sessionName: "removed-earlier")
    ]
    return g
  }()

  /// The group as `Service.removal` builds it: its kept rows plus the session's artifacts.
  static let after: SessionGroup = {
    var g = before
    g.artifacts! += [
      GroupArtifact(
        url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates", published: 1000, updated: 2000,
        removed: nil, session: session.id, sessionName: session.name)
    ]
    return g
  }()

  static let removal = SessionRemoval(id: session.id, name: session.name, group: after)

  /// Saves the session with an event and a snapshot, and its group without the session's rows.
  static func seed(_ store: Store) throws {
    try store.save(session)
    try store.append(Event(session: session.id, t: 1, kind: "SessionStart"))
    try store.save(snapshot: "{}", session: session.id)
    try store.save(group: before)
  }

  @Test func deleteSavesTheGroupWithTheKeptRows() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)

    try store.delete(session: Self.removal)

    let reopened = try Store(path: "\(dir)/sb.db")
    #expect(try reopened.groups() == [Self.after])
    #expect(try reopened.sessions().isEmpty)
    #expect(try reopened.removedSessions().map(\.id) == [Self.session.id])
  }

  @Test func deleteWithoutAGroupLeavesTheGroupsAsTheyWere() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)

    try store.delete(session: SessionRemoval(id: Self.session.id, name: Self.session.name))

    #expect(try store.groups() == [Self.before])
    #expect(try store.sessions().isEmpty)
  }

  @Test func checkDeletableWithAGroupLeavesTheGroupAndTheSession() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)

    try store.checkDeletable(session: Self.removal)

    let reopened = try Store(path: "\(dir)/sb.db")
    #expect(try reopened.groups() == [Self.before])
    #expect(try reopened.sessions() == [Self.session])
    #expect(try reopened.removedSessions().isEmpty)
  }

  /// The check and the delete run the same statements, so a group save that fails throws from both.
  @Test(arguments: ["checkDeletable", "delete"])
  func aRemovalWhoseGroupSaveFailsThrowsAndChangesNothing(_ call: String) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)
    try ResolvedTodoStoreTests.block("INSERT", on: "groups", in: "\(dir)/sb.db")

    #expect(throws: APIError.self) {
      if call == "delete" {
        try store.delete(session: Self.removal)
      } else {
        try store.checkDeletable(session: Self.removal)
      }
    }

    let reopened = try Store(path: "\(dir)/sb.db")
    #expect(try reopened.sessions() == [Self.session])
    #expect(try reopened.events(session: Self.session.id).count == 1)
    #expect(try reopened.snapshot(session: Self.session.id) == "{}")
    #expect(try reopened.groups() == [Self.before])
    #expect(try reopened.removedSessions().isEmpty)
  }

  /// A removal without a group writes no group, so the blocked save does not stop it.
  @Test func aRemovalWithoutAGroupIgnoresABlockedGroupSave() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)
    try ResolvedTodoStoreTests.block("INSERT", on: "groups", in: "\(dir)/sb.db")
    let plain = SessionRemoval(id: Self.session.id, name: Self.session.name)

    try store.checkDeletable(session: plain)
    try store.delete(session: plain)

    #expect(try store.sessions().isEmpty)
    #expect(try store.groups() == [Self.before])
  }

  /// A statement that fails after the group save rolls the group save back too.
  @Test(arguments: [("DELETE", "sessions"), ("DELETE", "events"), ("INSERT", "removed_sessions")])
  func aRemovalThatFailsAfterTheGroupSaveLeavesTheGroupAsItWas(_ statement: String, _ table: String) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try Self.seed(store)
    try ResolvedTodoStoreTests.block(statement, on: table, in: "\(dir)/sb.db")

    #expect(throws: APIError.self) { try store.delete(session: Self.removal) }

    let reopened = try Store(path: "\(dir)/sb.db")
    #expect(try reopened.groups() == [Self.before])
    #expect(try reopened.sessions() == [Self.session])
  }
}
