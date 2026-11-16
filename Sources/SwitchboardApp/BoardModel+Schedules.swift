import SwitchboardCore

extension BoardModel {
  func pauseSchedule(_ id: String, paused: Bool) {
    perform("pause-schedule", ["schedule": .string(id), "paused": .bool(paused)])
  }

  func removeSchedule(_ id: String) {
    perform("remove-schedule", ["schedule": .string(id)])
  }
}
