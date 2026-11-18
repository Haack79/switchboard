import Foundation

/// A prompt that sbd sends to a session on an interval. It lives in the
/// session's row, so it survives restarts of sbd and of claude.
public struct Schedule: Codable, Equatable, Sendable {
  /// The result of one run.
  public struct Run: Codable, Equatable, Sendable {
    /// `pasted`, `resumed`, and `queued` are the raw values of `Delivery`.
    public enum Outcome: String, Codable, Sendable {
      case pasted
      case resumed
      case queued
      case failed

      public init(_ delivery: Delivery) {
        switch delivery {
        case .pasted: self = .pasted
        case .resumed: self = .resumed
        case .queued: self = .queued
        }
      }
    }

    /// Milliseconds since the epoch.
    public var t: Int64
    public var outcome: Outcome
    /// The due times that sbd dropped since the previous run.
    public var skipped: Int
    /// Set only for `failed`.
    public var error: String?

    public init(t: Int64, outcome: Outcome, skipped: Int, error: String? = nil) {
      self.t = t
      self.outcome = outcome
      self.skipped = skipped
      self.error = error
    }

    /// Such as `pasted 5m ago · 2 skipped` or `failed 2m ago: <error>`.
    public func text(now: Int64 = nowMs()) -> String {
      var text = "\(outcome.rawValue) \(ago(t, now: now)) ago"
      if let error { text += ": \(error)" }
      if skipped > 0 { text += " · \(skipped) skipped" }
      return text
    }
  }

  public static let maxPerSession = 10
  public static let maxRuns = 10
  /// One minute, in ms.
  public static let minInterval: Int64 = 60_000

  /// Unique across every session.
  public var id: String
  /// Sent verbatim, so a slash command runs as one.
  public var prompt: String
  /// The interval, in ms.
  public var every: Int64
  /// When the schedule is next due, in ms since the epoch. A time in the past
  /// means it waits for its session to be free.
  public var next: Int64
  /// Nil means active.
  public var paused: Bool?
  public var by: Author
  /// Milliseconds since the epoch.
  public var created: Int64
  /// Always equals `runs.first` once `record(_:)` wrote it.
  public var last: Run?
  /// The recent runs, newest first, at most `maxRuns`. Nil before the first
  /// recorded run and in a row stored before sbd kept the history.
  public var runs: [Run]?

  public init(
    id: String, prompt: String, every: Int64, next: Int64, paused: Bool? = nil, by: Author, created: Int64,
    last: Run? = nil, runs: [Run]? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.every = every
    self.next = next
    self.paused = paused
    self.by = by
    self.created = created
    self.last = last
    self.runs = runs
  }

  /// The known runs, newest first. A row stored before sbd kept the history shows its `last`.
  public var history: [Run] { runs ?? last.map { [$0] } ?? [] }

  /// Saves the run as `last` and as the newest of `runs`, so the two can't drift.
  public mutating func record(_ run: Run) {
    // `history` falls back to `last`, so `runs` changes before `last` does.
    runs = Array(([run] + history).prefix(Schedule.maxRuns))
    last = run
  }

  /// How long a due schedule waits before it counts as overdue: one interval,
  /// but at least 10 minutes and at most an hour.
  public static func overdueGrace(_ every: Int64) -> Int64 { min(max(every, 600_000), 3_600_000) }

