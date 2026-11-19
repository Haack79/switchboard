import Foundation
import SwitchboardCore

extension Service {
  /// Starts a fresh operator conversation when `OperatorReset.due` says so and nothing in flight needs the current
  /// one. A running claude must be quiet, and sbd stops it. Once claude has exited, sbd gives the operator a new
  /// Claude session id and launches nothing. The next message then starts claude with `--session-id` on the new id.
  /// A message that arrives first keeps the old conversation until the next quiet tick. It runs on the state queue.
  func rotateOperatorIfDue(now: Int64) {
    guard let id = operatorID(quiet: true), let e = entries[id], e.session.host == nil, e.facts.turnsSinceReset > 0,
      OperatorReset.blocker(waits: e.session.waits ?? [], facts: e.facts) == nil,
      canTakeNotice(e, now: now), e.pending.isEmpty, e.mcpRelaunch == nil, e.resumeLaunch == nil
    else { return }
    guard OperatorReset.due(e.facts, created: e.session.created, now: now, settings: tickOperatorSettings())
    else { return }
    switch claudeState(id) {
    case .running(let pid):
      let jobs = backgroundJobs(pid, in: processes(of: id))
      guard stopPolicy.isQuiet(stopInput(e, jobs: jobs, now: now)), e.facts.subagents.isEmpty, !e.facts.exiting
      else { return }
      do { try stop(id, reason: "its conversation restarts") } catch {
        logLine("can't stop the operator \(id) for a fresh conversation: \(error)")
      }
    case .stopped:
      let from = e.session.claudeSessionId
      let to = UUID().uuidString.lowercased()
      do { try update(id) { $0.claudeSessionId = to } } catch {
        logLine("can't start a fresh conversation for the operator \(id): \(error)")
        return
      }
      record(
        id, OperatorReset.event,
        ["from": .string(from), "to": .string(to), "turns": .number(Double(e.facts.turnsSinceReset))])
    case .starting, .unknown:
      return
    }
  }

  /// config.json's `operator` settings for the tick. sbd reads the file again only when its modification time
  /// changes, because the tick asks every second. A config.json that doesn't decode leaves the settings that sbd
  /// started with, and logs nothing, so a broken file does not log a line per tick.
  func tickOperatorSettings() -> OperatorSettings {
    let modified = (try? FileManager.default.attributesOfItem(atPath: home.config))?[.modificationDate] as? Date
    if let cached = cachedOperatorSettings, cached.modified == modified { return cached.settings }
    let settings = (try? home.readConfig().operator) ?? config.operator
    cachedOperatorSettings = (modified, settings)
    return settings
  }
}
