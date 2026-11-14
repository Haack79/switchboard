import Foundation
import SwitchboardCore

/// `sb pause <session|group> [--until WHEN] [--reason R] [--message M] [--json]`, or `--group G` in place of the
/// ref. sbd reads WHEN on its own clock.
func pauseCommand(_ a: Args) {
  var extra = whoAsks()
  if let until = a.values["--until"] { extra["until"] = .string(until) }
  if let reason = a.values["--reason"] { extra["reason"] = .string(reason) }
  if let message = a.values["--message"] { extra["message"] = .string(message) }
  targetCommand("pause", a, extra: extra)
}

/// `sb resume <session|group> [--message M | --prompt M] [--json]`, or `--group G` in place of the ref. sbd
/// refuses both flags together.
func resumeCommand(_ a: Args) {
  var extra = whoAsks()
  if let message = a.values["--message"] { extra["message"] = .string(message) }
  if let prompt = a.values["--prompt"] { extra["prompt"] = .string(prompt) }
  targetCommand("resume", a, extra: extra)
}

/// Sends the ref as `session`, which sbd reads as a group when no session matches it, or `--group` as `group`.
/// A group prints one line per session, such as `paused  s4k2p  flag-cache`.
private func targetCommand(_ op: String, _ a: Args, extra: [String: JSON]) {
  var args = extra
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

/// `by`, and `from` when Claude runs the command inside a session.
private func whoAsks() -> [String: JSON] {
  var args: [String: JSON] = ["by": .string(author.rawValue)]
  if author == .claude, let from = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["from"] = .string(from) }
  return args
}

/// The `paused:` line of `sb get`, such as `paused:  by Manager 5m ago: free CPU; 2 messages held`.
func printPause(_ s: SessionSummary) {
  guard let pause = s.pause else { return }
  let count = s.heldMessages ?? 0
  let held = count == 0 ? "" : "; \(count) message\(count == 1 ? "" : "s") held"
  print("  paused:  by \(pause.byText) \(ago(pause.since)) ago\(pause.detail)\(held)".printable)
}