  /// The prompt without the spaces and newlines at its ends. It refuses a prompt with nothing else.
  public static func cleanPrompt(_ text: String?) throws -> String {
    guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
      throw APIError("a schedule needs a prompt")
    }
    return prompt
  }

  /// The schedule with a new interval, a new prompt, or both. A new interval
  /// moves the next run to one interval from now when that is sooner, and a
  /// paused schedule keeps its next run, because resume sets it.
  public func edited(every: String?, prompt: String?, now: Int64) throws -> Schedule {
    guard every != nil || prompt != nil else {
      throw APIError("an edit needs every, an interval such as 30m, or a prompt")
    }
    var edited = self
    if let every {
      do {
        edited.every = try Schedule.parseInterval(every)
        let soonest = try Schedule.next(after: now, every: edited.every)
        if paused != true { edited.next = min(next, soonest) }
      } catch {
        throw APIError("every \(every): \(error)")
      }
    }
    if let prompt { edited.prompt = try Schedule.cleanPrompt(prompt) }
    return edited
  }

  /// Reads one whole number and one unit, `s`, `m`, `h`, `d`, or `w`, such as
  /// `30m`, and returns the interval in ms. It refuses an interval under
  /// `minInterval`.
  public static func parseInterval(_ text: String) throws -> Int64 {
    guard let ms = Wait.durationMs(text) else {
      if let total = compoundMs(text) {
        throw APIError("the interval \(text) has more than one unit. Write it with one, as \(intervalText(total))")
      }
      throw APIError("can't read the interval \(text). Write one number and one unit (s, m, h, d, or w), as 30m")
    }
    guard ms >= minInterval else { throw APIError("the shortest interval is 1m, so \(text) is too short") }
    return ms
  }

  /// The total of an interval such as `1h30m`, or nil for text that isn't
  /// two or more numbers that each have a unit.
  private static func compoundMs(_ text: String) -> Int64? {
    var parts: [Substring] = []
    var start = text.startIndex
    for i in text.indices where Wait.units[text[i]] != nil {
      parts.append(text[start...i])
      start = text.index(after: i)
    }
    guard parts.count > 1, start == text.endIndex else { return nil }
    var total: Int64 = 0
    for part in parts {
      guard let ms = Wait.durationMs(String(part)) else { return nil }
      let (sum, overflow) = total.addingReportingOverflow(ms)
      if overflow { return nil }
      total = sum
    }
    return total
  }

  /// An interval in the largest unit that divides it evenly, such as `30m`, `1h`, or `90s`.
  public static func intervalText(_ ms: Int64) -> String {
    let seconds = ms / 1000
    for (unit, size) in Wait.units.sorted(by: { $0.value > $1.value })
    where seconds % size == 0 && seconds >= size {
      return "\(seconds / size)\(unit)"
    }
    return "\(seconds)s"
  }

  /// The time one interval after `now`. It throws when that time is past the end of the clock.
  public static func next(after now: Int64, every: Int64) throws -> Int64 {
    let (next, overflow) = now.addingReportingOverflow(every)
    guard !overflow else { throw APIError("a run \(intervalText(every)) from now is past the end of the clock") }
    return next
  }

  public func isDue(now: Int64) -> Bool { paused != true && next <= now }

  /// The first reason that the session can't take the schedule's prompt now,
  /// or nil when it can. `process` is nil when sbd can't read the session's
  /// host. The card from `sb summary set` does not hold a schedule, as it
  /// does not hold a resolved `resume` wait.
  public static func blocker(facts: SessionFacts, process: PromptGuard.Process?, messageWaiting: Bool) -> String? {
    guard let process else { return "its host is not connected" }
    return PromptGuard.openCard(facts) ?? PromptGuard.turn(facts, process: process, messageWaiting: messageWaiting)
  }

  /// The reason that a session runs none of its schedules, or nil when it
  /// can run them. A removal job may be stopping the session's claude, so a
  /// session that the job holds waits too.
  public static func hold(done: Bool, paused: Bool, removing: Bool) -> String? {
    if done { return "the session is marked done" }
    if paused { return "the session is paused" }
    if removing { return "the session is being removed" }
    return nil
  }

  /// The next run after a run at `now`, and the due times that the run
  /// drops. The next run counts from `now`, not from the old due time.
  public func fired(at now: Int64) -> (next: Int64, skipped: Int) {
    let next = (try? Schedule.next(after: now, every: every)) ?? .max
    return (next, Int(max(0, now - self.next) / every))
  }

  /// The interval and the status text, such as `every 30m · next in 12m`. `sb schedule ls` and the app show it.
  public func timingText(_ status: String) -> String {
    "every \(Schedule.intervalText(every)) · \(status)"
  }

  /// When the schedule runs next, such as `next in 12m`, `paused`, or `due, runs when the session is free`.
  public func nextText(now: Int64 = nowMs()) -> String {
    if paused == true { return "paused" }
    if next <= now { return "due, runs when the session is free" }
    return "next \(fromNow(next, now: now))"
  }

  /// The result of the last run, such as `last: pasted 5m ago`, `last:
  /// failed 2m ago: <error>`, or `never ran`.
  public func lastText(now: Int64 = nowMs()) -> String {
    guard let last else { return "never ran" }
    return "last: \(last.text(now: now))"
  }
}

