import Foundation
import SwitchboardCore

/// Runs `highlight`, which rings a session in the app and puts its Inbox item first, or with `--clear` removes the
/// highlight. It runs inside Claude Code, so the Manager can use it. sbd refuses the caller's own session.
func highlightCommand(_ a: Args) {
  var extra = callerArg
  extra["highlighted"] = .bool(!a.switches.contains("--clear"))
  extra["by"] = .string(author.rawValue)
  sessionCommand("highlight", a, extra: extra)
}
