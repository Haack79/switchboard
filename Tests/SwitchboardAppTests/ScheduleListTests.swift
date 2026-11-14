import SwitchboardCore
import Testing

@testable import SwitchboardApp

let scheduleNow: Int64 = 1_700_000_000_000
let minuteMs: Int64 = 60_000

func scheduleFixture(
  _ id: String, _ prompt: String = "Run the Waiting audit", every: Int64 = 30 * minuteMs,
  next: Int64 = scheduleNow + 12 * minuteMs, paused: Bool? = nil, last: Schedule.Run? = nil
) -> Schedule {
  Schedule(
    id: id, prompt: prompt, every: every, next: next, paused: paused, by: .you, created: scheduleNow - every,
    last: last)
}

func scheduledSession(
  _ schedules: [Schedule]?, waits: [Wait] = [], markedDone: Bool = false
) -> SessionSummary {
  var s = waitingSession(waits, markedDone: markedDone)
  s.schedules = schedules
  return s
}

@Suite struct ScheduleListTests {
  @Suite struct Timing {
    @Test func anActiveScheduleShowsItsIntervalAndHowSoonItRuns() {
      let caption = ScheduleCaption(scheduleFixture("r1"), now: scheduleNow)

      #expect(caption.timing == "every 30m · next in 12m")
    }

    @Test func anIntervalInHoursShowsInHours() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", every: 120 * minuteMs, next: scheduleNow + 90 * minuteMs), now: scheduleNow)

      #expect(caption.timing == "every 2h · next in 1h")
    }

    @Test func aScheduleWhoseRunIsPastDueSaysItRunsWhenTheSessionIsFree() {
      let caption = ScheduleCaption(scheduleFixture("r1", next: scheduleNow - 5 * minuteMs), now: scheduleNow)

      #expect(caption.timing == "every 30m · due, runs when the session is free")
    }

    /// Core counts a schedule as due from the moment `next` comes.
    @Test func aScheduleDueThisMomentSaysItRunsWhenTheSessionIsFree() {
      let caption = ScheduleCaption(scheduleFixture("r1", next: scheduleNow), now: scheduleNow)

      #expect(caption.timing == "every 30m · due, runs when the session is free")
    }

    @Test func aPausedScheduleSaysPaused() {
      let caption = ScheduleCaption(scheduleFixture("r1", paused: true), now: scheduleNow)

      #expect(caption.timing == "every 30m · paused")
    }

