import Foundation

/// The times that the app's Snooze menu offers and the end time that the snooze mark shows.
public enum SnoozePresets {
  static let durations: [(title: String, ms: Int64)] = [
    ("15 minutes", 900_000), ("1 hour", 3_600_000), ("3 hours", 10_800_000),
  ]

  /// 15 minutes, 1 hour, 3 hours, 09:00 tomorrow, and 09:00 next Monday, in
  /// that order. "Tomorrow" and "next Monday" are calendar days in `zone`, and
  /// next Monday is a week away on a Monday. Each end falls on a whole second,
  /// because `Wait.parseTime` reads an ISO 8601 time without fractions.
  public static func times(now: Int64, zone: TimeZone) -> [(title: String, until: Int64)] {
    let second = now / 1000 * 1000
    let calendar = gregorian(zone)
    let today = calendar.startOfDay(for: date(now))
    let weekday = calendar.component(.weekday, from: today)
    // Weekday 1 is Sunday and 2 is Monday. A Monday gets 7 days, not 0.
    let toMonday = (8 - weekday) % 7 + 1
    let dated = [("Tomorrow", 1), ("Next Monday", toMonday)].map { title, days in
      let until = nine(daysAfter: today, days, calendar)
      return (title: "\(title) (\(weekdayTime(until, calendar)))", until: until)
    }
    return durations.map { (title: $0.title, until: second + $0.ms) } + dated
  }

  /// The snooze mark's end time: `HH:mm` when it ends today in `zone`,
  /// `EEE HH:mm` within the next 6 calendar days, and `MMM d HH:mm` after that.
  /// It formats the parts itself, because a refresh path calls it.
  public static func shortTime(until: Int64, now: Int64, zone: TimeZone) -> String {
    let calendar = gregorian(zone)
    let end = date(until)
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date(now)), to: calendar.startOfDay(for: end)
    ).day!
    switch days {
    case 0: return hourMinute(until, calendar)
    case 1...6: return weekdayTime(until, calendar)
    default:
      let c = calendar.dateComponents([.month, .day], from: end)
      return "\(calendar.shortMonthSymbols[c.month! - 1]) \(c.day!) \(hourMinute(until, calendar))"
    }
  }

  static func gregorian(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

  /// 09:00 on the day `days` after `day`. Building it from the parts keeps it
  /// at 09:00 across a daylight-saving change.
  static func nine(daysAfter day: Date, _ days: Int, _ calendar: Calendar) -> Int64 {
    var c = calendar.dateComponents([.year, .month, .day], from: day)
    c.day! += days
    c.hour = 9
    return Int64(calendar.date(from: c)!.timeIntervalSince1970 * 1000)
  }

  static func hourMinute(_ ms: Int64, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date(ms))
    return String(format: "%02d:%02d", c.hour!, c.minute!)
  }

  static func weekdayTime(_ ms: Int64, _ calendar: Calendar) -> String {
    let weekday = calendar.component(.weekday, from: date(ms))
    return "\(calendar.shortWeekdaySymbols[weekday - 1]) \(hourMinute(ms, calendar))"
  }
}
