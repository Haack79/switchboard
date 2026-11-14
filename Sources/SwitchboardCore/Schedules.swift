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
  }

  public static let maxPerSession = 10
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
  public var last: Run?

  public init(
    id: String, prompt: String, every: Int64, next: Int64, paused: Bool? = nil, by: Author, created: Int64,
    last: Run? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.every = every
    self.next = next
    self.paused = paused
    self.by = by
    self.created = created
    self.last = last
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
    for (unit, size) in [("w", Int64(604_800)), ("d", 86_400), ("h", 3600), ("m", 60)]
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

  /// When the schedule runs next, as `sb schedule ls` shows it.
  public func nextText(now: Int64 = nowMs()) -> String {
    if paused == true { return "paused" }
    if next <= now { return "due, runs when the session is free" }
    return "next \(fromNow(next, now: now))"
  }

  /// The result of the last run, such as `last: pasted 5m ago`, `last:
  /// failed 2m ago: <error>`, or `never ran`.
  public func lastText(now: Int64 = nowMs()) -> String {
    guard let last else { return "never ran" }
    var text = "last: \(last.outcome.rawValue) \(ago(last.t, now: now)) ago"
    if let error = last.error { text += ": \(error)" }
    if last.skipped > 0 { text += " · \(last.skipped) skipped" }
    return text
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
    guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
      throw APIError("a schedule needs a prompt")
    }
    return Schedule(id: id, prompt: prompt, every: ms, next: next, by: try Author(parsing: by), created: now)
  }
}

/// A schedule with its session, as the schedule requests return it.
public struct ScheduleRow: Codable, Equatable, Sendable {
  public var session: String
  public var name: String
  public var schedule: Schedule

  public init(session: String, name: String, schedule: Schedule) {
    self.session = session
    self.name = name
    self.schedule = schedule
  }
}
