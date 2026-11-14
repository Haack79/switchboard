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
      let id: String
      do {
        id = try lookup(args)
      } catch where args["group"] == nil && args["session"]?.string == Manager.operatorName {
        // The Manager guide schedules loops on the operator by name, so an unscoped request creates it as `sb wait` does.
        id = try ensureOperator()
      }
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
      let sessions = try entries.values.map(\.session)
        .filter { s in only == nil || only == s.id }
        .filter { try inScope($0.id, args: args) }
      let rows: [ScheduleRow] = sessions.flatMap { s in (s.schedules ?? []).map { scheduleRow(s.id, $0) } }
      func order(_ r: ScheduleRow) -> (Int, Int64, String) {
        (r.schedule.paused == true ? 1 : 0, r.schedule.next, r.schedule.id)
      }
      return try JSON(encoding: rows.sorted { order($0) < order($1) })
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
      try changeSchedule(id, schedule.id) { $0 = schedule }
      record(id, pausing ? "schedule-paused" : "schedule-resumed", ["schedule": try JSON(encoding: schedule)])
      return try JSON(encoding: scheduleRow(id, schedule))
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// Sends each due schedule's prompt to its session when the session is
  /// free. A schedule whose session is busy stays due and runs once when the
  /// session is free. The tick calls it after it resolves due waits. A
  /// session marked done keeps its schedules and runs none of them.
  func fireDueSchedules(now: Int64) {
    let ids = entries.compactMap { id, e in
      !e.session.done && e.session.schedules?.contains { $0.isDue(now: now) } == true ? id : nil
    }
    for id in ids.sorted() {
      guard let session = entries[id]?.session else { continue }
      let due = (session.schedules ?? []).filter { $0.isDue(now: now) }
        .sorted { ($0.next, $0.id) < ($1.next, $1.id) }
      // A run makes the session busy, so the guard runs again before each schedule.
      for schedule in due {
        guard let e = entries[id],
          Schedule.blocker(facts: e.facts, process: promptProcess(id), messageWaiting: e.messageWaiting(now: now))
            == nil
        else { break }
        fire(id, schedule, now: now)
      }
    }
  }

  /// Saves the next run before the send and the result after it, so a crash
  /// between the two loses the run instead of sending it twice. A failed send
  /// waits for the next run instead of trying again on each tick.
  private func fire(_ id: String, _ schedule: Schedule, now: Int64) {
    var ran = schedule
    let (next, skipped) = schedule.fired(at: now)
    ran.next = next
    do {
      try changeSchedule(id, schedule.id) { $0.next = next }
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id), because its next run can't be saved: \(error)")
      return
    }
    let run: Schedule.Run
    do {
      let delivery = try send(id, schedule.prompt, byUser: false, trigger: .schedule)
      run = Schedule.Run(t: now, outcome: .init(delivery), skipped: skipped)
    } catch {
      logLine("can't run schedule \(schedule.id) of \(id): \(error)")
      run = Schedule.Run(t: now, outcome: .failed, skipped: skipped, error: "\(error)")
    }
    ran.last = run
    do {
      try changeSchedule(id, schedule.id) { $0.last = run }
    } catch {
      logLine("can't save the run of schedule \(schedule.id) of \(id): \(error)")
    }
    var data: [String: JSON] = ["outcome": .string(run.outcome.rawValue), "skipped": .number(Double(skipped))]
    data["schedule"] = try? JSON(encoding: ran)
    if let error = run.error { data["error"] = .string(error) }
    record(id, "schedule-ran", .object(data))
  }

  /// Changes one schedule of the session and saves the session's row.
  private func changeSchedule(_ id: String, _ scheduleId: String, _ change: (inout Schedule) -> Void) throws {
    try update(id) { s in
      s.schedules = s.schedules?.map { schedule in
        var schedule = schedule
        if schedule.id == scheduleId { change(&schedule) }
        return schedule
      }
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
