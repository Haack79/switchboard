import Foundation
import SwitchboardCore

/// Runs `highlight`, which rings a session in the app and puts its Inbox item first, or with `--clear` removes it.
func highlightCommand(_ a: Args) {
  var extra = callerArg
  extra["highlighted"] = .bool(!a.switches.contains("--clear"))
  extra["by"] = .string(author.rawValue)
  sessionCommand("highlight", a, extra: extra)
}
