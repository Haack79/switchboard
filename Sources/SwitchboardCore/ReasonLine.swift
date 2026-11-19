extension SessionSummary {
  /// The reason line, marked when the user acknowledged it, while the user's
  /// snooze holds it, and with the note of a snooze that ended.
  public var reasonLine: String { marking(reason) }

  /// `text` with the marks that `reasonLine` adds to the reason.
  public func marking(_ text: String) -> String {
    var line = acknowledged == true ? "\(text) (acknowledged)" : text
    if let until = snoozedUntil { line += " (\(Snooze.label(until: until)))" }
    if let note = snoozeNote { line += " (\(note))" }
    return line
  }
}
