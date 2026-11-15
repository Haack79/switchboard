import Foundation

extension MCPToolServer {
  static let pauseTools: [Tool] = [
    Tool(
      "pause",
      "Pauses one session, or each session in a group that has started, isn't done, and isn't paused. A pause stops claude and keeps it stopped. Switchboard holds every message, notice, and wait outcome for the session until it resumes, and nothing else starts it. Give exactly one of `session` and `group`. `until` resumes the session on its own: at a time such as 2h or 2026-11-15 09:00, when a PR such as #123 or owner/name#123 merges, or when another session reaches a state, written session:<name>[=<state>] (Done by default). To free CPU or to hold work, pause a session instead of stopping it, because a stopped session moves to Needs you and wakes on the next message.",
      [
        "session": session, "group": group,
        "until": string(
          "When the session resumes on its own: a duration or time such as 2h or 2026-11-15 09:00, a PR that merges, such as #123, owner/name#123, or a PR URL; or session:<name>[=<state>]. Omit it to stay paused until `resume`."
        ),
        "reason": string(
          "Why the session is paused, in one line. Switchboard shows it to the user on the session's Paused line."),
        "message": string(
          "The message that the session gets when it resumes, before the messages that were held. Default: a note that it was paused."
        ),
      ]),
    Tool(
      "resume",
      "Resumes a paused session, or each paused session in a group. Give exactly one of `session` and `group`. The session first gets `message`, else the message stored with its pause, else a note that it was paused. Then it gets the messages that were held.",
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
