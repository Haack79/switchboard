import Foundation

/// The user's snooze of a session, as `snooze` events record it. It holds the
/// session's Inbox item in Waiting until `until`, or until a new prompt, a
/// failed CI run, or the PR's merge ends it early.
public struct Snooze: Codable, Equatable, Sendable {
  /// When the snooze ends, in ms since the epoch.
  public var until: Int64
  /// Why the snooze ended before `until`, or nil when it didn't.
  public var wokeEarly: String?

  /// The snooze's length when the request names no time.
  public static let defaultMs: Int64 = 3_600_000

  public func isActive(at t: Int64) -> Bool { wokeEarly == nil && t < until }

  /// The note that an ended snooze adds to the item that came back.
  var note: String { Snooze.label(until: until) + (wokeEarly.map { ", woke early: \($0)" } ?? "") }

  /// "snoozed until" and the time, as `sb` and the note show it.
  public static func label(until: Int64) -> String { "snoozed until \(Wait.formatTime(until))" }
}

/// The facts that can end a snooze early, read before an event so that the
/// facts after it show what the event changed.
struct SnoozeTriggers {
  var prompts: OpenPrompts
  var ciFailed: Bool
  var merged: Bool

  init(_ facts: SessionFacts) {
    prompts = facts.openPrompts
    ciFailed = facts.pr?.ciFailed == true
    merged = facts.pr?.state == .merged
  }

  /// Why the facts in `after` end the snooze, or nil when they don't. When
  /// two rules hold, the first one names the wake.
  func wake(after: SnoozeTriggers) -> String? {
    if after.prompts.opened(since: prompts) { return "a new prompt" }
    if after.ciFailed && !ciFailed { return "CI failed" }
    if after.merged && !merged { return "the PR merged" }
    return nil
  }
}

extension SessionFacts {
  /// The kinds that end a snooze record that has ended, beside an event that
  /// moves `lastTouched`. Each one means that the user acted on the session.
  static let snoozeClearingKinds: Set = ["dialog_closed", "card_closed", "ack"]

  /// Folds the snooze events, and ends an active snooze early on an event
  /// after which `before.wake(after:)` names a reason. An ended record lasts
  /// until the user acts on the session or a new turn starts, so the item
  /// that came back keeps its note. Only `unsnooze` or a new `snooze` clears
  /// an active record. `before` is nil unless the snooze was active at the
  /// event's time. `touchedBefore` is `lastTouched` before the event.
  mutating func applySnooze(_ event: Event, before: SnoozeTriggers?, touchedBefore: Int64) {
    switch event.kind {
    case "snooze":
      guard let until = event.data["until"]?.int else { return }
      snooze = Snooze(until: Int64(until), wokeEarly: nil)
    case "unsnooze":
      snooze = nil
    default:
      guard let record = snooze else { return }
      if let before {
        // SnoozeTriggers reads self, so it runs before the write to snooze starts.
        let why = before.wake(after: SnoozeTriggers(self))
        snooze?.wokeEarly = why
      } else if !record.isActive(at: event.t),
        lastTouched != touchedBefore || SessionFacts.snoozeClearingKinds.contains(event.kind)
      {
        snooze = nil
      }
    }
  }
}

extension Attention {
  /// The snooze layer of `shown`. An active snooze moves an Inbox verdict to
  /// Waiting. After the snooze ends, the Inbox verdict carries a note that
  /// says when it ended and why it ended early. Any other verdict is unchanged.
  static func snoozed(_ verdict: Verdict, _ facts: SessionFacts, now: Int64) -> Verdict {
    guard AttentionState.inbox.contains(verdict.state), let snooze = facts.snooze else { return verdict }
    var out = verdict
    if snooze.isActive(at: now) {
      out.state = .waiting
      out.snoozed = true
    } else {
      out.snoozeNote = snooze.note
    }
    return out
  }
}

extension SessionSummary {
  /// The line that the Inbox, the menu bar, and a notification show for the
  /// session's item: its title, or the reason without an item, and the note
  /// of a snooze that ended.
  public var inboxTitle: String {
    let line = triage?.title ?? reason
    return snoozeNote.map { "\(line) (\($0))" } ?? line
  }
}
