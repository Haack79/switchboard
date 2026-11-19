import Foundation
import SwitchboardCore

/// The words after `sb schedule` that name a subcommand. A session with one
/// of these names is scheduled by its id.
let scheduleSubcommands = ["ls", "rm", "pause", "resume", "edit", "run"]

/// `sb schedule <session> --every <interval> <prompt>` adds a schedule.
/// `ls [<session>]` lists the schedules, `rm <id>` removes one, `pause <id>`
/// and `resume <id>` pause and resume one, `edit <id> [--every <interval>]
/// [<prompt>]` changes one, and `run <id>` makes one due now.
func scheduleCommand(_ a: Args) {
  let first = a.session("schedule")
  let result: JSON
  switch first {
  case "ls":
    guard a.positional.count <= 2 else { refuse(a.positional.dropFirst(2).joined(separator: " "), "schedule ls") }
    result = call("schedules", a.positional.count == 2 ? ["session": .string(a.positional[1])] : [:])
    if a.json { return printJSON(result) }
    let rows = decode(result, as: [ScheduleRow].self)
    if rows.isEmpty { print("No schedules.") }
    for r in rows { print("\(r.schedule.id)  \(r.name) (\(r.session))  \(scheduleText(r))".printable) }
    return
  case "rm", "pause", "resume", "run":
    guard a.positional.count == 2 else { die("schedule \(first) needs a schedule id") }
    let id = JSON.string(a.positional[1])
    switch first {
    case "rm": result = call("remove-schedule", ["schedule": id])
    case "run": result = call("run-schedule", ["schedule": id])
    default: result = call("pause-schedule", ["schedule": id, "paused": .bool(first == "pause")])
    }
  case "edit":
    guard a.positional.count >= 2 else { die("schedule edit needs a schedule id") }
    var args: [String: JSON] = ["schedule": .string(a.positional[1])]
    // An empty prompt argument still goes to sbd, which refuses it and keeps the interval too.
    if a.positional.count > 2 { args["prompt"] = .string(a.positional.dropFirst(2).joined(separator: " ")) }
    if let every = a.values["--every"] { args["every"] = .string(every) }
    guard args.count > 1 else { die("schedule edit needs --every or a prompt") }
    result = call("edit-schedule", args)
  default:
    var args: [String: JSON] = [
      "session": .string(first), "prompt": .string(a.positional.dropFirst().joined(separator: " ")),
      "by": .string(author.rawValue),
    ]
    if let every = a.values["--every"] { args["every"] = .string(every) }
    result = call("schedule", args)
  }
  if a.json { return printJSON(result) }
  let row = decode(result, as: ScheduleRow.self)
  print("\(first == "rm" ? "removed " : "")\(row.schedule.id)  \(scheduleText(row))".printable)
}

/// The row's line with the status that sbd computed. An sbd older than the
/// status sends none, so the line falls back to the next run.
func scheduleText(_ r: ScheduleRow) -> String {
  scheduleText(r.schedule, status: r.status?.text ?? r.schedule.nextText())
}

/// The prompt on one line, then the interval, the status, and the last result.
func scheduleText(_ s: Schedule, status: String) -> String {
  "\(oneLine(s.prompt))  \(s.timingText(status)) · \(s.lastText())"
}

/// The summary carries the facts that sbd's tick reads, so the status matches the one that sbd computes.
func printSchedules(_ s: SessionSummary) {
  for schedule in s.schedules ?? [] {
    let status = ScheduleStatus(schedule, hold: s.scheduleHold, now: nowMs())
    print("  schedule: \(schedule.id)  \(scheduleText(schedule, status: status.text))".printable)
  }
}
