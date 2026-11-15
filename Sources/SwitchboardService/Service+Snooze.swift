import Foundation
import SwitchboardCore

extension Service {
  /// The `snooze` request, which holds the Inbox item of `session` in Waiting
  /// until `until` (a time that `Wait.parseTime` reads) or for `for` (a
  /// duration), or for `Snooze.defaultMs` without either. It changes nothing
  /// that sbd does to the session. A new snooze replaces the session's
  /// current one. `caller` is the asking session's id.
  func snoozeRequest(_ args: JSON) throws -> JSON {
    let id = try lookupOther(args, refusing: "snooze")
    let session = entries[id]!.session
    guard session.kind == .work else { throw APIError("only a work session can be snoozed") }
    if session.done { throw APIError("\(session.name) is marked done") }
    let now = nowMs()
    let until = try snoozeEnd(args, now: now)
    record(id, "snooze", ["until": .number(Double(until))])
    return try JSON(encoding: summary(id))
  }

  /// The `unsnooze` request, which ends the active snooze of `session`.
  func unsnoozeRequest(_ args: JSON) throws -> JSON {
    let id = try lookupOther(args, refusing: "snooze")
    let e = entries[id]!
    guard e.facts.snooze?.isActive(at: nowMs()) == true else { throw APIError("\(e.session.name) isn't snoozed") }
    record(id, "unsnooze")
    return try JSON(encoding: summary(id))
  }

  /// When the snooze that the request asks for ends.
  private func snoozeEnd(_ args: JSON, now: Int64) throws -> Int64 {
    let until = args["until"]?.string
    let duration = args["for"]?.string
    if until != nil && duration != nil { throw APIError("until and for don't go together") }
    if let duration, Wait.durationMs(duration) == nil {
      throw APIError("for takes a duration such as 30m, 2h, or 1d, not \(duration)")
    }
    guard let text = until ?? duration else { return now + Snooze.defaultMs }
    guard let time = Wait.parseTime(text, now: now) else { throw APIError("can't read the time \(text)") }
    guard time > now else { throw APIError("\(text) has passed") }
    // The event stores the time as a JSON number. A JSON number is a Double, which holds every integer only up to 2^53.
    guard time <= 1 << 53 else { throw APIError("\(text) is too far away") }
    return time
  }
}
