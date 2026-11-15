import Foundation
import SwitchboardCore

extension BoardModel {
  /// Holds the session's Inbox item in Waiting until `until`. The Inbox moves
  /// its focus from a snoozed item to the next one.
  func snooze(_ id: String, until: Date) {
    guard snoozing.insert(id).inserted else { return }
    stepInboxPast(id)
    // The formatter writes whole seconds, the only form that `Wait.parseTime` reads.
    let time = ISO8601DateFormatter().string(from: until)
    perform(
      "snooze", ["session": .string(id), "until": .string(time)], finally: { self.snoozing.remove(id) })
  }

  /// Ends the session's snooze, which puts its item back in the Inbox.
  func unsnooze(_ id: String) {
    guard snoozing.insert(id).inserted else { return }
    perform(
      "unsnooze", ["session": .string(id)],
      then: { self.storeLastSeen(id, reply: $0) },
      finally: { self.snoozing.remove(id) })
  }
}
