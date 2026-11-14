import Foundation
import SwitchboardCore

extension Service {
  /// The line that a dead Claude pane shows while the session isn't paused.
  static let stoppedPaneMessage =
    "Claude stopped. Switchboard resumes it when you open the session or send it a message."

  /// The tick stops a paused session's claude at most this often.
  static let pauseStopMs: Int64 = 5_000

  /// The line that a dead Claude pane shows while the session is paused.
  static func pausedPaneMessage(_ pause: Pause) -> String {
    "\(pause.line). Resume the session to start claude again."
  }

  /// Pauses one session and returns its summary. It refuses a session that hasn't started, a session that
  /// pauses itself, Claude pausing a Manager conversation or a group chat, and a session on a host that sbd
  /// can't read. A second pause replaces who paused, the reason, and the message, and keeps `since`.
  func pauseRequest(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let session = entries[id]!.session
    let by = try Author(parsing: args["by"]?.string)
    // A sender that sbd no longer knows goes unrecorded.
    let from = try? lookup(["session": args["from"] ?? .null])
    try refuseNotStarted(session)
    if from == id {
      throw APIError(
        "\(id) can't pause itself, because the pause stops the claude that runs this command. To wait on something, use sb wait"
      )
    }
    if by == .claude, let label = session.kind.label { throw APIError("only the user can pause \(label)") }
    try requireRead(id)
    let now = nowMs()
    let until = try args["until"]?.string.map { text in
      try Pause.parseUntil(text, now: now).makeWait(
        id: shortId("w", taken: waitIds(id)), waiter: id, now: now, findSession: waitTarget)
    }
    let pause = Pause(
      by: by, from: from.map(pauser), reason: try Pause.cleanReason(args["reason"]?.string),
      since: session.pause?.since ?? now, until: until, message: args["message"]?.string.flatMap(nonBlank))
    try update(id) { $0.pause = pause }
    entries[id]?.queuedSince = nil
    entries[id]?.queuedTrigger = nil
    entries[id]?.jumpedAt = nil
    entries[id]?.mcpRelaunch = nil
    entries[id]?.resumeLaunch = nil
    // tmux writes the dead message when claude exits, so it is set before the stop.
    setClaudeDeadMessage(id, Service.pausedPaneMessage(pause))
    record(id, "paused", try JSON(encoding: pause))
    // A starting claude has no pid to stop yet. The tick stops it once it has one.
    if case .running = claudeState(id) { enforcePause(id, now: nowMs()) }
    return try JSON(encoding: summary(id))
  }

  /// The ids of the session's open waits and of its pause condition, which a new wait or condition doesn't reuse.
  func waitIds(_ id: String) -> [String] {
    let session = entries[id]?.session
    return (session?.waits ?? []).map(\.id) + [session?.pause?.until?.id].compactMap { $0 }
  }

  /// The session that a `session` wait or a pause condition names, by id, prefix, or name.
  func waitTarget(_ ref: String) throws -> Wait.SessionTarget {
    let other = try lookup(["session": .string(ref)])
    return Wait.SessionTarget(id: other, name: entries[other]!.session.name)
  }

  /// The session's pause condition when `waitId` names it.
  func pauseCondition(_ id: String, _ waitId: String?) -> Wait? {
    guard let waitId, let until = entries[id]?.session.pause?.until, until.id == waitId else { return nil }
    return until
  }

  /// Resumes the session when `wait` is its pause condition, and returns whether it was. A met condition records
  /// no `wait-resolved`, because the condition isn't one of the session's waits.
  func resumeOnCondition(_ id: String, _ wait: Wait, outcome: String) throws -> Bool {
    guard pauseCondition(id, wait.id) != nil else { return false }
    try unpause(id, outcome: outcome, message: nil, trigger: .wait, by: nil, from: nil)
    return true
  }

  /// Refuses a request that names the pause condition as a wait to clear. Only a resume or the condition ends it.
  func refuseCondition(_ id: String, _ waitId: String) throws {
    guard pauseCondition(id, waitId) != nil else { return }
    throw APIError(
      "\(waitId) is the condition that resumes \(id), not a wait. Resume it with: sb resume \(id), or pause it again without --until"
    )
  }

