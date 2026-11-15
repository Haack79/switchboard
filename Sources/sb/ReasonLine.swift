import SwitchboardCore

extension SessionSummary {
  /// The reason line, marked when the user acknowledged it, while the user's
  /// snooze holds it, and with the note of a snooze that ended.
  var reasonLine: String {
    var line = acknowledged == true ? "\(reason) (acknowledged)" : reason
    if let until = snoozedUntil { line += " (\(Snooze.label(until: until)))" }
    if let note = snoozeNote { line += " (\(note))" }
    return line
  }
}
