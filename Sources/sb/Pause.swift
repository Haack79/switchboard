import Foundation
import SwitchboardCore

/// `sb pause <session|group> [--until WHEN] [--reason R] [--message M] [--json]`, or `sb resume <session|group>
/// [--message M | --prompt M] [--json]`, with `--group G` in place of the ref. Each `--k` in `flags` that is given
/// goes to sbd as `k`. sbd reads WHEN on its own clock, and refuses `--message` with `--prompt`.
///
/// It sends the ref as `session`, which sbd reads as a group when no session matches it, or `--group` as `group`.
/// A group prints one line per session, such as `paused  s4k2p  flag-cache`.
func targetCommand(_ op: String, _ a: Args, flags: [String]) {
  var args = whoAsks()
  for flag in flags {
    if let value = a.values["--\(flag)"] { args[flag] = .string(value) }
  }
  if let group = a.values["--group"] {
    if !a.positional.isEmpty { die("\(op) takes a session or --group, not both") }
    args["group"] = .string(group)
  } else {
    args["session"] = .string(a.session(op))
  }
  let result = call(op, args)
  if a.json { return printJSON(result) }
  guard result["sessions"] != nil else { return printSession(summary(result)) }
  for row in decode(result, as: PauseReport.self).sessions {
    let what = row.result.rawValue.replacingOccurrences(of: "_", with: " ")
    print("\(what)  \(row.session)  \(row.name)\(row.error.map { ": \($0)" } ?? "")".printable)
  }
}

/// The `paused:` line of `sb get`, such as `paused:  by Manager 5m ago: free CPU; 2 messages held`.
func printPause(_ s: SessionSummary) {
  guard let pause = s.pause else { return }
  let count = s.heldMessages ?? 0
  let held = count == 0 ? "" : "; \(count) message\(count == 1 ? "" : "s") held"
  print("  paused:  by \(pause.byText) \(ago(pause.since)) ago\(pause.detail)\(held)".printable)
}
