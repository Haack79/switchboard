import Foundation

extension MCPToolServer {
  static let pauseTools: [Tool] = [
    Tool(
      "pause",
      "Pauses a session, or each session in a group that has started, isn't done, and isn't paused. A pause stops claude and keeps it stopped: Switchboard holds every message, notice, and wait outcome for the session until it resumes, and nothing else starts it. `until` resumes it on its own: at a time such as 2h or 2026-11-15 09:00, when a PR such as #123 or owner/name#123 merges, or when another session reaches a state, written session:<name>[=<state>] (Done by default). Pause a session rather than stop it, because a stopped session moves to Needs you and wakes on the next message.",
      [
        "session": session, "group": group,
        "until": string("When the session resumes on its own: a time, a PR, or session:<name>[=<state>]."),
        "reason": string("Why the session is paused, on one line. Switchboard shows it with the pause."),
        "message": string("The message that the session resumes with. Default: a note that it was paused."),
      ]),
    Tool(
      "resume",
      "Resumes a paused session, or each paused session in a group. The session gets `message`, else the message stored with its pause, else a note that it was paused, and then the messages that waited.",
      ["session": session, "group": group, "message": string("The message that each session resumes with.")]),
  ]

  func pause(_ args: JSON, _ scoped: Scoped?) throws -> JSON {
    try client.call("pause", pauseTarget(args, scoped).merging(pick(args, ["until", "reason", "message"])) { $1 })
  }

  func resume(_ args: JSON, _ scoped: Scoped?) throws -> JSON {
    try client.call("resume", pauseTarget(args, scoped).merging(pick(args, ["message"])) { $1 })
  }

  /// The request's target, exactly one of `session` and `group`, and who asks. A scoped server also sends its
  /// group as `scope` and its session as `caller`, so that sbd checks the target in the same step as the change.
  private func pauseTarget(_ args: JSON, _ scoped: Scoped?) throws -> [String: JSON] {
    var request: [String: JSON] = ["by": MCPToolServer.byClaude]
    switch (args["session"]?.string, args["group"]?.string) {
    case (.some, nil): request["session"] = try sessionID(args, scoped)
    case (nil, .some(let ref)) where !ref.isEmpty: request["group"] = try groupID(args, scoped)
    default: throw APIError("name exactly one of session and group")
    }
    if let caller {
      request["from"] = .string(caller)
      if scoped != nil { request["caller"] = .string(caller) }
    }
    if let scoped { request["scope"] = .string(scoped.group.id) }
    return request
  }
}
