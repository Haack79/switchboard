import Foundation
import SwitchboardCore

/// Runs `ack`, which takes a session's item out of the Inbox until its reason
/// changes or a new turn starts, or with `--undo` puts it back. It runs inside
/// Claude Code, so the Manager can use it. sbd refuses the caller's own session.
/// Inside Claude Code, sbd also refuses the operator while it has open reports.
func acknowledge(_ a: Args) {
  var extra = callerArg
  if a.switches.contains("--undo") { extra["undo"] = true }
  if author == .claude { extra["insideClaude"] = true }
  sessionCommand("ack", a, extra: extra)
}

/// `caller` set to the session that runs `sb`, when one does. sbd refuses
/// some requests from a session, such as acknowledging itself.
var callerArg: [String: JSON] {
  ProcessInfo.processInfo.environment["SB_SESSION_ID"].map { ["caller": .string($0)] } ?? [:]
}

/// `from` set to the session whose Claude runs `sb`. sbd records it on the
/// `sent` event. The message then doesn't count as the user's, and it doesn't
/// close the operator's reports.
var fromArg: [String: JSON] {
  guard author == .claude, let from = ProcessInfo.processInfo.environment["SB_SESSION_ID"] else { return [:] }
  return ["from": .string(from)]
}
