import Foundation
import SwitchboardCore

extension Service {
  /// The `highlight` request, which highlights `session`, or with `highlighted` false clears its highlight. It
  /// records an event only when the value changes. It always returns the summary. It refuses a session that isn't a
  /// work session, a session whose evaluated state is Done, and the asking session `caller`. A session that
  /// highlighted itself could raise its own priority.
  func highlightRequest(_ args: JSON) throws -> JSON {
    let on = args["highlighted"]?.bool ?? true
    let by = try Author(parsing: args["by"]?.string)
    let id = try lookupOther(args, refusing: on ? "highlight itself" : "change its own highlight")
    let e = entries[id]!
    if on {
      guard e.session.kind == .work else { throw APIError("only a work session can be highlighted") }
      if Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState).state == .done {
        throw APIError("\(e.session.name) is done")
      }
    }
    if (e.session.highlighted == true) != on {
      try updateOrRestore([id]) { _, s in s.highlighted = on ? true : nil }
      record(id, on ? "highlighted" : "unhighlighted", ["by": .string(by.rawValue)])
    }
    return try JSON(encoding: summary(id))
  }

  /// Clears the highlight of a session whose evaluated state is Done. When the store can't save the change, the
  /// flag stays set. The next verdict tries again.
  func clearHighlightOnDone(_ id: String, _ verdict: Verdict) {
    guard verdict.state == .done, entries[id]?.session.highlighted == true else { return }
    do {
      try update(id) { $0.highlighted = nil }
    } catch {
      // `fold` can run inside `store.transaction`. This can't use `updateOrRestore`, because that opens its own
      // transaction. `update` changes the entry before it saves, so the flag goes back here.
      entries[id]?.session.highlighted = true
      logLine("can't clear the highlight of \(id): \(error)")
      return
    }
    record(id, "unhighlighted", ["by": "sbd", "why": "done"])
  }
}
