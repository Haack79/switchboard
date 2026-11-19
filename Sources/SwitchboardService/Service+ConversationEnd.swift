import Foundation
import SwitchboardCore

/// Ending a Manager conversation, and the context size that suggests it.
/// `plans/end-manager-conversation.md` in the notes repo describes it.
extension Service {
  /// A serial queue keeps the reads in the order of their turns, so an older turn's slow read can't replace a newer
  /// turn's value.
  static let contextReads = DispatchQueue(label: "sbd.context")

  /// Reads the conversation's context size from its transcript off the state queue, then records a `context` event
  /// when the value changed. A read that finishes after a `/clear`, a compaction, a resume of another conversation,
  /// or the conversation's removal records nothing.
  func recordContext(_ id: String) {
    guard let e = entries[id] else { return }
    let findTranscript = transcriptFinder(id)
    let machine = site(for: e.session).machine
    let claudeSessionId = e.session.claudeSessionId
    let lastStart = e.facts.lastStart
    Self.contextReads.async { [self] in
      let tokens = findTranscript().flatMap { Transcript.contextTokens($0, on: machine) }
      queue.async { [self] in
        guard let now = entries[id], now.session.claudeSessionId == claudeSessionId,
          now.facts.lastStart == lastStart, now.facts.contextTokens != tokens
        else { return }
        record(id, "context", ["tokens": tokens.map { .number(Double($0)) } ?? .null])
      }
    }
  }

  // MARK: Ending

  static let endCommand = "sb manager end"

  /// Refuses to remove a Manager conversation while a message is queued for it or claude has not confirmed one,
  /// whatever its pause state, because no id names a message and the removal would drop it unseen. It also
  /// refuses while its own waits, its pause condition, or its schedules hold an id that `endingDrops[id]` does
  /// not name. A wait handed to the operator sits on the operator, so it never blocks. `removalEntry` and
  /// `forgetSession` both call it, because a wait, a pause, or a message can land while the panes stop. It runs
  /// on the state queue.
  func refuseConversationRemoval(_ id: String) throws {
    guard let e = entries[id], e.session.kind == .manager else { return }
    let session = e.session
    if e.hasMessageOnItsWay { throw messagesRefusal(e) }
    let drops = endingDrops[id] ?? []
    let waits = session.resolvableWaits
    let schedules = session.schedules ?? []
    let unnamed =
      waits.filter { !drops.contains($0.id) }.map { "  \($0.id)  \(ownWaitLine($0, of: session))" }
      + schedules.filter { !drops.contains($0.id) }.map { "  \($0.id)  \(oneLine($0.prompt))" }
    guard !unnamed.isEmpty else { return }
    let flags = (waits.map(\.id) + schedules.map(\.id)).map { "--drop \($0)" }.joined(separator: " ")
    throw APIError(
      "\(session.name) has waits or schedules of its own that removing it would drop:\n"
        + unnamed.joined(separator: "\n")
        + "\nTo end it and drop them, run: \(Self.endCommand) \(id) \(flags)")
  }

  /// The refusal for a conversation that holds messages, with the step that delivers them in its state.
  private func messagesRefusal(_ e: Entry) -> APIError {
    let id = e.session.id
    let count = e.pending.count + (e.inFlight == nil ? 0 : 1)
    let lines =
      e.pending.map { "  \(oneLine($0.text))" }
      + (e.inFlight == nil ? [] : ["  a message that claude has not confirmed yet"])
    let remedy =
      if e.session.pause != nil {
        "Resume it to deliver them first, with: sb resume \(id)"
      } else if claudeState(id) == .stopped {
        "Start it to deliver them first, with: sb open \(id)"
      } else {
        "They reach claude once it is ready for them. Try again then."
      }
    return APIError(
      "\(e.session.name) has \(count == 1 ? "1 message on its" : "\(count) messages on their") way to it "
        + "that removing it would drop:\n"
        + lines.joined(separator: "\n") + "\n" + remedy)
  }

  /// The wait's line, or for the pause condition the pause's line and the message that the resume would send.
  private func ownWaitLine(_ wait: Wait, of session: Session) -> String {
    guard let pause = session.pause, pause.until?.id == wait.id else { return wait.line }
    return pause.line + (pause.message.map { ". The resume would send: \(oneLine($0))" } ?? "")
  }