    /// A paused schedule keeps the `next` it had, which can be in the past. It is not held, so it doesn't say due.
    @Test func aPausedScheduleWhoseNextRunHasPassedSaysPausedNotDue() {
      let caption = ScheduleCaption(
        scheduleFixture("r1", next: scheduleNow - 5 * minuteMs, paused: true), now: scheduleNow)

      #expect(caption.timing == "every 30m · paused")
    }
  }

  @Suite struct LastResult {
    @Test func aScheduleThatHasNotRunSaysNeverRan() {
      #expect(ScheduleCaption(scheduleFixture("r1"), now: scheduleNow).result == "never ran")
    }

    @Test func aPastedRunWithNoSkippedTimesShowsTheOutcomeAndTheAge() {
      let run = Schedule.Run(t: scheduleNow - 5 * minuteMs, outcome: .pasted, skipped: 0)

      #expect(ScheduleCaption(scheduleFixture("r1", last: run), now: scheduleNow).result == "last: pasted 5m ago")
    }

    @Test func aPastedRunWithSkippedTimesCountsThem() {
      let run = Schedule.Run(t: scheduleNow - 5 * minuteMs, outcome: .pasted, skipped: 2)

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), now: scheduleNow).result
          == "last: pasted 5m ago · 2 skipped")
    }

    @Test(arguments: [Schedule.Run.Outcome.resumed, .queued])
    func aDeliveredRunNamesHowItWasDelivered(_ outcome: Schedule.Run.Outcome) {
      let run = Schedule.Run(t: scheduleNow - 3 * minuteMs, outcome: outcome, skipped: 0)

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), now: scheduleNow).result
          == "last: \(outcome.rawValue) 3m ago")
    }

    @Test func aFailedRunShowsTheError() {
      let run = Schedule.Run(
        t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 0, error: "the folder /work/gone is missing")

      #expect(
        ScheduleCaption(scheduleFixture("r1", last: run), now: scheduleNow).result
          == "last: failed 2m ago: the folder /work/gone is missing")
    }
  }

  @Suite struct Prompt {
    @Test func theRowShowsTheWholePrompt() {
      let prompt = "Run the Waiting audit.\nThen list the sessions that need me.\nThen stop.\nAnd a fourth line."

      #expect(ScheduleCaption(scheduleFixture("r1", prompt), now: scheduleNow).prompt == prompt)
    }
  }

  @Suite struct PauseButton {
    @Test func anActiveScheduleOffersPause() {
      #expect(ScheduleCaption(scheduleFixture("r1"), now: scheduleNow).toggleTitle == "Pause")
    }

    @Test func aPausedScheduleOffersResume() {
      #expect(ScheduleCaption(scheduleFixture("r1", paused: true), now: scheduleNow).toggleTitle == "Resume")
    }
  }

  /// `sb schedule ls` and the app read the same schedule. Their captions say the same thing.
  @Suite struct MatchesTheCLI {
    static let schedules: [Schedule] = [
      scheduleFixture("r1"),
      scheduleFixture("r2", next: scheduleNow),
      scheduleFixture("r3", next: scheduleNow - 45 * minuteMs),
      scheduleFixture("r4", paused: true),
      scheduleFixture("r5", every: 7 * 24 * 60 * minuteMs, next: scheduleNow + 3 * 24 * 60 * minuteMs),
      scheduleFixture("r6", every: 90_000, next: scheduleNow + 30_000),
      scheduleFixture("r7", last: Schedule.Run(t: scheduleNow - 1_000, outcome: .resumed, skipped: 0)),
      scheduleFixture("r8", last: Schedule.Run(t: scheduleNow - 3 * 3_600_000, outcome: .queued, skipped: 11)),
      scheduleFixture("r9", last: Schedule.Run(t: scheduleNow - 2 * minuteMs, outcome: .failed, skipped: 1, error: "")),
    ]

    @Test(arguments: schedules)
    func theTimingEndsWithTheCLIsNextText(_ schedule: Schedule) {
      let caption = ScheduleCaption(schedule, now: scheduleNow)

      #expect(
        caption.timing
          == "every \(Schedule.intervalText(schedule.every)) · \(schedule.nextText(now: scheduleNow))")
    }

    @Test(arguments: schedules)
    func theResultIsTheCLIsLastText(_ schedule: Schedule) {
      #expect(ScheduleCaption(schedule, now: scheduleNow).result == schedule.lastText(now: scheduleNow))
    }
  }

  @Suite struct Strip {
    @Test func drawsNothingForASessionWithoutSchedules() {
      #expect(SchedulesStrip.text(nil, now: scheduleNow) == nil)
    }

    @Test func drawsNothingForAnEmptyList() {
      #expect(SchedulesStrip.text([], now: scheduleNow) == nil)
    }

    @Test func oneScheduleSaysHowSoonItRuns() {
      #expect(SchedulesStrip.text([scheduleFixture("r1")], now: scheduleNow) == "1 schedule · next in 12m")
    }

    @Test func severalSchedulesCountThemAndShowTheSoonestRun() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 40 * minuteMs),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
        scheduleFixture("r3", next: scheduleNow + 25 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "3 schedules · next in 12m")
    }

    @Test func aHeldScheduleMakesTheStripSayDue() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 12 * minuteMs),
        scheduleFixture("r2", next: scheduleNow - 3 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · due")
    }

    @Test func aScheduleDueThisMomentMakesTheStripSayDue() {
      #expect(SchedulesStrip.text([scheduleFixture("r1", next: scheduleNow)], now: scheduleNow) == "1 schedule · due")
    }

    /// A paused schedule doesn't run, so its `next` is neither the soonest run nor a held one.
    @Test func aPausedScheduleWhoseNextRunHasPassedDoesNotMakeTheStripSayDue() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow - 3 * minuteMs, paused: true),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · next in 12m")
    }

    @Test func aPausedScheduleWithTheSoonestNextIsNotTheNextRun() {
      let schedules = [
        scheduleFixture("r1", next: scheduleNow + 2 * minuteMs, paused: true),
        scheduleFixture("r2", next: scheduleNow + 12 * minuteMs),
      ]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · next in 12m")
    }

    @Test func onlyPausedSchedulesSayPaused() {
      let schedules = [scheduleFixture("r1", paused: true), scheduleFixture("r2", paused: true)]

      #expect(SchedulesStrip.text(schedules, now: scheduleNow) == "2 schedules · paused")
    }
  }
}
