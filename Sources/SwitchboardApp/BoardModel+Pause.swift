import SwitchboardCore

extension BoardModel {
  /// Pauses one session with no reason, condition, or message. sbd refuses a request that names both a session
  /// and a group.
  func pause(_ id: String) { perform("pause", ["session": .string(id)]) }

  func pauseGroup(_ id: String) { sendToGroup("pause", id) }

  /// Resumes each paused member with the message in its own pause.
  func resumeGroup(_ id: String) { sendToGroup("resume", id) }

  /// A group pause or resume succeeds even when some members fail, so the failures come back in its rows.
  private func sendToGroup(_ op: String, _ id: String) {
    perform(
      op, ["group": .string(id)],
      then: { result in
        guard let report = try? JSONCoding.convert(result, to: PauseReport.self) else { return }
        let failed = report.sessions.filter { $0.result == .failed }.map { "\($0.name): \($0.error ?? "failed")" }
        if !failed.isEmpty { self.actionError = "\(op): \(failed.joined(separator: "; "))" }
      })
  }
}
