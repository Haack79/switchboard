import Foundation
import SwitchboardCore

/// Runs `snooze`, which takes a session's item out of the Inbox until a time,
/// or until a new prompt, a failed CI run, or the PR's merge ends it early. It
/// runs inside Claude Code, so the Manager can use it. sbd refuses the caller's
/// own session.
func snoozeCommand(_ a: Args) {
  var extra = callerArg
  let until = a.values["--until"]
  let duration = a.values["--for"]
  if until != nil && duration != nil { die("--until and --for don't go together") }
  if let until { extra["until"] = .string(until) }
  if let duration { extra["for"] = .string(duration) }
  sessionCommand("snooze", a, extra: extra)
}

/// Runs `unsnooze`, which ends a session's snooze and puts its item back.
func unsnoozeCommand(_ a: Args) {
  sessionCommand("unsnooze", a, extra: callerArg)
}
