import Foundation
import SwitchboardCore

/// A message that the user sent to a chat or a Manager conversation and that the chat's log does not hold yet.
/// The chat shows it until the transcript records the prompt, which happens when Claude's turn starts.
struct PendingChatMessage: Equatable, Identifiable {
  enum Status: Equatable {
    case sending
    case accepted(Delivery?)
    case failed(String)
  }

  let id = UUID()
  /// The text that was sent, without the images.
  let text: String
  /// The log's last message when the message was sent, or nil when the log was empty or had not loaded.
  let after: ChatMessage?
  var status: Status = .sending

  /// sbd's refusal, when it refused the message.
  var error: String? {
    if case .failed(let error) = status { return error }
    return nil
  }

  var failed: Bool { error != nil }

  /// Whether sbd took the message, so the transcript can hold it.
  var accepted: Bool {
    if case .accepted = status { return true }
    return false
  }

  /// What the progress line says, or nil when the send failed.
  var progress: String? {
    switch status {
    case .sending: "Sending…"
    case .accepted(.queued): "Queued…"
    case .accepted(.resumed): "Starting Claude…"
    case .accepted: "Waiting for Claude…"
    case .failed: nil
    }
  }

  /// The pending messages that `log` does not record, in order. A user message records a pending message when it
  /// comes after the pending message's `after` and after the message that recorded the one before, and holds its
  /// text. Each log message records one pending message at most. When the log no longer holds `after`, the search
  /// starts at the log's first message. A failed message stays.
  static func notInLog(_ pending: [PendingChatMessage], log: [ChatMessage]) -> [PendingChatMessage] {
    var cursor = 0
    return pending.filter { message in
      if message.failed { return true }
      let start = max(cursor, message.after.flatMap { log.lastIndex(of: $0) }.map { $0 + 1 } ?? 0)
      guard let match = log[start...].firstIndex(where: { $0.records(message.text) }) else { return true }
      cursor = match + 1
      return false
    }
  }
}
