import Foundation
import SwitchboardCore

/// The words after `sb schedule` that name a subcommand. A session with one
/// of these names is scheduled by its id.
let scheduleSubcommands = ["ls", "rm", "pause", "resume"]

/// `sb schedule <session> --every <interval> <prompt>` adds a schedule.
/// `ls [<session>]` lists the schedules, `rm <id>` removes one, and
/// `pause <id>` and `resume <id>` pause and resume one.
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
    for r in rows { print("\(r.schedule.id)  \(r.name) (\(r.session))  \(scheduleText(r.schedule))".printable) }
    return
  case "rm", "pause", "resume":
    guard a.positional.count == 2 else { die("schedule \(first) needs a schedule id") }
    let id = JSON.string(a.positional[1])
    result =
      first == "rm"
      ? call("remove-schedule", ["schedule": id])
      : call("pause-schedule", ["schedule": id, "paused": .bool(first == "pause")])
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
  print("\(first == "rm" ? "removed " : "")\(row.schedule.id)  \(scheduleText(row.schedule))".printable)
}

/// The prompt on one line, then the interval, the next run, and the last result.
func scheduleText(_ s: Schedule) -> String {
  "\(oneLine(s.prompt)) (every \(Schedule.intervalText(s.every)), \(s.nextText()); \(s.lastText()))"
}

func printSchedules(_ s: SessionSummary) {
  for schedule in s.schedules ?? [] { print("  schedule: \(schedule.id)  \(scheduleText(schedule))".printable) }
}
