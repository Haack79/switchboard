import Foundation
import SwitchboardCore

/// `sb operator [<text>] [--log]`. It opens the operator, and creates it when none exists.
func operatorCommand(_ a: Args) {
  if a.switches.contains("--log") { return printChatLog(a, ["operator": true]) }
  var args: [String: JSON] = [:]
  let text = a.positional.joined(separator: " ")
  if !text.isEmpty { args["text"] = .string(text) }
  printOpenOrSend(a, call("operator", args, timeout: 300))
}
