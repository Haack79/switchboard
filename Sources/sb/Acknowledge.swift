import Foundation
import SwitchboardCore

/// Runs `ack`, which takes a session's item out of the Inbox until its reason
/// changes or a new turn starts, or with `--undo` puts it back. It runs inside
/// Claude Code, so the Manager can use it. sbd refuses the caller's own session.
/// Inside Claude Code, sbd also refuses the operator while it has open reports.
func acknowledge(_ a: Args) {
  var extra = callerArg
  if a.switches.contains("--undo") { extra["undo"] = true }
  extra.merge(insideClaudeArg) { $1 }
  sessionCommand("ack", a, extra: extra)
}

/// `caller` set to the session that runs `sb`, when one does. sbd refuses
/// some requests from a session, such as acknowledging itself.
var callerArg: [String: JSON] {
  ProcessInfo.processInfo.environment["SB_SESSION_ID"].map { ["caller": .string($0)] } ?? [:]
}

/// `insideClaude` when a Claude Code runs `sb`. sbd then takes the request as Claude's, not the user's.
var insideClaudeArg: [String: JSON] { author == .claude ? ["insideClaude": true] : [:] }

/// The sender fields of a message that a Claude Code runs `sb` to send. They hold `insideClaude`, and `from` set to
/// its session when it runs in one. sbd records the message as Claude's. The message then doesn't close the
/// operator's reports.
var fromArg: [String: JSON] {
  guard author == .claude else { return [:] }
  var arg = insideClaudeArg
  arg["from"] = ProcessInfo.processInfo.environment["SB_SESSION_ID"].map(JSON.string)
  return arg
}
