import Foundation
import SwitchboardCore

/// `sb operator [<text>] [--log]`. It opens the operator, and creates it when none exists. `report` and
/// `reports` are reserved first words.
func operatorCommand(_ a: Args) {
  switch a.positional.first {
  case "report": return operatorReport(a)
  case "reports": return operatorReports(a)
  default: break
  }
  if a.switches.contains("--log") { return printChatLog(a, ["operator": true]) }
  var args: [String: JSON] = [:]
  let text = a.positional.joined(separator: " ")
  if !text.isEmpty { args["text"] = .string(text) }
  if author == .claude, let from = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["from"] = .string(from) }
  printOpenOrSend(a, call("operator", args, timeout: 300))
}

/// `sb operator report [--needs-you] [--session S] <text>`, which only the operator runs.
private func operatorReport(_ a: Args) {
  let text = a.positional.dropFirst().joined(separator: " ")
  if text.isEmpty { die("operator report needs text") }
  var args: [String: JSON] = ["text": .string(text), "needsYou": .bool(a.switches.contains("--needs-you"))]
  if let caller = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["caller"] = .string(caller) }
  if let about = a.values["--session"] { args["session"] = .string(about) }
  let result = call("operator-report", args)
  if a.json { return printJSON(result) }
  print(reportLine(result))
}

/// `sb operator reports [--all]`: the operator's reports, oldest first.
private func operatorReports(_ a: Args) {
  let result = call("operator-reports", a.switches.contains("--all") ? ["all": true] : [:])
  if a.json { return printJSON(result) }
  for row in result.array ?? [] { print(reportLine(row)) }
}

/// A report on one line: its time, whether it is open, the session that it is about, and its text.
private func reportLine(_ row: JSON) -> String {
  let time = Wait.formatTime(Int64(row["t"]?.int ?? 0))
  let status = row["open"]?.bool == true ? "open" : row["needsYou"]?.bool == true ? "closed" : "info"
  let about = row["aboutName"]?.string.map { "\($0): " } ?? ""
  return "\(time)  \(status)  \(about)\(row["text"]?.string ?? "")".printable
}
