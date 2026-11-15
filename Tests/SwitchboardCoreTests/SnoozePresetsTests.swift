import Foundation
import Testing

@testable import SwitchboardCore

private let fifteenMinutes: Int64 = 900_000
private let oneHour: Int64 = 3_600_000
private let threeHours: Int64 = 10_800_000

/// The string the app sends as `until`: ISO 8601 in UTC, as `ISO8601DateFormatter` writes it.
private func iso(_ ms: Int64) -> String {
  ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// A `now` in Los Angeles and the two dated presets it gives. The expected
/// ends are UTC literals. PST is UTC-8 and PDT is UTC-7. Los Angeles moves to
/// PDT on Sunday 2026-03-08 and back to PST on Sunday 2026-11-01.
struct DatedPresetCase: Sendable, CustomTestStringConvertible {
  var name: String
  var now: Int64
  var tomorrow: Int64
  var tomorrowDay: String
  var nextMonday: Int64
  var testDescription: String { name }
}

private let datedCases: [DatedPresetCase] = [
  DatedPresetCase(
    name: "Thursday afternoon", now: epochMs(2026, 11, 12, 23, 30, zone: utc),
    tomorrow: epochMs(2026, 11, 13, 17, 0, zone: utc), tomorrowDay: "Fri",
    nextMonday: epochMs(2026, 11, 16, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Tuesday 2:00 a.m.", now: epochMs(2026, 11, 17, 10, 0, zone: utc),
    tomorrow: epochMs(2026, 11, 18, 17, 0, zone: utc), tomorrowDay: "Wed",
    nextMonday: epochMs(2026, 11, 23, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Sunday afternoon", now: epochMs(2026, 11, 15, 22, 0, zone: utc),
    tomorrow: epochMs(2026, 11, 16, 17, 0, zone: utc), tomorrowDay: "Mon",
    nextMonday: epochMs(2026, 11, 16, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Monday 07:00, before 09:00", now: epochMs(2026, 11, 16, 15, 0, zone: utc),
    tomorrow: epochMs(2026, 11, 17, 17, 0, zone: utc), tomorrowDay: "Tue",
    nextMonday: epochMs(2026, 11, 23, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Monday 10:00, after 09:00", now: epochMs(2026, 11, 16, 18, 0, zone: utc),
    tomorrow: epochMs(2026, 11, 17, 17, 0, zone: utc), tomorrowDay: "Tue",
    nextMonday: epochMs(2026, 11, 23, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Saturday before the spring change", now: epochMs(2026, 3, 7, 20, 0, zone: utc),
    tomorrow: epochMs(2026, 3, 8, 16, 0, zone: utc), tomorrowDay: "Sun",
    nextMonday: epochMs(2026, 3, 9, 16, 0, zone: utc)),
  DatedPresetCase(
    name: "Sunday 03:00 PDT, just after the spring skip", now: epochMs(2026, 3, 8, 10, 0, zone: utc),
    tomorrow: epochMs(2026, 3, 9, 16, 0, zone: utc), tomorrowDay: "Mon",
    nextMonday: epochMs(2026, 3, 9, 16, 0, zone: utc)),
  DatedPresetCase(
    name: "Saturday before the fall change", now: epochMs(2026, 10, 31, 19, 0, zone: utc),
    tomorrow: epochMs(2026, 11, 1, 17, 0, zone: utc), tomorrowDay: "Sun",
    nextMonday: epochMs(2026, 11, 2, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Sunday 01:30 PDT, the first of the repeated hour", now: epochMs(2026, 11, 1, 8, 30, zone: utc),
    tomorrow: epochMs(2026, 11, 2, 17, 0, zone: utc), tomorrowDay: "Mon",
    nextMonday: epochMs(2026, 11, 2, 17, 0, zone: utc)),
  DatedPresetCase(
    name: "Thursday before the fall change", now: epochMs(2026, 10, 29, 19, 0, zone: utc),
    tomorrow: epochMs(2026, 10, 30, 16, 0, zone: utc), tomorrowDay: "Fri",
    nextMonday: epochMs(2026, 11, 2, 17, 0, zone: utc)),
]

@Suite struct SnoozePresetTimes {
  @Test(arguments: datedCases)
  func givesFivePresets(_ c: DatedPresetCase) {
    #expect(SnoozePresets.times(now: c.now, zone: losAngeles).count == 5)
  }

  @Test func durationPresetsComeFirstWithTheirLengths() {
    let now = epochMs(2026, 11, 12, 23, 30, zone: utc)

    let titles = SnoozePresets.times(now: now, zone: losAngeles).prefix(3).map(\.title)

    #expect(titles == ["15 minutes", "1 hour", "3 hours"])
  }

  @Test(arguments: datedCases)
  func durationPresetsAddTheirLengthToNow(_ c: DatedPresetCase) {
    let untils = SnoozePresets.times(now: c.now, zone: losAngeles).prefix(3).map(\.until)

    #expect(untils == [c.now + fifteenMinutes, c.now + oneHour, c.now + threeHours])
  }

  /// 01:30 PST on 2026-03-08, half an hour before Los Angeles skips from 02:00 to 03:00.
  @Test func durationPresetsCountElapsedTimeAcrossTheSpringSkip() {
    let now = epochMs(2026, 3, 8, 9, 30, zone: utc)

    let untils = SnoozePresets.times(now: now, zone: losAngeles).prefix(3).map(\.until)

    #expect(untils == [now + fifteenMinutes, now + oneHour, now + threeHours])
  }

  @Test(arguments: datedCases)
  func tomorrowIsNineOnTheNextCalendarDayInTheZone(_ c: DatedPresetCase) {
    let presets = SnoozePresets.times(now: c.now, zone: losAngeles)

    #expect(presets[3].until == c.tomorrow)
  }

  @Test(arguments: datedCases)
  func nextMondayIsNineOnTheFirstMondayAfterToday(_ c: DatedPresetCase) {
    let presets = SnoozePresets.times(now: c.now, zone: losAngeles)

    #expect(presets[4].until == c.nextMonday)
  }

  @Test(arguments: datedCases)
  func tomorrowTitleShowsTheWeekdayAndTime(_ c: DatedPresetCase) {
    let title = SnoozePresets.times(now: c.now, zone: losAngeles)[3].title

    #expect(title.hasPrefix("Tomorrow"))
    #expect(title.contains("\(c.tomorrowDay) 09:00"))
  }

  @Test(arguments: datedCases)
  func nextMondayTitleShowsTheWeekdayAndTime(_ c: DatedPresetCase) {
    let title = SnoozePresets.times(now: c.now, zone: losAngeles)[4].title

    #expect(title.hasPrefix("Next Monday"))
    #expect(title.contains("Mon 09:00"))
  }

  @Test(arguments: datedCases)
  func everyPresetEndsAfterNow(_ c: DatedPresetCase) {
    let presets = SnoozePresets.times(now: c.now, zone: losAngeles)

    #expect(presets.allSatisfy { $0.until > c.now })
  }

  /// 20:00 PST on Monday 2026-11-16 is 04:00 UTC on Tuesday 2026-11-17.
  @Test func datedPresetsFollowTheGivenZone() {
    let now = epochMs(2026, 11, 17, 4, 0, zone: utc)

    let inLA = SnoozePresets.times(now: now, zone: losAngeles).suffix(2).map(\.until)
    let inUTC = SnoozePresets.times(now: now, zone: utc).suffix(2).map(\.until)

    #expect(inLA == [epochMs(2026, 11, 17, 17, 0, zone: utc), epochMs(2026, 11, 23, 17, 0, zone: utc)])
    #expect(inUTC == [epochMs(2026, 11, 18, 9, 0, zone: utc), epochMs(2026, 11, 23, 9, 0, zone: utc)])
  }

  @Test func tomorrowTitleNamesTheWeekdayInTheGivenZone() {
    let now = epochMs(2026, 11, 17, 4, 0, zone: utc)

    let title = SnoozePresets.times(now: now, zone: utc)[3].title

    #expect(title.contains("Wed 09:00"))
  }
}

/// The app sends a preset's end as ISO 8601 in UTC, and sbd reads it with
/// `Wait.parseTime`. Both must name the same instant whatever sbd's zone is.
@Suite struct SnoozePresetWireTime {
  @Test(arguments: datedCases, [utc, losAngeles, kolkata])
  func everyPresetParsesBackToTheSameInstant(_ c: DatedPresetCase, _ sbdZone: TimeZone) {
    let presets = SnoozePresets.times(now: c.now, zone: losAngeles)

    let parsed = presets.map { Wait.parseTime(iso($0.until), now: c.now, zone: sbdZone) }

    #expect(parsed == presets.map { Optional($0.until) })
  }

  /// A real clock reads milliseconds. `Wait.parseTime` reads ISO 8601 without
  /// fractional seconds, so a preset's end must fall on a whole second for the
  /// app and sbd to agree on it.
  @Test(arguments: [0, 1, 123, 500, 999] as [Int64], [utc, losAngeles])
  func presetsFromASubSecondNowParseBackToTheSameInstant(_ millis: Int64, _ sbdZone: TimeZone) {
    let now = epochMs(2026, 11, 12, 23, 30, zone: utc) + millis
    let presets = SnoozePresets.times(now: now, zone: losAngeles)

    let parsed = presets.map { Wait.parseTime(iso($0.until), now: now, zone: sbdZone) }

    #expect(parsed == presets.map { Optional($0.until) })
  }

  @Test(arguments: [1, 123, 500, 999] as [Int64])
  func durationPresetsFromASubSecondNowStayWithinASecondOfTheirLength(_ millis: Int64) {
    let now = epochMs(2026, 11, 12, 23, 30, zone: utc) + millis

    let untils = SnoozePresets.times(now: now, zone: losAngeles).prefix(3).map(\.until)

    let lengths = [fifteenMinutes, oneHour, threeHours]
    #expect(zip(untils, lengths).allSatisfy { abs($0 - (now + $1)) < 1000 })
  }
}

/// The snooze mark's end time. "Today" and "the next 6 days" are calendar days
/// in the zone, so a weekday never names today's weekday a week later.
@Suite struct SnoozeShortTime {
  /// Saturday 2026-11-14 10:00 PST.
  static let saturdayMorning = epochMs(2026, 11, 14, 18, 0, zone: utc)

  @Test(arguments: [
    (epochMs(2026, 11, 14, 18, 15, zone: utc), "10:15"),
    (epochMs(2026, 11, 15, 7, 59, zone: utc), "23:59"),
  ])
  func endTodayShowsHoursAndMinutes(_ until: Int64, _ text: String) {
    #expect(SnoozePresets.shortTime(until: until, now: Self.saturdayMorning, zone: losAngeles) == text)
  }

  @Test(arguments: [
    (epochMs(2026, 11, 15, 8, 0, zone: utc), "Sun 00:00"),
    (epochMs(2026, 11, 16, 17, 0, zone: utc), "Mon 09:00"),
    (epochMs(2026, 11, 21, 7, 59, zone: utc), "Fri 23:59"),
  ])
  func endWithinTheNextSixDaysShowsTheWeekday(_ until: Int64, _ text: String) {
    #expect(SnoozePresets.shortTime(until: until, now: Self.saturdayMorning, zone: losAngeles) == text)
  }

  @Test(arguments: [
    (epochMs(2026, 11, 21, 8, 0, zone: utc), "Nov 21 00:00"),
    (epochMs(2026, 12, 1, 17, 5, zone: utc), "Dec 1 09:05"),
    (epochMs(2027, 1, 10, 17, 0, zone: utc), "Jan 10 09:00"),
  ])
  func endSevenOrMoreDaysAwayShowsTheDate(_ until: Int64, _ text: String) {
    #expect(SnoozePresets.shortTime(until: until, now: Self.saturdayMorning, zone: losAngeles) == text)
  }

  /// 07:59 UTC on Sunday is 23:59 PST on Saturday.
  @Test(arguments: [(losAngeles, "23:59"), (utc, "Sun 07:59")])
  func dayAndTimeFollowTheGivenZone(_ zone: TimeZone, _ text: String) {
    let until = epochMs(2026, 11, 15, 7, 59, zone: utc)

    #expect(SnoozePresets.shortTime(until: until, now: Self.saturdayMorning, zone: zone) == text)
  }

  /// Sunday 2026-11-01 lasts 25 hours in Los Angeles. 00:10 PDT to 23:50 PST is 24 hours and 40 minutes.
  @Test func endLaterOnTheLongFallDayIsToday() {
    let now = epochMs(2026, 11, 1, 7, 10, zone: utc)
    let until = epochMs(2026, 11, 2, 7, 50, zone: utc)

    #expect(SnoozePresets.shortTime(until: until, now: now, zone: losAngeles) == "23:50")
  }

  /// Sunday 2026-03-08 lasts 23 hours in Los Angeles. 00:30 PST to Monday 00:30 PDT is 23 hours.
  @Test func endAfterMidnightOfTheShortSpringDayIsTomorrow() {
    let now = epochMs(2026, 3, 8, 8, 30, zone: utc)
    let until = epochMs(2026, 3, 9, 7, 30, zone: utc)

    #expect(SnoozePresets.shortTime(until: until, now: now, zone: losAngeles) == "Mon 00:30")
  }

  /// Saturday 2026-10-31 10:00 PDT. The week after it crosses the fall change.
  @Test(arguments: [
    (epochMs(2026, 11, 7, 7, 59, zone: utc), "Fri 23:59"),
    (epochMs(2026, 11, 7, 8, 0, zone: utc), "Nov 7 00:00"),
  ])
  func sixDayBoundaryHoldsAcrossTheFallChange(_ until: Int64, _ text: String) {
    let now = epochMs(2026, 10, 31, 17, 0, zone: utc)

    #expect(SnoozePresets.shortTime(until: until, now: now, zone: losAngeles) == text)
  }
}
