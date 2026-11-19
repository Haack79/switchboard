import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

// These tests never move `Clock`, because it is global to the test process.

private let sessionId = "s1"

/// A `Service` in a temporary home that never loads, so it starts no tmux server, no claude, and no poller. Its
/// config names the host `mini`, whose link connects only when a request waits for it.
final class FailedRemovalHarness {
  let home: Home
  let service: Service

  init() throws {
    home = Home(path: try makeShortTempFolder())
    let config: JSON = [
      "claude": "/usr/bin/false", "tmux": "/usr/bin/true", "ssh": .string(LinkBench.stub),
      "hosts": ["mini": ["kind": "ssh", "destination": .string(LinkBench.destination)]],
    ]
    try config.text.write(toFile: home.config, atomically: true, encoding: .utf8)
    service = try Service(home: home, sbPath: "/usr/bin/true")
  }

  deinit {
    for link in service.hostLinks.values { link.disconnect() }
    try? FileManager.default.removeItem(atPath: home.path)
  }

  /// The session's folder under the home. It exists unless `create` is false.
  func folder(_ id: String = sessionId, create: Bool = true) throws -> String {
    let path = "\(home.path)/work/\(id)"
    if create { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    return path
  }

  /// The path where a removal moves the session's folder.
  func trashPath(_ id: String = sessionId) -> String { "\(home.path)/trash/\(id)" }

  /// Saves the session to the store and adds it to the service.
  func add(_ session: Session) throws {
    try service.store.save(session)
    service.queue.sync { service.entries[session.id] = Service.Entry(session: session) }
  }

  /// Records an event for the session as sbd records every event, through `fold`.
  func record(_ trigger: DropEvent, _ id: String = sessionId) {
    service.queue.sync { _ = service.record(id, trigger.kind, trigger.data) }
  }

  func session(_ id: String = sessionId) -> Session? { service.queue.sync { service.entries[id]?.session } }

  func removal(_ id: String = sessionId) -> Removal? { session(id)?.removal }

  /// The session as the store holds it, which is what a restart loads.
  func stored(_ id: String = sessionId) throws -> Session? {
    try Store(path: home.database).sessions().first { $0.id == id }
  }

  func summary(_ id: String = sessionId) -> SessionSummary { service.queue.sync { service.summary(id) } }

  /// The `rm-keep` request. It runs off the state queue, as a client's request does.
  func keep(_ id: String = sessionId) -> Response {
    service.handle(Request(op: "rm-keep", args: ["session": .string(id)]))
  }
}

/// A work session that started, with its folder at `cwd`.
private func workSession(_ id: String = sessionId, cwd: String, host: String? = nil, removal: Removal?) -> Session {
  var s = Session(id: id, name: "dirty-\(id)", cwd: cwd, claudeSessionId: "c-\(id)", created: 5)
  s.started = true
  s.host = host
  s.removal = removal
  return s
}

/// A removal in `state` that the user queued with Done's delete icon, as `rm-queue` records it.
private func makeRemoval(
  _ state: Removal.State, error: String? = "the worktree has uncommitted files: notes.txt", trash: String? = nil,
  released: Bool = false, worktree: Bool = true, branch: Bool = true, remoteBranch: Bool = false,
  resolve: [String] = []
) -> Removal {
  var r = Removal(
    requested: 1_000, notBefore: 1_000, worktree: worktree, branch: branch, remoteBranch: remoteBranch,
    resolve: resolve)
  r.state = state
  r.error = state == .failed ? error : nil
  r.trash = trash
  r.released = released
  return r
}

/// An event that sbd records for a session, as `record` takes it.
struct DropEvent: Sendable, CustomTestStringConvertible {
  let name: String
  let kind: String
  let data: JSON

  var testDescription: String { name }

  static func prompt(_ text: String, name: String, agent: String? = nil) -> DropEvent {
    var data: [String: JSON] = [
      "hook_event_name": "UserPromptSubmit", "session_id": .string("c-\(sessionId)"), "prompt": .string(text),
    ]
    if let agent { data["agent_id"] = .string(agent) }
    return DropEvent(name: name, kind: "UserPromptSubmit", data: .object(data))
  }