  /// Stops the paused session's running claude, at most once every `pauseStopMs`. A claude that reported
  /// SessionEnd is already exiting, so it gets no second stop.
  func enforcePause(_ id: String, now: Int64) {
    guard let e = entries[id], !e.facts.exiting, now - (e.pauseStopAt ?? 0) >= Service.pauseStopMs else { return }
    entries[id]?.pauseStopAt = now
    do { try stop(id, reason: "paused") } catch { logLine("can't stop paused \(id): \(error)") }
  }

  /// Resumes a paused session with the request's message, else the pause's own. A session that isn't paused
  /// launches as `sb resume` always did, with the message as its prompt.
  func resumeRequest(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    let message = args["message"]?.string
    let prompt = args["prompt"]?.string
    if message != nil && prompt != nil { throw APIError("resume takes a message or a prompt, not both") }
    let text = (message ?? prompt).flatMap(nonBlank)
    if entries[id]!.session.pause != nil {
      let by = try Author(parsing: args["by"]?.string)
      let from = (try? lookup(["session": args["from"] ?? .null])).flatMap { $0 == id ? nil : $0 }
      try unpause(id, outcome: nil, message: text, trigger: from == nil ? .resume : .session, by: by, from: from)
    } else {
      try launch(id, prompt: text, trigger: .resume)
    }
    return try JSON(encoding: summary(id))
  }

  /// Ends the session's pause and sends the resume message ahead of the held messages. `outcome` says why it
  /// resumes, and `message` replaces the pause's text. `by` is nil when sbd resumes the session on its own. A
  /// stopped claude with nothing held resumes with the message as its prompt. Otherwise the message goes to the
  /// front of the queue. A claude that still runs gets a paste only once it is live and ready. The tick's
  /// relaunch for the queue starts claude after it exits. Each open wait's recheck counts from the resume, so
  /// the time spent paused doesn't make it overdue.
  func unpause(
    _ id: String, outcome: String?, message: String?, trigger: LaunchTrigger, by: Author?, from: String?
  ) throws {
    guard let session = entries[id]?.session, let pause = session.pause else { throw APIError("\(id) isn't paused") }
    try requireRead(id)
    try requireFolder(session)
    let now = nowMs()
    try update(id) { s in
      s.pause = nil
      // A date wait and a manual wait carry their own times.
      s.waits = s.waits?.map { w in
        guard w.kind != .date, w.kind != .manual else { return w }
        var fresh = w
        fresh.recheck = nil
        return config.recheck.stamped(fresh, from: now)
      }
    }
    entries[id]?.pauseStopAt = nil
    var data: [String: JSON] = ["pause": try JSON(encoding: pause), "by": .string(by?.rawValue ?? "sbd")]
    if let outcome { data["outcome"] = .string(outcome) }
    if let from { data["from"] = .string(from) }
    record(id, "unpaused", .object(data))
    setClaudeDeadMessage(id, Service.stoppedPaneMessage)
    let text = pause.resumeText(outcome: outcome, override: message)
    let byUser = by == .you
    if claudeState(id) == .stopped, entries[id]!.pending.isEmpty {
      _ = try send(id, text, byUser: byUser, trigger: trigger, from: from)
      return
    }
    let sent = try recordSent(id, text, .queued, byUser: byUser, from: from, extra: ["first": true])
    entries[id]?.pending.insert(QueuedMessage(text: text, sent: sent), at: 0)
    if claudeState(id) == .stopped {
      try launch(id, prompt: nil, trigger: trigger)
    } else {
      entries[id]?.resumeLaunch = trigger
      // The stop's event cleared `live`, so a claude that the pause stopped takes no paste.
      deliverPending(id, after: 0)
    }
  }

  /// The session that paused another, with a chat named by its group.
  private func pauser(_ id: String) -> Pause.Pauser {
    let s = entries[id]!.session
    return Pause.Pauser(id: id, name: s.chat.flatMap { groups[$0]?.name } ?? s.name, kind: s.kind)
  }

  /// Sets the line that the session's Claude pane shows once claude exits. A session with no Claude pane has
  /// none to set.
  func setClaudeDeadMessage(_ id: String, _ message: String) {
    guard paneRow(id, .claude) != nil else { return }
    do {
      try site(of: id).terminals().setDeadMessage(paneName(id, .claude), message)
    } catch {
      logLine("can't set the dead message of \(id): \(error)")
    }
  }
}

private func nonBlank(_ text: String) -> String? {
  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}
