import Foundation
import SwitchboardCore

/// `sb send <session> [--run-here] [--image <path>]… [text]`. The `--run-here`
/// and `--image` pairs right after the session are flags, and every word after
/// them is text.
func sendCommand(_ a: Args) {
  var words = a.positional.dropFirst()
  var paths: [String] = []
  var runHere = false
  while let flag = words.first, flag == "--image" || flag == "--run-here" {
    words.removeFirst()
    if flag == "--run-here" {
      runHere = true
      continue
    }
    guard let path = words.popFirst() else { die("--image needs a path") }
    paths.append(path)
  }
  let text = words.joined(separator: " ")
  if text.isEmpty && paths.isEmpty { die("send needs text") }
  var args: [String: JSON] = ["session": .string(a.session("send")), "text": .string(text)]
  args.merge(fromArg) { $1 }
  if runHere {
    refuseInsideClaudeCode(
      "sb send --run-here runs a work skill in a Manager conversation for you, so it doesn't run inside Claude Code. Ask the user to run it in their own terminal."
    )
    args["runHere"] = true
    // sbd refuses `runHere` with `from`, so a process in a session can't run a work skill without CLAUDECODE.
    if let session = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["from"] = .string(session) }
  }
  if !paths.isEmpty {
    var total = 0
    do { try Attachments.checkMessage(count: paths.count, total: 0) } catch { die("\(error)") }
    args["images"] = .array(
      paths.map { path in
        let file = URL(fileURLWithPath: path.expandingTilde)
        do {
          let data = try Attachments.read(path: file.path)
          total += data.count
          try Attachments.checkMessage(count: paths.count, total: total)
          return Attachments.json(name: file.lastPathComponent, data: data)
        } catch {
          die("\(error)")
        }
      })
  }
  let result = call("send", args)
  if a.json { return printJSON(result) }
  guard let held = result["held"]?.string, let name = result["name"]?.string else {
    return print(result["delivery"]?.string ?? "sent")
  }
  print("held until \(name) resumes (\(held))".printable)
}
