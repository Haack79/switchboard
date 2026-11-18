import SwitchboardCore

extension BoardModel {
  func pauseSchedule(_ id: String, paused: Bool) {
    perform("pause-schedule", ["schedule": .string(id), "paused": .bool(paused)])
  }

  /// sbd makes the schedule due and sends nothing itself. Its tick runs the schedule once the session is free.
  func runSchedule(_ id: String) {
    perform("run-schedule", ["schedule": .string(id)])
  }

  func removeSchedule(_ id: String) {
    perform("remove-schedule", ["schedule": .string(id)])
  }
}