  static func hook(_ kind: String, _ extra: [String: JSON] = [:]) -> DropEvent {
    let data: [String: JSON] = ["hook_event_name": .string(kind), "session_id": .string("c-\(sessionId)")]
    return DropEvent(name: kind, kind: kind, data: .object(data.merging(extra) { $1 }))
  }

  static func launch(_ kind: String, trigger: LaunchTrigger) -> DropEvent {
    DropEvent(
      name: kind, kind: kind,
      data: ["prompt": .null, "mcp": [], "permission_mode": .null, "trigger": .string(trigger.rawValue)])
  }

  /// The events that show the session came back to life (Decision 14): a main-session prompt, peer messages
  /// included, a launch, a resume, `undone`, and the event that `unpause` records.
  static let drops: [DropEvent] = [
    .prompt("Carry on with the PR.", name: "UserPromptSubmit"),
    .prompt(
      #"<cross-session-message from="sxyz12">Can you rebase on main?</cross-session-message>"#,
      name: "UserPromptSubmit from a peer"),
    .launch("started", trigger: .send),
    .launch("resumed", trigger: .resume),
    DropEvent(name: "undone", kind: "undone", data: [:]),
    DropEvent(name: "unpaused", kind: "unpaused", data: ["by": "you"]),
  ]

  /// Events that do not show the session came back: a subagent's prompt, the end of a turn, a tool call in a turn,
  /// a notification, and the user's own marks.
  static let others: [DropEvent] = [
    .prompt("Look in Sources/.", name: "UserPromptSubmit from a subagent", agent: "agent-1"),
    .hook("Stop", ["last_assistant_message": "Done."]),
    .hook("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "t1"]),
    .hook("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]),
    DropEvent(name: "done", kind: "done", data: [:]),
    DropEvent(name: "ack", kind: "ack", data: ["state": "needs_you", "reason": "Delete failed: x"]),
  ]
}

/// A failed removal that the guard may clear: the folder is at `cwd`, nothing is at the trash path, and git still
/// lists the worktree.
enum CleanRemoval: String, CaseIterable, Sendable {
  /// The removal failed before it chose a trash path.
  case noTrashPath
  /// The removal stored a trash path, failed before the rename, and put nothing there.
  case emptyTrashPath

  func make(_ h: FailedRemovalHarness) throws -> Session {
    let trash: String? = self == .emptyTrashPath ? h.trashPath() : nil
    return workSession(cwd: try h.folder(), removal: makeRemoval(.failed, trash: trash))
  }
}

/// A removal that the guard must keep. Each one breaks one part of the property that clearing needs: the folder is
/// at `cwd`, git still lists the worktree, and no removal step is pending (Risk 2).
enum KeptRemoval: String, CaseIterable, Sendable {
  case queued
  case running
  /// The worktree's folder sits in the trash, which the purge deletes once no removal names it.
  case failedWithFolderInTrash
  /// `trashedFolder` reads the trash path with `lstat`, so a symlink there counts as a folder in the trash.
  case failedWithSymlinkInTrash
  case failedWithFileInTrash
  /// git already dropped the worktree's record.
  case failedReleased
  case failedReleasedWithFolderInTrash
  /// sbd can't check a remote folder the way it checks one on this Mac (Decision 19). The same path exists on this
  /// Mac, so a guard that checked `cwd` here would find it.
  case failedOnARemoteHost
  /// Nothing is at `cwd` and nothing is in the trash, so sbd can't show where the folder is. This goes past
  /// Decision 14's three checks, to Risk 2's "the session's folder is at `session.cwd`".
  case failedWithCwdGone
  /// `cwd` is a symlink to a folder. The guard reads `cwd` with `lstat`, as `trashFolder(for:)` does, so it can't
  /// show that the link's folder is the worktree.
  case failedWithSymlinkAtCwd
  /// `rm` or `cleanup` is removing the session's files. This goes past Decision 14's three checks, to Risk 2's
  /// "no removal step is pending".
  case failedWhileRmRemoves

  func make(_ h: FailedRemovalHarness) throws -> Session {
    let fm = FileManager.default
    let trash = h.trashPath()
    try fm.createDirectory(atPath: "\(h.home.path)/trash", withIntermediateDirectories: true)
    switch self {
    case .queued:
      return workSession(cwd: try h.folder(), removal: makeRemoval(.queued))
    case .running:
      return workSession(cwd: try h.folder(), removal: makeRemoval(.running, trash: trash))
    case .failedWithFolderInTrash:
      try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
      try "late".write(toFile: "\(trash)/notes.txt", atomically: true, encoding: .utf8)
      return workSession(cwd: try h.folder(), removal: makeRemoval(.failed, trash: trash))
    case .failedWithSymlinkInTrash:
      try fm.createSymbolicLink(atPath: trash, withDestinationPath: "\(h.home.path)/nowhere")
      return workSession(cwd: try h.folder(), removal: makeRemoval(.failed, trash: trash))
    case .failedWithFileInTrash:
      try "x".write(toFile: trash, atomically: true, encoding: .utf8)
      return workSession(cwd: try h.folder(), removal: makeRemoval(.failed, trash: trash))
    case .failedReleased:
      return workSession(cwd: try h.folder(), removal: makeRemoval(.failed, released: true))
    case .failedReleasedWithFolderInTrash:
      try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
      return workSession(cwd: try h.folder(create: false), removal: makeRemoval(.failed, trash: trash, released: true))
    case .failedOnARemoteHost:
      return workSession(cwd: try h.folder(), host: "mini", removal: makeRemoval(.failed))
    case .failedWithCwdGone:
      return workSession(cwd: try h.folder(create: false), removal: makeRemoval(.failed))
    case .failedWithSymlinkAtCwd:
      let target = try h.folder("\(sessionId)-target")
      let cwd = try h.folder(create: false)
      try fm.createSymbolicLink(atPath: cwd, withDestinationPath: target)
      return workSession(cwd: cwd, removal: makeRemoval(.failed))
    case .failedWhileRmRemoves:
      return workSession(cwd: try h.folder(), removal: makeRemoval(.failed))
    }
  }

  /// Sets up what the shape needs beyond the session record.
  func prepare(_ h: FailedRemovalHarness) {
    guard self == .failedWhileRmRemoves else { return }
    h.service.queue.sync { _ = h.service.removing.insert(sessionId) }
  }
}

// MARK: Drops

/// sbd clears a clean failed removal when the session comes back to life, as `rm-keep` clears it (#378).
@Suite struct FailedRemovalDropClean {
  @Test(arguments: DropEvent.drops, CleanRemoval.allCases)
  func aDropEventClearsTheRemoval(_ trigger: DropEvent, _ shape: CleanRemoval) throws {
    let h = try FailedRemovalHarness()
    try h.add(try shape.make(h))
    try #require(h.removal()?.state == .failed)

    h.record(trigger)

    #expect(h.removal() == nil)
  }

  /// A restart loads the store, so a removal cleared only in memory would come back.
  @Test(arguments: DropEvent.drops, CleanRemoval.allCases)
  func theClearedRemovalIsSavedToTheStore(_ trigger: DropEvent, _ shape: CleanRemoval) throws {
    let h = try FailedRemovalHarness()
    try h.add(try shape.make(h))
    try #require(try h.stored()?.removal?.state == .failed)

    h.record(trigger)

    #expect(try h.stored()?.removal == nil)
  }

  /// The session leaves Needs you's "Delete failed" item, and its state comes from its events again.
  @Test(arguments: DropEvent.drops)
  func theStateComesFromTheEventsAgain(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    try h.add(try CleanRemoval.noTrashPath.make(h))
    try #require(h.summary().reason.hasPrefix("Delete failed"))

    h.record(trigger)

    let summary = h.summary()
    #expect(!summary.reason.hasPrefix("Delete failed"), "\(summary.state): \(summary.reason)")
    #expect(summary.removal == nil)
  }

  /// The drop moves nothing: the folder stays at `cwd` with its files.
  @Test(arguments: DropEvent.drops)
  func theDropLeavesTheFolderInPlace(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    let session = try CleanRemoval.noTrashPath.make(h)
    try "x".write(toFile: "\(session.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try h.add(session)

    h.record(trigger)

    #expect(h.removal() == nil)
    #expect(FileManager.default.fileExists(atPath: "\(session.cwd)/notes.txt"))
  }
}

// MARK: Guard

/// The guard keeps every removal whose folder sbd can't show is safe at `cwd` (Risk 2).
@Suite struct FailedRemovalDropGuard {
  @Test(arguments: DropEvent.drops, KeptRemoval.allCases)
  func aRemovalThatIsNotCleanStays(_ trigger: DropEvent, _ shape: KeptRemoval) throws {
    let h = try FailedRemovalHarness()
    let session = try shape.make(h)
    try h.add(session)
    shape.prepare(h)

    h.record(trigger)

    #expect(h.removal() == session.removal)
    #expect(try h.stored()?.removal == session.removal)
  }

  /// The guard never moves a folder. Moving one back from the trash is Keep's job.
  @Test(arguments: DropEvent.drops)
  func aFolderInTheTrashStaysInTheTrash(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    let session = try KeptRemoval.failedWithFolderInTrash.make(h)
    try FileManager.default.removeItem(atPath: session.cwd)
    try h.add(session)

    h.record(trigger)

    #expect(FileManager.default.fileExists(atPath: "\(h.trashPath())/notes.txt"))
    #expect(!FileManager.default.fileExists(atPath: session.cwd))
  }

  /// A remote session still shows "Delete failed" after it comes back.
  @Test(arguments: DropEvent.drops)
  func aRemoteSessionKeepsItsDeleteFailedItem(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    try h.add(try KeptRemoval.failedOnARemoteHost.make(h))

    h.record(trigger)

    #expect(h.summary().reason.hasPrefix("Delete failed"))
  }

  @Test(arguments: DropEvent.others, CleanRemoval.allCases)
  func anEventThatIsNotADropKeepsACleanFailedRemoval(_ trigger: DropEvent, _ shape: CleanRemoval) throws {
    let h = try FailedRemovalHarness()
    let session = try shape.make(h)
    try h.add(session)

    h.record(trigger)

    #expect(h.removal() == session.removal)
  }

  @Test(arguments: DropEvent.drops)
  func aSessionWithNoRemovalIsUnchanged(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    let session = workSession(cwd: try h.folder(), removal: nil)
    try h.add(session)

    h.record(trigger)

    #expect(h.session() == session)
    #expect(try h.stored() == session)
  }

  /// A removal that finished forgot the session, so a late event names no entry.
  @Test(arguments: DropEvent.drops)
  func anEventForAForgottenSessionAddsNoEntry(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()

    h.record(trigger, "sgone1")

    #expect(h.session("sgone1") == nil)
    #expect(try h.stored("sgone1") == nil)
  }

  /// A restart replays the stored events and runs `afterTrack` for each session. Neither is a new event, so the
  /// removal stays.
  @Test func aRestartThatReplaysADropEventKeepsTheRemoval() throws {
    let h = try FailedRemovalHarness()
    let session = try CleanRemoval.noTrashPath.make(h)
    try h.add(session)
    for trigger in DropEvent.drops {
      _ = try h.service.store.append(Event(session: sessionId, t: nowMs(), kind: trigger.kind, data: trigger.data))
    }
    let restarted = try Service(home: h.home, sbPath: "/usr/bin/true")
    defer { for link in restarted.hostLinks.values { link.disconnect() } }

    try restarted.load()

    let loaded = restarted.queue.sync { restarted.entries[sessionId] }
    #expect(loaded?.events == DropEvent.drops.count)
    #expect(loaded?.session.removal == session.removal)
    #expect(try h.stored()?.removal == session.removal)
  }

  /// The drop touches only the session that the event names.
  @Test(arguments: DropEvent.drops)
  func aDropLeavesAnotherSessionsRemoval(_ trigger: DropEvent) throws {
    let h = try FailedRemovalHarness()
    try h.add(try CleanRemoval.noTrashPath.make(h))
    let other = workSession("s2", cwd: try h.folder("s2"), removal: makeRemoval(.failed))
    try h.add(other)

    h.record(trigger)

    #expect(h.removal("s2") == other.removal)
  }
}

// MARK: Parity with rm-keep

/// A clean failed removal for the parity tests, with the fields that `rm-queue` and the job can set.
struct ParityRemoval: Sendable, CustomTestStringConvertible {
  let name: String
  let removal: @Sendable (FailedRemovalHarness) -> Removal

  var testDescription: String { name }

  static let all: [ParityRemoval] = [
    ParityRemoval(name: "worktree only") { _ in makeRemoval(.failed, branch: false) },
    ParityRemoval(name: "worktree, branch, and remote branch") { _ in makeRemoval(.failed, remoteBranch: true) },
    ParityRemoval(name: "resolves to-dos") { _ in makeRemoval(.failed, resolve: ["n1", "n2"]) },
    ParityRemoval(name: "no error text") { _ in makeRemoval(.failed, error: nil) },
    ParityRemoval(name: "multi-line error") { _ in
      makeRemoval(.failed, error: "can't stop the panes:\n  sleep 100 still runs in \"the folder\"")
    },
    ParityRemoval(name: "trash path with nothing there") { h in makeRemoval(.failed, trash: h.trashPath()) },
  ]
}

/// `rm-keep` on a clean failed removal and the auto-drop leave the same session record (Risk 2).
@Suite struct FailedRemovalDropParity {
  /// One home gets `rm-keep` and then the event, so both homes record the same event. The other gets only the
  /// event, which drops the removal.
  @Test(arguments: DropEvent.drops, ParityRemoval.all)
  func keepAndTheDropLeaveEqualRecords(_ trigger: DropEvent, _ parity: ParityRemoval) throws {
    let kept = try FailedRemovalHarness()
    let dropped = try FailedRemovalHarness()
    try kept.add(workSession(cwd: try kept.folder(), removal: parity.removal(kept)))
    try dropped.add(workSession(cwd: try dropped.folder(), removal: parity.removal(dropped)))
    let answer = kept.keep()
    try #require(answer.ok, "rm-keep failed: \(answer.error ?? "")")
    kept.record(trigger)

    dropped.record(trigger)

    let keptSession = try #require(kept.session())
    let droppedSession = try #require(dropped.session())
    #expect(droppedSession == withHome(keptSession, from: kept, to: dropped))
  }

  @Test(arguments: DropEvent.drops, ParityRemoval.all)
  func keepAndTheDropStoreEqualRecords(_ trigger: DropEvent, _ parity: ParityRemoval) throws {
    let kept = try FailedRemovalHarness()
    let dropped = try FailedRemovalHarness()
    try kept.add(workSession(cwd: try kept.folder(), removal: parity.removal(kept)))
    try dropped.add(workSession(cwd: try dropped.folder(), removal: parity.removal(dropped)))
    let answer = kept.keep()
    try #require(answer.ok, "rm-keep failed: \(answer.error ?? "")")
    kept.record(trigger)

    dropped.record(trigger)

    let keptRow = try #require(try kept.stored())
    let droppedRow = try #require(try dropped.stored())
    #expect(droppedRow == withHome(keptRow, from: kept, to: dropped))
  }

  /// The parity holds only where `rm-keep` would answer: on a removal that it refuses, the drop keeps it too.
  @Test(arguments: [KeptRemoval.failedReleasedWithFolderInTrash, .queued, .running])
  func aRemovalThatKeepRefusesIsNotDropped(_ shape: KeptRemoval) throws {
    let h = try FailedRemovalHarness()
    let session = try shape.make(h)
    try h.add(session)
    try #require(!h.keep().ok)

    h.record(DropEvent.drops[0])

    #expect(h.removal() == session.removal)
  }
}

/// The session with each path under the first harness's home moved under the second's, so two homes compare.
private func withHome(_ session: Session, from: FailedRemovalHarness, to: FailedRemovalHarness) -> Session {
  var s = session
  s.cwd = s.cwd.replacingOccurrences(of: from.home.path, with: to.home.path)
  let trash = s.removal?.trash?.replacingOccurrences(of: from.home.path, with: to.home.path)
  s.removal?.trash = trash
  return s
}
