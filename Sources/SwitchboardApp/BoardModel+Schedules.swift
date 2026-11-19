import SwitchboardCore

extension BoardModel {
  func pauseSchedule(_ id: String, paused: Bool) {
    perform("pause-schedule", ["schedule": .string(id), "paused": .bool(paused)])
  }

  /// sbd makes the schedule due and sends nothing itself. Its tick runs the schedule once the session is free.
  func runSchedule(_ id: String) {
    perform("run-schedule", ["schedule": .string(id)])
  }

  /// The loop editor closes when sbd adds the loop. A refusal leaves it open, with the reason in `actionError`.
  /// `session` is a session id, or `Manager.operatorName`, for which sbd creates the operator when it has none.
  func addSchedule(session: String, every: String, prompt: String) {
    saveLoop(
      "schedule",
      [
        "session": .string(session), "every": .string(every), "prompt": .string(prompt),
        "by": .string(Author.you.rawValue),
      ])
  }

  /// Sends only the fields that are not nil. The loop editor closes as `addSchedule` describes.
  func editSchedule(_ id: String, every: String?, prompt: String?) {
    var args: [String: JSON] = ["schedule": .string(id)]
    if let every { args["every"] = .string(every) }
    if let prompt { args["prompt"] = .string(prompt) }
    saveLoop("edit-schedule", args)
  }

  private func saveLoop(_ op: String, _ args: [String: JSON]) {
    guard !savingLoop else { return }
    let opening = loopEditorOpening
    savingLoop = true
    perform(
      op, args, then: { _ in if self.loopEditorOpening == opening { self.loopEditor = nil } },
      finally: { self.savingLoop = false })
  }

  func removeSchedule(_ id: String) {
    perform("remove-schedule", ["schedule": .string(id)])
  }
}