  /// The `manager-end` request, which removes a Manager conversation, and with `new` starts one in its place
  /// with the same account, MCP servers, and pin. `drop` names the conversation's own waits, pause condition, and
  /// schedules that the removal may drop. Only the user ends a conversation: it refuses a request that names a `caller`, and a
  /// client below any local session's live Claude pane. It runs off the state queue, because `remove` does.
  func managerEnd(_ args: JSON, caller: Caller) throws -> JSON {
    if let from = args["caller"]?.string {
      let name = queue.sync { entries[from]?.session.name } ?? from
      throw APIError(
        "\(name) can't end a Manager conversation. Only the user ends one, from a terminal outside every session.")
    }
    let ancestry = try caller.ancestry(command: Self.endCommand)
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let drops = Set(args["drop"]?.array?.compactMap(\.string) ?? [])
    // A pane that started after the last tick is in no older snapshot.
    let fresh = ancestry == nil ? nil : buildSnapshot()
    let ending = try queue.sync { () -> Ending in
      install(fresh)
      if let ancestry, let pane = localClaudePane(holding: ancestry) {
        throw APIError(
          "`\(Self.endCommand)` runs inside the Claude pane of \(mention(pane)). "
            + "Only the user ends a conversation. Run it from a terminal outside the session.")
      }
      let id = try managerConversation(ref)
      let e = entries[id]!
      if e.facts.turnRunning || e.facts.jobs > 0 {
        throw APIError(
          "\(e.session.name) is in a turn or runs a background job. Wait for it to finish, or stop it with: sb stop \(id)"
        )
      }
      if removing.contains(id) || endingDrops[id] != nil { throw APIError("\(mention(id)) is being deleted") }
      endingDrops[id] = drops
      let own = e.session.resolvableWaits.map(\.id) + (e.session.schedules ?? []).map(\.id)
      return Ending(
        id: id, session: e.session, findTranscript: transcriptFinder(id), dropped: own.filter(drops.contains))
    }
    defer { queue.sync { endingDrops[ending.id] = nil } }
    let transcript = ending.findTranscript()
    _ = try remove(["session": .string(ending.id)], caller: caller)
    let session = ending.session
    var answer: [String: JSON] = [
      "ended": .string(ending.id), "name": .string(session.name), "transcript": transcript.map(JSON.string) ?? .null,
      "claudeSessionId": .string(session.claudeSessionId),
      "handed": .array(queue.sync { handedOff(from: ending.id)?.waits ?? [] }.map { .string($0.id) }),
      "dropped": .array(ending.dropped.map(JSON.string)),
    ]
    if args["new"]?.bool == true {
      do {
        answer["started"] = try JSON(encoding: startInPlace(of: session, name: args["name"]?.string))
      } catch {
        throw APIError(
          "Ended \(session.name), whose transcript is at \(transcript ?? "an unknown path"), "
            + "but can't start a new conversation: \(error)")
      }
    }
    return .object(answer)
  }

  /// What `managerEnd` reads on the state queue before the removal.
  struct Ending {
    var id: String
    var session: Session
    var findTranscript: () -> String?
    /// The ids of the conversation's own waits, pause condition, and schedules that `drop` names.
    var dropped: [String]
  }

  /// A local session whose live Claude pane's pid is in `ancestry`. A shell pane does not count, so the user may
  /// end a conversation from a session's shell pane. It runs on the state queue.
  func localClaudePane(holding ancestry: Set<Int>) -> String? {
    entries.keys.sorted().first { id in
      guard entries[id]?.session.host == nil, let row = paneRow(id, .claude), !row.dead else { return false }
      return Processes.isValidPid(row.pid) && ancestry.contains(row.pid)
    }
  }

  /// Starts an untitled conversation, or one named `name`, with the account, MCP servers, and pin of `ended`.
  /// It runs off the state queue.
  private func startInPlace(of ended: Session, name: String?) throws -> SessionSummary {
    try ensureManagerFolder()
    awaitMCPServers()
    return try queue.sync {
      let id = try createManager(
        name: name.flatMap { $0.isEmpty ? nil : $0 }, prompt: nil, account: ended.claudeConfigDir, mcp: ended.mcp
      ).id
      if ended.pinned == true {
        try update(id) { $0.pinned = true }
        record(id, "pinned")
      }
      return summary(id)
    }
  }
}
