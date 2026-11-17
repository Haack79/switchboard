import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The `highlighted` key of the session's row in `sb ls --json`, or nil when the row has no such key.
  func highlightField(_ id: String) throws -> JSON? {
    try listed(id)["highlighted"]
  }

  /// The session's `unhighlighted` events that sbd recorded because the session reached Done.
  fileprivate func clearsOnDone(_ id: String) throws -> [Event] {
    try events(id, kind: "unhighlighted").filter { $0.data["by"] == "sbd" && $0.data["why"] == "done" }
  }
}

/// `sb highlight` sets a flag that rings the session in the app and puts its Inbox item first. `--clear` removes
/// it, and sbd removes it when the session reaches Done.
@Suite(.blocking(timeLimit: .seconds(120))) struct HighlightTests {
  func needsYouSession(_ sbd: Instance, name: String = "t") throws -> SessionSummary {
    try AcknowledgeTests().needsYouSession(sbd, name: name)
  }

  /// A session whose PR #18303 is open and ready to merge, so it is not Done.
  func prSession(_ sbd: Instance) throws -> SessionSummary {
    let s = try MergeTests().readySession(sbd)
    try #require(try sbd.get(s.id).state == .readyToMerge)
    return s
  }

  // MARK: Setting and clearing

  @Test func highlightSetsTheFieldInLsAndGet() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("highlight", s.id)

    #expect(try sbd.highlightField(s.id) == .bool(true))
    #expect(try sbd.getJSON(s.id)["highlighted"] == .bool(true))
  }

  @Test func highlightRecordsOneHighlightedEventByYou() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("highlight", s.id)

    let events = try sbd.events(s.id, kind: "highlighted")
    #expect(events.count == 1)
    #expect(events.first?.data["by"] == "you")
  }

  @Test func highlightLeavesOtherSessionsWithoutTheKey() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "one")
    let other = try needsYouSession(sbd, name: "two")

    try sbd.sb("highlight", s.id)

    let rows = try sbd.lsRows()
    #expect(rows.contains { $0["id"]?.string == other.id })
    #expect(rows.filter { $0["id"]?.string != s.id }.allSatisfy { $0["highlighted"] == nil })
    #expect(try sbd.getJSON(other.id)["highlighted"] == nil)
  }

  @Test func clearRemovesTheField() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("highlight", s.id, "--clear")

    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.getJSON(s.id)["highlighted"] == nil)
  }

  @Test func clearRecordsOneUnhighlightedEventByYou() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("highlight", s.id, "--clear")

    let events = try sbd.events(s.id, kind: "unhighlighted")
    #expect(events.count == 1)
    #expect(events.first?.data["by"] == "you")
  }

  @Test func highlightTwiceRecordsOneEvent() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("highlight", s.id)

    #expect(try sbd.count("highlighted", of: s.id) == 1)
    #expect(try sbd.highlightField(s.id) == .bool(true))
  }

  @Test func clearOfASessionWithoutAHighlightRecordsNothing() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("highlight", s.id, "--clear")

    #expect(try sbd.count("unhighlighted", of: s.id) == 0)
    #expect(try sbd.highlightField(s.id) == nil)
  }

  @Test func highlightJSONPrintsTheSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let got = try #require(JSON.parse(try sbd.sb("highlight", "--json", s.id)))

    #expect(got["id"]?.string == s.id)
    #expect(got["highlighted"] == .bool(true))
  }

  @Test func highlightRequestDefaultsToTrueAndReturnsTheSummary() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    let got = try sbd.client.call("highlight", ["session": .string(s.id)])

    #expect(got["id"]?.string == s.id)
    #expect(got["highlighted"] == .bool(true))
  }

  @Test func highlightSurvivesAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.highlightField(s.id) == .bool(true))
    #expect(try sbd.count("unhighlighted", of: s.id) == 0)
  }

  @Test func highlightIsNotActivity() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    let before = try sbd.get(s.id)

    try sbd.sb("highlight", s.id)
    let highlighted = try sbd.get(s.id)
    try sbd.sb("highlight", s.id, "--clear")
    let cleared = try sbd.get(s.id)

    #expect(highlighted.lastActivity == before.lastActivity)
    #expect(cleared.lastActivity == before.lastActivity)
    #expect(highlighted.state == before.state)
    #expect(highlighted.since == before.since)
  }

  /// The Manager runs inside Claude Code with its own SB_SESSION_ID.
  @Test func theManagerCanHighlightAnotherSessionWithSb() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    let conversation = try #require(JSON.parse(try sbd.sb("manager", "new", "--json"))?["id"]?.string)

    try sbd.sb(["highlight", s.id], env: ["CLAUDECODE": "1", "SB_SESSION_ID": conversation])

    #expect(try sbd.highlightField(s.id) == .bool(true))
    #expect(try sbd.events(s.id, kind: "highlighted").first?.data["by"] == "claude")
  }

  // MARK: Done clears it (Risk 1)

  /// The clear's own event folds again through the guard, which finds nothing left to clear.
  @Test func markingDoneClearsTheHighlightOnceAcrossLaterTicks() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("done", s.id)

    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)

    try sbd.advanceClock(5_000)
    try sbd.advanceClock(5_000)

    #expect(try sbd.count("unhighlighted", of: s.id) == 1)
  }

  @Test func markingNotDoneLeavesItCleared() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)
    try sbd.sb("done", s.id)

    try sbd.sb("undone", s.id)

    #expect(try sbd.get(s.id).state != .done)
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.count("highlighted", of: s.id) == 1)
  }

  @Test func aSessionMarkedDoneStaysUnhighlightedAfterAnSbdRestart() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)
    try sbd.sb("done", s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.count("unhighlighted", of: s.id) == 1)
  }

  /// The startup pass: the stored session is highlighted and marked done, as when sbd stopped before its guard ran.
  @Test func aSessionThatBecameDoneWhileSbdWasDownLosesItsHighlightAtStartup() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)
    sbd.stopSbd()
    do {
      let store = try Store(path: sbd.home.database)
      var session = try #require(try store.sessions().first { $0.id == s.id })
      try #require(session.highlighted == true)
      session.done = true
      try store.save(session)
    }

    try sbd.startSbd()

    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  @Test func aMergedPRWithACleanFolderClearsTheHighlightOnceAcrossLaterPolls() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    try sbd.sb("highlight", s.id)

    github.change(MergeTests.number) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.get(s.id).markedDone == false)
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)

    try sbd.poll(all: true)
    try sbd.advanceClock(5_000)

    #expect(try sbd.count("unhighlighted", of: s.id) == 1)
  }

  /// sbd can't save the clear while the log is locked, so the session keeps its highlight. A tick after the lock
  /// clears it.
  @Test func aClearThatCantBeSavedKeepsTheHighlightUntilALaterTick() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    try sbd.sb("highlight", s.id)
    github.change(MergeTests.number) { $0["state"] = "MERGED" }

    let locked = try sbd.whileTheLogIsLocked {
      try sbd.poll(all: true)
      return (state: try sbd.get(s.id).state, highlighted: try sbd.highlightField(s.id))
    }
    try sbd.advanceClock(5_000)

    #expect(locked.state == .done)
    #expect(locked.highlighted == .bool(true))
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  @Test func aClosedPRWithACleanFolderClearsTheHighlight() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    try sbd.sb("highlight", s.id)

    github.change(MergeTests.number) { $0["state"] = "CLOSED" }
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  /// The folder's uncommitted file keeps the session in Needs you, so it keeps its highlight until the folder is clean.
  @Test func aMergedPRWithUncommittedChangesKeepsTheHighlightUntilTheFolderIsClean() throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    try sbd.sb("highlight", s.id)
    let file = "\(s.cwd)/notes.txt"
    try "x".write(toFile: file, atomically: true, encoding: .utf8)

    github.change(MergeTests.number) { $0["state"] = "MERGED" }
    try sbd.poll(all: true)

    let dirty = try sbd.get(s.id)
    #expect(dirty.state == .needsYou)
    #expect(dirty.reason == "#18303 merged; commit or discard the uncommitted changes")
    #expect(try sbd.highlightField(s.id) == .bool(true))
    #expect(try sbd.count("unhighlighted", of: s.id) == 0)

    try FileManager.default.removeItem(atPath: file)
    try sbd.poll(all: true)

    #expect(try sbd.get(s.id).state == .done)
    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  /// The guard reads the evaluated state, not the snoozed shown state.
  @Test func aSnoozedSessionThatReachesDoneLosesItsHighlight() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)
    try sbd.sb("snooze", s.id)

    try sbd.sb("done", s.id)

    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  @Test func anAcknowledgedSessionThatReachesDoneLosesItsHighlight() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)
    try sbd.sb("ack", s.id)

    try sbd.sb("done", s.id)

    #expect(try sbd.highlightField(s.id) == nil)
    #expect(try sbd.clearsOnDone(s.id).count == 1)
  }

  @Test func aSnoozedSessionThatIsNotDoneKeepsItsHighlight() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("snooze", s.id)
    try sbd.advanceClock(5_000)

    #expect(try sbd.highlightField(s.id) == .bool(true))
    #expect(try sbd.count("unhighlighted", of: s.id) == 0)
  }

  // MARK: Refusals

  enum DoneBy: String, CaseIterable, Sendable { case marked, mergedPR }

  /// Done is the evaluated state, so a merged PR with a clean folder is refused although it isn't marked done.
  @Test(arguments: DoneBy.allCases)
  func highlightRefusesADoneSession(_ how: DoneBy) throws {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let s = try prSession(sbd)
    switch how {
    case .marked: try sbd.sb("done", s.id)
    case .mergedPR:
      github.change(MergeTests.number) { $0["state"] = "MERGED" }
      try sbd.poll(all: true)
    }
    let done = try sbd.get(s.id)
    try #require(done.state == .done)

    let r = try sbd.run(["highlight", s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(done.name) is done"), "\(r.stderr)")
    #expect(try sbd.count("highlighted", of: s.id) == 0)
    #expect(try sbd.highlightField(s.id) == nil)
  }

  @Test func clearOfADoneSessionIsAllowed() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("done", s.id)

    let r = try sbd.run(["highlight", s.id, "--clear"])

    #expect(r.status == 0, "\(r.stderr)")
  }

  @Test func highlightRefusesEverySessionThatIsNotWork() throws {
    let sbd = try Instance()
    try sbd.sb("group", "add", "Flags")
    let refused = [
      ("manager", try sbd.id(of: try #require(JSON.parse(try sbd.sb("manager", "--json"))))),
      ("conversation", try #require(JSON.parse(try sbd.sb("manager", "new", "--json"))?["id"]?.string)),
      ("group chat", try sbd.chatOf("Flags")),
      ("operator", try sbd.id(of: try #require(JSON.parse(try sbd.sb("operator", "--json"))))),
    ]

    for (kind, id) in refused {
      let r = try sbd.run(["highlight", id])

      #expect(r.status != 0, "\(kind)")
      #expect(r.stderr.contains("only a work session can be highlighted"), "\(kind): \(r.stderr)")
      #expect(try sbd.count("highlighted", of: id) == 0, "\(kind)")
    }
  }

  /// The caller and the target can each name the session by its id, its name, or a prefix of its id.
  @Test func highlightRefusesTheSessionThatRunsIt() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    func ref(_ form: String) -> String {
      switch form {
      case "name": s.name
      case "prefix": String(s.id.prefix(s.id.count - 1))
      default: s.id
      }
    }

    for (target, caller) in [("id", "id"), ("name", "id"), ("prefix", "id"), ("id", "name"), ("id", "prefix")] {
      let r = try sbd.run(["highlight", ref(target)], env: ["CLAUDECODE": "1", "SB_SESSION_ID": ref(caller)])

      #expect(r.status != 0, "\(target), \(caller)")
      #expect(r.stderr.contains("worker can't highlight itself"), "\(target), \(caller): \(r.stderr)")
    }
    #expect(try sbd.count("highlighted", of: s.id) == 0)
    #expect(try sbd.highlightField(s.id) == nil)
  }

  @Test func clearRefusesTheSessionThatRunsIt() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "worker")
    try sbd.sb("highlight", s.id)

    let r = try sbd.run(["highlight", s.id, "--clear"], env: ["CLAUDECODE": "1", "SB_SESSION_ID": s.id])

    #expect(r.status != 0)
    #expect(r.stderr.contains("worker can't change its own highlight"), "\(r.stderr)")
    #expect(try sbd.count("unhighlighted", of: s.id) == 0)
    #expect(try sbd.highlightField(s.id) == .bool(true))
  }

  @Test func highlightRequestWithTheTargetAsCallerIsRefused() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    #expect(throws: APIError.self) {
      try sbd.client.call("highlight", ["session": .string(s.id), "caller": .string(s.id)])
    }
    #expect(try sbd.count("highlighted", of: s.id) == 0)
  }

  // MARK: The Inbox order (Risk 2)

  func triageIDs(_ sbd: Instance, of ids: [String]) throws -> [String] {
    try sbd.triageJSON().compactMap { $0["id"]?.string }.filter { ids.contains($0) }
  }

  @Test func triageListsAHighlightedItemFirst() throws {
    let sbd = try Instance()
    let older = try needsYouSession(sbd, name: "older")
    let newer = try needsYouSession(sbd, name: "newer")
    let ids = [older.id, newer.id]
    try #require(try triageIDs(sbd, of: ids) == [older.id, newer.id])

    try sbd.sb("highlight", newer.id)
    let highlighted = try triageIDs(sbd, of: ids)
    try sbd.sb("highlight", newer.id, "--clear")
    let cleared = try triageIDs(sbd, of: ids)

    #expect(highlighted == [newer.id, older.id])
    #expect(cleared == [older.id, newer.id])
  }

  @Test func triageCarriesTheHighlightedKey() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("highlight", s.id)

    let row = try #require(try sbd.triageJSON().first { $0["id"]?.string == s.id })
    #expect(row["highlighted"] == .bool(true))
  }

  @Test func aHighlightedSnoozedSessionStaysOutOfTriageUntilItWakes() throws {
    let sbd = try Instance()
    let older = try needsYouSession(sbd, name: "older")
    let newer = try needsYouSession(sbd, name: "newer")
    let ids = [older.id, newer.id]
    try sbd.sb("highlight", newer.id)
    try sbd.sb("snooze", newer.id)

    let snoozed = try triageIDs(sbd, of: ids)
    try sbd.advanceClock(61 * SnoozeTests.minuteMs)
    let woken = try triageIDs(sbd, of: ids)

    #expect(snoozed == [older.id])
    #expect(woken == [newer.id, older.id])
    #expect(try sbd.highlightField(newer.id) == .bool(true))
  }

  // MARK: Text output

  /// The `sb ls` lines with each age column replaced, because `sb` reads its own clock for the age.
  func lsLines(_ sbd: Instance) throws -> [String] {
    try sbd.sb("ls").split(separator: "\n", omittingEmptySubsequences: false).map {
      String($0).replacing(#/  \d+[smhd] *  /#, with: "  <age>  ")
    }
  }

  @Test func lsTextMarksOnlyTheHighlightedRow() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "one")
    _ = try needsYouSession(sbd, name: "two")
    let before = try lsLines(sbd)

    try sbd.sb("highlight", s.id)
    let after = try lsLines(sbd)

    try #require(after.count == before.count, "\(after)")
    for (old, new) in zip(before, after) {
      if old.contains(s.id) {
        #expect(old.hasPrefix("  "), "\(old)")
        #expect(new == "* " + String(old.dropFirst(2)), "\(new)")
      } else {
        #expect(new == old)
      }
    }
  }

  @Test func lsTextIsUnchangedAfterTheHighlightIsCleared() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd, name: "one")
    let before = try lsLines(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("highlight", s.id, "--clear")

    #expect(try lsLines(sbd) == before)
  }

  @Test func getTextPrintsTheHighlightedLineAfterTheStateLine() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)

    try sbd.sb("highlight", s.id)

    let lines = try sbd.sb("get", s.id).split(separator: "\n").map(String.init)
    let state = try #require(lines.firstIndex { $0.hasPrefix("  state:") }, "\(lines)")
    #expect(lines.indices.contains(state + 1) && lines[state + 1] == "  highlighted: yes", "\(lines)")
    #expect(lines.filter { $0.contains("highlighted:") }.count == 1)
  }

  @Test func getTextHasNoHighlightedLineWithoutAHighlight() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("highlight", s.id, "--clear")

    #expect(try !sbd.sb("get", s.id).contains("highlighted"))
  }

  // MARK: Delete

  @Test func deletingAHighlightedSessionRemovesIt() throws {
    let sbd = try Instance()
    let s = try needsYouSession(sbd)
    try sbd.sb("highlight", s.id)

    try sbd.sb("rm", s.id)

    try sbd.waitFor("the removal of \(s.id)") { try !sbd.lsRows().contains { $0["id"]?.string == s.id } }
    #expect(try sbd.run(["highlight", s.id, "--clear"]).status != 0)
  }
}
