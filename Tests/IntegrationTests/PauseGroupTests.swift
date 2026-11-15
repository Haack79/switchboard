import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The row of a group report for one session.
  fileprivate func row(_ report: JSON, _ id: String) -> JSON? {
    report["sessions"]?.array?.first { $0["session"]?.string == id }
  }

  /// Runs `sb resume <args> --json` and returns what it printed.
  @discardableResult
  fileprivate func resumeJSON(_ args: [String]) throws -> JSON {
    try #require(JSON.parse(try sb(["resume"] + args + ["--json"])))
  }

  fileprivate func pausedEvents(_ id: String, after mark: Int64 = 0) throws -> [Event] {
    try events(id, after: mark).filter { $0.kind == "paused" }
  }
}

/// `sb pause <group>` and `sb resume <group>`: each member is paused or resumed on its own record.
@Suite(.blocking(timeLimit: .seconds(180))) struct PauseGroupTests {
  /// Group Flags holds a member marked done, a member that is already paused with its own reason and message, a
  /// live member, and a follow-up that hasn't started. Flags also has a chat, which is never a member.
  private struct Flags {
    let group: GroupSummary
    let done: SessionSummary
    let paused: SessionSummary
    let live: SessionSummary
    let unstarted: SessionSummary
    let chat: String
  }

  private func flags(_ sbd: Instance) throws -> Flags {
    let done = try sbd.new(name: "finished")
    let paused = try sbd.pausedStopped("held", ["--reason", "own reason", "--message", "own message"])
    let live = try sbd.liveIdle("busy")
    let group = try sbd.addGroup("Flags", [done.id, paused.id, live.id])
    try sbd.sb("done", done.id)
    let unstarted = try add(sbd, ["prompt": "Fix the cache.", "group": .string(group.id)])
    let chat = try sbd.chatOf("Flags")
    return Flags(group: group, done: done, paused: paused, live: live, unstarted: unstarted, chat: chat)
  }

  /// Group Flags with two live members, alpha and bravo.
  private func twoLive(_ sbd: Instance) throws -> (group: GroupSummary, a: SessionSummary, b: SessionSummary) {
    let a = try sbd.liveIdle("alpha")
    let b = try sbd.liveIdle("bravo")
    return (try sbd.addGroup("Flags", [a.id, b.id]), a, b)
  }

  // MARK: Pausing a group

  @Test func aGroupPauseReportsEachMemberAsPausedAlreadyPausedOrSkipped() throws {
    let sbd = try Instance()
    let f = try flags(sbd)

    let report = try sbd.pauseJSON("Flags", ["--reason", "x"])

    #expect(report["group"]?.string == f.group.id, "\(report.text)")
    #expect(report["name"] == "Flags")
    #expect(
      sbd.results(report) == [
        f.done.id: "skipped", f.paused.id: "already_paused", f.live.id: "paused", f.unstarted.id: "skipped",
      ], "\(report.text)")
    #expect(sbd.row(report, f.live.id)?["name"] == "busy")
  }

  @Test func aGroupPauseStopsTheLiveMemberWithTheGroupsReason() throws {
    let sbd = try Instance()
    let f = try flags(sbd)
    let mark = try sbd.lastEventId(f.live.id)

    try sbd.pauseJSON("Flags", ["--reason", "x"])

    try sbd.waitForPausedExit(f.live.id)
    #expect(try sbd.get(f.live.id).reason == "Paused by you: x")
    #expect(try sbd.pausedEvents(f.live.id, after: mark).count == 1)
  }

  /// A group pause never erases a pause that a member already has.
  @Test func aGroupPauseKeepsTheOwnPauseOfAnAlreadyPausedMember() throws {
    let sbd = try Instance()
    let f = try flags(sbd)
    let before = try #require(try sbd.pauseField(f.paused.id))
    let mark = try sbd.lastEventId(f.paused.id)
    try sbd.advanceClock(60_000)

    try sbd.pauseJSON("Flags", ["--reason", "x", "--message", "group message"])

    #expect(try sbd.pauseField(f.paused.id) == before)
    #expect(try sbd.get(f.paused.id).reason == "Paused by you: own reason")
    #expect(try sbd.pausedEvents(f.paused.id, after: mark).isEmpty)
  }

  @Test func aGroupPauseLeavesTheDoneMemberTheUnstartedFollowupAndTheChatUnpaused() throws {
    let sbd = try Instance()
    let f = try flags(sbd)

    let report = try sbd.pauseJSON("Flags", ["--reason", "x"])

    try sbd.waitForPausedExit(f.live.id)
    for id in [f.done.id, f.unstarted.id, f.chat] {
      #expect(try sbd.pauseField(id) == nil, "\(id)")
      #expect(try sbd.pausedEvents(id).isEmpty, "\(id)")
    }
    #expect(try sbd.get(f.done.id).state == .done)
    #expect(sbd.row(report, f.chat) == nil, "\(report.text)")
  }

  @Test func aGroupPausePrintsOneLinePerMember() throws {
    let sbd = try Instance()
    let f = try flags(sbd)

    let out = try sbd.sb("pause", "Flags")

    let lines = out.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    #expect(lines.contains(["paused", f.live.id, "busy"]), "\(out)")
    for id in [f.done.id, f.paused.id, f.unstarted.id] {
      #expect(lines.filter { $0.contains(id) }.count == 1, "\(id) in \(out)")
    }
    #expect(!out.contains(f.chat), "\(out)")
  }

  /// How a command names the group. No session has the group's name or a prefix of its id, so a positional ref
  /// falls back to the group.
  enum GroupRef: String, CaseIterable, Sendable { case positionalName, positionalId, flagName, flagId }

  @Test(arguments: GroupRef.allCases)
  func aGroupPauseAcceptsTheGroupHoweverItIsNamed(_ how: GroupRef) throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    let args: [String]
    switch how {
    case .positionalName: args = ["Flags"]
    case .positionalId: args = [g.group.id]
    case .flagName: args = ["--group", "Flags"]
    case .flagId: args = ["--group", g.group.id]
    }

    let report = try #require(JSON.parse(try sbd.sb(["pause"] + args + ["--json"])))

    #expect(report["group"]?.string == g.group.id, "\(report.text)")
    #expect(sbd.results(report) == [g.a.id: "paused", g.b.id: "paused"], "\(report.text)")
    #expect(try sbd.pauseField(g.a.id) != nil)
    #expect(try sbd.pauseField(g.b.id) != nil)
  }

  /// A group has no paused flag of its own, so a session that joins it after a group pause isn't paused.
  @Test func aSessionThatJoinsThePausedGroupLaterIsNotPaused() throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    try sbd.pauseJSON("Flags")
    let later = try sbd.liveIdle("later")

    _ = try sbd.sb("group", "move", "--json", later.id, "--to", "Flags")

    #expect(try sbd.get(later.id).group == g.group.id)
    #expect(try sbd.pauseField(later.id) == nil)
    #expect(try sbd.get(later.id).live)
  }

  /// Claude in a member pauses its own group. The member can't pause itself, so its row fails.
  /// The pause of every other member goes ahead.
  @Test func aMemberThatPausesItsOwnGroupFailsForItselfAndPausesTheOthers() throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)

    let r = try sbd.run(["pause", "--group", "Flags", "--json"], env: sbd.inside(g.a.id))

    let report = try #require(JSON.parse(r.stdout), "\(r.stdout) \(r.stderr)")
    #expect(sbd.results(report) == [g.a.id: "failed", g.b.id: "paused"], "\(report.text)")
    let error = try #require(sbd.row(report, g.a.id)?["error"]?.string)
    #expect(error.contains("can't pause itself"), "\(error)")
    #expect(try sbd.pauseField(g.a.id) == nil)
    #expect(try sbd.get(g.b.id).reason == "Paused by alpha")
  }

  // MARK: Conditions on a group pause

  /// The condition is read once for the group, and each member gets a condition of its own.
  @Test func aGroupPauseUntilATimeResumesEachMemberWhenTheTimeComes() throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    try sbd.pauseJSON("Flags", ["--until", "1h"])
    try sbd.waitForPausedExit(g.a.id)
    try sbd.waitForPausedExit(g.b.id)
    for id in [g.a.id, g.b.id] {
      #expect(try sbd.pauseField(id)?["until"]?["kind"] == "date", "\(id)")
    }
    let marks = (a: try sbd.lastEventId(g.a.id), b: try sbd.lastEventId(g.b.id))

    try sbd.advanceClock(2 * 3_600_000)

    for (id, mark) in [(g.a.id, marks.a), (g.b.id, marks.b)] {
      try sbd.waitForPrompts(id, after: mark, count: 1)
      #expect(try sbd.pauseField(id) == nil, "\(id)")
      #expect(try sbd.launchEvents(id, after: mark).first?.data["trigger"] == "wait", "\(id)")
    }
  }

  /// The positive control of the refusal below: a `session:` condition on a session outside the group pauses
  /// every member with that condition.
  @Test func aGroupPauseUntilAnOutsideSessionPausesEveryMemberWithTheCondition() throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    let outsider = try sbd.new(name: "outsider")

    let report = try sbd.pauseJSON("Flags", ["--until", "session:outsider"])

    #expect(sbd.results(report) == [g.a.id: "paused", g.b.id: "paused"], "\(report.text)")
    for id in [g.a.id, g.b.id] {
      let until = try #require(try sbd.pauseField(id)?["until"], "\(id)")
      #expect(until["kind"] == "session", "\(id)")
      #expect(until["session"]?["id"]?.string == outsider.id, "\(until.text)")
    }
  }

  /// Each way that a `session:` condition can name a member of the group.
  enum MemberRef: String, CaseIterable, Sendable { case name, id, idPrefix, nameWithState }

  /// The member would be paused too, so its state could never change. The refusal comes before any member is
  /// paused.
  @Test(arguments: MemberRef.allCases)
  func aGroupPauseUntilAMemberIsRefusedBeforeAnyMemberIsPaused(_ how: MemberRef) throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    let ref: String
    switch how {
    case .name: ref = "bravo"
    case .id: ref = g.b.id
    case .idPrefix: ref = String(g.b.id.prefix(4))
    case .nameWithState: ref = "bravo=needs_you"
    }

    let r = try sbd.run(["pause", "--group", "Flags", "--until", "session:\(ref)", "--json"])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(!r.stderr.contains("needs a session"), "the group pause never ran: \(r.stderr)")
    #expect(r.stderr.contains(g.b.id) || r.stderr.contains("bravo") || r.stderr.contains(ref), "\(r.stderr)")
    for id in [g.a.id, g.b.id] {
      #expect(try sbd.pauseField(id) == nil, "\(id)")
      #expect(try sbd.pausedEvents(id).isEmpty, "\(id)")
      #expect(try sbd.get(id).live, "\(id)")
    }
  }

  /// A condition that no member could meet is refused once for the group, not once per member.
  @Test(arguments: ["session:nosuch", "2020-01-01 09:00", "session:outsider=bogus"])
  func aGroupPauseWithAConditionThatCantBeSetIsRefusedBeforeAnyMemberIsPaused(_ until: String) throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    _ = try sbd.new(name: "outsider")

    let r = try sbd.run(["pause", "--group", "Flags", "--until", until, "--json"])

    #expect(r.status != 0, "\(r.stdout)")
    for id in [g.a.id, g.b.id] {
      #expect(try sbd.pauseField(id) == nil, "\(id)")
      #expect(try sbd.pausedEvents(id).isEmpty, "\(id)")
    }
  }

  // MARK: Resuming a group

  enum ResumeRef: String, CaseIterable, Sendable { case positional, flag }

  /// Without `--message`, each paused member resumes with its own message. A member that isn't paused gets
  /// nothing.
  @Test(arguments: ResumeRef.allCases)
  func aGroupResumeResumesEachPausedMemberWithItsOwnMessage(_ how: ResumeRef) throws {
    let sbd = try Instance()
    let a = try sbd.pausedStopped("a", ["--message", "a's own message"])
    let b = try sbd.pausedStopped("b")
    let c = try sbd.liveIdle("c")
    _ = try sbd.addGroup("Flags", [a.id, b.id, c.id])
    let marks = (a: try sbd.lastEventId(a.id), b: try sbd.lastEventId(b.id), c: try sbd.lastEventId(c.id))

    try sbd.resumeJSON(how == .positional ? ["Flags"] : ["--group", "Flags"])

    #expect(try sbd.waitForPrompts(a.id, after: marks.a, count: 1) == ["a's own message"])
    #expect(try sbd.waitForPrompts(b.id, after: marks.b, count: 1) == [defaultResume])
    #expect(try sbd.pauseField(a.id) == nil)
    #expect(try sbd.pauseField(b.id) == nil)
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(c.id, after: marks.c).isEmpty)
    #expect(try sbd.promptsSince(c.id, after: marks.c).isEmpty)
  }

  @Test func aGroupResumeWithAMessageSendsItToEveryPausedMember() throws {
    let sbd = try Instance()
    let a = try sbd.pausedStopped("a", ["--message", "a's own message"])
    let b = try sbd.pausedStopped("b")
    _ = try sbd.addGroup("Flags", [a.id, b.id])
    let marks = (a: try sbd.lastEventId(a.id), b: try sbd.lastEventId(b.id))

    try sbd.resumeJSON(["--group", "Flags", "--message", "all go"])

    #expect(try sbd.waitForPrompts(a.id, after: marks.a, count: 1) == ["all go"])
    #expect(try sbd.waitForPrompts(b.id, after: marks.b, count: 1) == ["all go"])
  }

  /// A member whose folder went away while it was paused fails the group resume with the folder's error.
  /// Its pause still ends. The other member resumes.
  @Test func aGroupResumeEndsThePauseOfAMemberWhoseFolderIsGoneAndResumesTheRest() throws {
    let sbd = try Instance()
    // Each session of `pausedStopped` runs in the same folder, so this one gets a folder of its own.
    let folder = sbd.work + "/gone"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let started = try sbd.client.call(
      "new", ["path": .string(folder), "name": "gone", "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(started.id, "gone's first reply") { $0.lastReply != nil && $0.claudePid != nil }
    try sbd.pauseJSON(started.id)
    let gone = try sbd.waitFor(started.id, "gone's claude to exit") { !$0.live && $0.claudePid == nil }
    let kept = try sbd.pausedStopped("kept")
    _ = try sbd.addGroup("Flags", [gone.id, kept.id])
    let marks = (gone: try sbd.lastEventId(gone.id), kept: try sbd.lastEventId(kept.id))
    let away = gone.cwd + ".away"
    try FileManager.default.moveItem(atPath: gone.cwd, toPath: away)
    defer { try? FileManager.default.moveItem(atPath: away, toPath: gone.cwd) }

    let report = try sbd.resumeJSON(["Flags"])

    #expect(sbd.results(report) == [gone.id: "failed", kept.id: "resumed"])
    #expect(sbd.row(report, gone.id)?["error"]?.string?.contains("is gone") == true, "\(report)")
    #expect(try sbd.pauseField(gone.id) == nil)
    #expect(try sbd.pauseField(kept.id) == nil)
    #expect(try sbd.waitForPrompts(kept.id, after: marks.kept, count: 1) == [defaultResume])
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(gone.id, after: marks.gone).isEmpty)
  }

  // MARK: A ref that names a session and a group

  /// How the session's ref collides with the group: the session has the group's name, or the group's name is a
  /// prefix of the session's id.
  enum Collision: String, CaseIterable, Sendable { case sessionName, sessionIdPrefix }

  /// A session outside the group, and group Flags or a group named by a prefix of the session's id, with one live
  /// member. It returns the ref that names both.
  private func collision(_ sbd: Instance, _ how: Collision) throws -> (
    ref: String, session: SessionSummary, member: SessionSummary
  ) {
    let member = try sbd.liveIdle("m")
    switch how {
    case .sessionName:
      let session = try sbd.liveIdle("Flags")
      _ = try sbd.addGroup("Flags", [member.id])
      return ("Flags", session, member)
    case .sessionIdPrefix:
      let session = try sbd.liveIdle("x")
      let ref = String(session.id.prefix(4))
      _ = try sbd.addGroup(ref, [member.id])
      return (ref, session, member)
    }
  }

  @Test(arguments: Collision.allCases)
  func aPauseOfARefThatNamesASessionAndAGroupIsRefused(_ how: Collision) throws {
    let sbd = try Instance()
    let c = try collision(sbd, how)

    let r = try sbd.run(["pause", c.ref])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("names a session and a group"), "\(r.stderr)")
    #expect(try sbd.pauseField(c.session.id) == nil)
    #expect(try sbd.pauseField(c.member.id) == nil)
  }

  @Test(arguments: Collision.allCases)
  func aResumeOfARefThatNamesASessionAndAGroupIsRefused(_ how: Collision) throws {
    let sbd = try Instance()
    let c = try collision(sbd, how)
    try sbd.pauseJSON(c.session.id)
    try sbd.pauseJSON(c.member.id)

    let r = try sbd.run(["resume", c.ref])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("names a session and a group"), "\(r.stderr)")
    #expect(try sbd.pauseField(c.session.id) != nil)
    #expect(try sbd.pauseField(c.member.id) != nil)
  }

  @Test func groupAndTheSessionIdEachPickOneSideOfTheSharedName() throws {
    let sbd = try Instance()
    let c = try collision(sbd, .sessionName)

    let report = try #require(JSON.parse(try sbd.sb("pause", "--group", "Flags", "--json")))

    #expect(sbd.results(report) == [c.member.id: "paused"], "\(report.text)")
    #expect(try sbd.pauseField(c.session.id) == nil)
    try sbd.pauseJSON(c.session.id)
    #expect(try sbd.pauseField(c.session.id) != nil)
  }

  /// A session's whole id picks the session even when a group has that id as its name.
  @Test func aSessionsWholeIdPicksTheSessionOverAGroupWithThatName() throws {
    let sbd = try Instance()
    let session = try sbd.liveIdle("x")
    let member = try sbd.liveIdle("m")
    _ = try sbd.addGroup(session.id, [member.id])

    try sbd.pauseJSON(session.id)

    #expect(try sbd.pauseField(session.id) != nil)
    #expect(try sbd.pauseField(member.id) == nil)
    try sbd.pauseJSON(member.id)
    try sbd.resumeJSON([session.id])
    #expect(try sbd.pauseField(session.id) == nil)
    #expect(try sbd.pauseField(member.id) != nil)
  }

  /// sbd refuses a ref that matches several sessions and also names a group, rather than reading it as the group.
  @Test func aRefThatMatchesSeveralSessionsAndAGroupIsRefused() throws {
    let sbd = try Instance()
    let g = try twoLive(sbd)
    let prefix = String(g.a.id.prefix(1))
    let member = try sbd.liveIdle("m")
    _ = try sbd.addGroup(prefix, [member.id])

    let r = try sbd.run(["pause", prefix])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("names a session and a group"), "\(r.stderr)")
    for id in [g.a.id, g.b.id, member.id] { #expect(try sbd.pauseField(id) == nil, "\(id)") }
  }

  /// This holds before groups too. It guards the fallback from replacing the session lookup's error.
  @Test func aRefThatNamesNoSessionAndNoGroupGetsTheSessionError() throws {
    let sbd = try Instance()
    _ = try twoLive(sbd)

    let r = try sbd.run(["pause", "nosuch"])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("no session nosuch"), "\(r.stderr)")
  }
}
