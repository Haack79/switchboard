import Foundation
import SwitchboardCore

/// `sb pause <session> [--reason R] [--message M] [--json]`.
func pauseCommand(_ a: Args) {
  var extra = whoAsks()
  if let reason = a.values["--reason"] { extra["reason"] = .string(reason) }
  if let message = a.values["--message"] { extra["message"] = .string(message) }
  sessionCommand("pause", a, extra: extra)
}

/// `sb resume <session> [--message M | --prompt M] [--json]`. sbd refuses both flags together.
func resumeCommand(_ a: Args) {
  var extra = whoAsks()
  if let message = a.values["--message"] { extra["message"] = .string(message) }
  if let prompt = a.values["--prompt"] { extra["prompt"] = .string(prompt) }
  sessionCommand("resume", a, extra: extra)
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
