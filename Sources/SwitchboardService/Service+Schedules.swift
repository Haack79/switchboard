import Foundation
import SwitchboardCore

/// Schedules: prompts that sbd sends to a session on an interval.
extension Service {
  /// The `schedule`, `schedules`, `remove-schedule`, and `pause-schedule`
  /// requests. Each takes an optional `group` and `caller`, which a scoped MCP
  /// server sends. With `group`, a request acts only on the group's sessions
  /// and on the caller. It runs on the state queue, so the scope check and the
  /// change happen in one step.
  func scheduleRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "schedule":
      let id = try lookup(args)
      try requireInScope(id, args: args)
      let session = entries[id]!.session
      try refuseNotStarted(session)
      let open = session.schedules ?? []
      guard open.count < Schedule.maxPerSession else {
        throw APIError(
          "\(id) has \(Schedule.maxPerSession) schedules, the most a session can have. Remove one with: sb schedule rm <id>"
        )
      }
      let request = try JSONCoding.convert(args, to: ScheduleRequest.self)
      let taken = entries.values.flatMap { $0.session.schedules ?? [] }.map(\.id)
      let schedule = try request.makeSchedule(id: shortId("r", taken: taken), now: nowMs())
      try update(id) { $0.schedules = open + [schedule] }
      record(id, "schedule", ["schedule": try JSON(encoding: schedule)])
      return try JSON(encoding: scheduleRow(id, schedule))
    case "schedules":
      let only = try args["session"].map { _ in try lookup(args) }
      let rows = try entries.values.map(\.session)
        .filter { s in only == nil || only == s.id }
        .filter { try inScope($0.id, args: args) }
        .flatMap { s in (s.schedules ?? []).map { scheduleRow(s.id, $0) } }
        .sorted { ($0.schedule.next, $0.schedule.id) < ($1.schedule.next, $1.schedule.id) }
      return try JSON(encoding: rows)
    case "remove-schedule":
      let (id, schedule) = try ownedSchedule(args)
      try update(id) { s in
        let rest = (s.schedules ?? []).filter { $0.id != schedule.id }
        s.schedules = rest.isEmpty ? nil : rest
      }
      record(id, "schedule-removed", ["schedule": try JSON(encoding: schedule)])
      return try JSON(encoding: scheduleRow(id, schedule))
    case "pause-schedule":
      let (id, found) = try ownedSchedule(args)
      var schedule = found
      let pausing = args["paused"]?.bool ?? true
      guard pausing != (schedule.paused == true) else { return try JSON(encoding: scheduleRow(id, schedule)) }
      if pausing {
        schedule.paused = true
      } else {
        schedule.next = try Schedule.next(after: nowMs(), every: schedule.every)
        schedule.paused = nil
      }
      try update(id) { s in s.schedules = s.schedules?.map { $0.id == schedule.id ? schedule : $0 } }
      record(id, pausing ? "schedule-paused" : "schedule-resumed", ["schedule": try JSON(encoding: schedule)])
      return try JSON(encoding: scheduleRow(id, schedule))
    default:
      throw APIError("unknown request \(op)")
    }
  }

  private func scheduleRow(_ id: String, _ schedule: Schedule) -> ScheduleRow {
    ScheduleRow(session: id, name: entries[id]!.session.name, schedule: schedule)
  }

  /// The schedule that the request's `schedule` names, with its session. It
  /// throws when `session` is given and doesn't own the schedule, and when
  /// the owner is outside the request's scope.
  private func ownedSchedule(_ args: JSON) throws -> (session: String, schedule: Schedule) {
    guard let ref = args["schedule"]?.string, !ref.isEmpty else { throw APIError("name a schedule") }
    let named = try args["session"].map { _ in try lookup(args) }
    let owner = entries.values.lazy.map(\.session).compactMap { s in
      s.schedules?.first { $0.id == ref }.map { (session: s.id, schedule: $0) }
    }.first
    guard let owner, named == nil || named == owner.session else {
      throw APIError(named.map { "\($0) has no schedule \(ref)" } ?? "no schedule \(ref)")
    }
    try requireInScope(owner.session, args: args)
    return owner
  }

  /// Refuses a session outside the request's scope.
  func requireInScope(_ id: String, args: JSON) throws {
    guard try !inScope(id, args: args) else { return }
    let group = args["group"]?.string ?? ""
    throw APIError("\(id) is not in group \(groups[group]?.name ?? group)")
  }

  /// True when the request has no `group`, or when the session is in that
  /// group or is the `caller`. It throws for a `group` that isn't an id, so a
  /// malformed scope never reads as no scope.
  private func inScope(_ id: String, args: JSON) throws -> Bool {
    guard let value = args["group"] else { return true }
    guard let group = value.string, !group.isEmpty else { throw APIError("group is the id of a group") }
    return entries[id]?.session.group == group || id == args["caller"]?.string
  }
}
