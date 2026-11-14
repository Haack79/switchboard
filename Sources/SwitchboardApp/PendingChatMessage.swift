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

  /// The pending messages that `log` does not answer, in order. A user message answers a pending message when it
  /// comes after the pending message's `after` and after the message that answered the one before, and holds its
  /// text. Each log message answers one pending message at most. When the log no longer holds `after`, the search
  /// starts at the log's first message. A failed message stays.
  static func unanswered(_ pending: [PendingChatMessage], log: [ChatMessage]) -> [PendingChatMessage] {
    var cursor = 0
    return pending.filter { message in
      if message.failed { return true }
      let start = max(cursor, message.after.flatMap { log.lastIndex(of: $0) }.map { $0 + 1 } ?? 0)
      guard let match = log[start...].firstIndex(where: message.isAnswered) else { return true }
      cursor = match + 1
      return false
    }
  }

  /// Whether `message` is the transcript's record of this message. The match reads the text the way
  /// `Transcript.hasUserMessage` matches a paste, because the transcript adds image markers to a prompt.
  private func isAnswered(by message: ChatMessage) -> Bool {
    guard message.role == .user, !message.isNotice, message.commandOutput == nil else { return false }
    let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Foundation's `contains` finds no empty string. An images-only message has no text.
    return wanted.isEmpty || (message.slashCommand ?? message.text).contains(wanted)
  }
}
