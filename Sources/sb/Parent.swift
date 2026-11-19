import Foundation
import SwitchboardCore

/// `sb parent <session> [<parent> | --clear]` shows the session's parent, moves the session to another parent, or
/// unlinks it from its parent.
func parentCommand(_ a: Args) {
  let clear = a.switches.contains("--clear")
  let ref = a.session("parent")
  guard a.positional.count <= (clear ? 1 : 2) else { die("parent takes a session and a parent, or --clear") }
  let result: JSON
  if clear || a.positional.count == 2 {
    var args = callerArg
    args["session"] = .string(ref)
    args["by"] = .string(author.rawValue)
    if clear { args["clear"] = true } else { args["parent"] = .string(a.positional[1]) }
    result = call("parent", args)
  } else {
    result = call("get", ["session": .string(ref)])
  }
  if a.json { return printJSON(result) }
  let s = summary(result)
  guard let parent = s.parent else { return print("\(s.name) (\(s.id)) has no parent") }
  let name = (try? client.call("get", ["session": .string(parent)])).flatMap { $0["name"]?.string }
  print("\(s.name) (\(s.id)): parent \(name.map { "\($0) (\(parent))" } ?? parent)")
}