extension SessionSummary {
  /// `Schedule.hold` from the facts that `Service.summary` copies from the session, so it matches sbd's tick.
  public var scheduleHold: String? {
    Schedule.hold(done: markedDone, paused: pause != nil, removing: isBeingRemoved)
  }
}

/// The arguments of the `schedule` request, as sb sends them.
public struct ScheduleRequest: Codable, Equatable, Sendable {
  /// An interval such as `30m`.
  public var every: String?
  public var prompt: String?
  /// `you` or `claude`. Nil means you.
  public var by: String?

  public init(every: String?, prompt: String?, by: String?) {
    self.every = every
    self.prompt = prompt
    self.by = by
  }

  /// Checks the arguments and builds a schedule whose first run is one interval after `now`.
  public func makeSchedule(id: String, now: Int64) throws -> Schedule {
    guard let every else { throw APIError("a schedule needs every, an interval such as 30m") }
    let ms: Int64
    let next: Int64
    do {
      ms = try Schedule.parseInterval(every)
      next = try Schedule.next(after: now, every: ms)
    } catch {
      throw APIError("every \(every): \(error)")
    }
    return Schedule(
      id: id, prompt: try Schedule.cleanPrompt(prompt), every: ms, next: next, by: try Author(parsing: by), created: now
    )
  }
}

/// A schedule with its session, as the schedule requests return it.
public struct ScheduleRow: Codable, Equatable, Sendable {
  public var session: String
  public var name: String
  public var schedule: Schedule
  /// Computed when sbd answers, never stored. Nil from an sbd older than the status.
  public var status: ScheduleStatus?

  public init(session: String, name: String, schedule: Schedule, status: ScheduleStatus? = nil) {
    self.session = session
    self.name = name
    self.schedule = schedule
    self.status = status
  }

  /// The Loops tab's order: failed, overdue, due, active, held, then paused,
  /// then by the next run, then by id. A row without a status comes last.
  public static func attentionOrder(_ a: ScheduleRow, _ b: ScheduleRow) -> Bool {
    func key(_ r: ScheduleRow) -> (Int, Int64, String) { (r.status?.state.rank ?? 6, r.schedule.next, r.schedule.id) }
    return key(a) < key(b)
  }
}

/// Whether a schedule runs, waits, or needs the user, with a line that says so.
public struct ScheduleStatus: Codable, Equatable, Sendable {
  /// Agents read these raw values in `sb schedule ls --json`.
  public enum State: String, Codable, Sendable {
    case active
    case due
    case overdue
    case failed
    case held
    case paused

    fileprivate var rank: Int {
      switch self {
      case .failed: 0
      case .overdue: 1
      case .due: 2
      case .active: 3
      case .held: 4
      case .paused: 5
      }
    }
  }

  public var state: State
  public var text: String

  /// `hold` is `Schedule.hold` for the schedule's session, the reason that
  /// sbd's tick runs none of the session's schedules. The first rule that
  /// matches wins: paused, failed, active, held, overdue, then due.
  public init(_ schedule: Schedule, hold: String?, now: Int64) {
    if schedule.paused == true {
      state = .paused
      text = "paused"
      return
    }
    let (state, text) = ScheduleStatus.timing(schedule, hold: hold, now: now)
    if let last = schedule.last, last.outcome == .failed {
      self.state = .failed
      self.text = "failed \(ago(last.t, now: now)) ago\(last.error.map { ": \($0)" } ?? "") · \(text)"
    } else {
      self.state = state
      self.text = text
    }
  }

  public var needsAttention: Bool { state == .failed || state == .overdue }

  /// The state and text of an active schedule from its next run alone.
  private static func timing(_ schedule: Schedule, hold: String?, now: Int64) -> (State, String) {
    if schedule.next > now { return (.active, "next \(fromNow(schedule.next, now: now))") }
    if let hold { return (.held, "held: \(hold)") }
    if now - schedule.next >= Schedule.overdueGrace(schedule.every) {
      return (.overdue, "overdue by \(ago(schedule.next, now: now)), runs when the session is free")
    }
    return (.due, "due \(ago(schedule.next, now: now)) ago, runs when the session is free")
  }
}
