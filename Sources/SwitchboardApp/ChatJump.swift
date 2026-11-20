import SwitchboardCore

/// A request to show one loop run's prompt in a chat. While it stands, the chat's log reads with the run's `sent`
/// id, and the chat scrolls to the prompt instead of following its last message.
struct ChatJump: Equatable {
  enum Found: Equatable {
    /// The prompt's index in the stored log.
    case row(Int)
    /// sbd marked no message, so the chat can't show the prompt.
    case missing
  }

  let session: String
  let sent: Int64
  /// Nil until a `chat-log` answer read with `sent` arrives.
  var found: Found?

  /// The log without markers, and where the answer marked `sent`. The stored log never holds a marker, so it
  /// compares equal to a read without `sent`.
  static func reading(_ messages: [ChatMessage], sent: Int64) -> (log: [ChatMessage], found: Found) {
    var found = Found.missing
    let log = messages.enumerated().map { index, message in
      var message = message
      if message.sent == sent { found = .row(index) }
      message.sent = nil
      return message
    }
    return (log, found)
  }

  /// The row that the chat scrolls to the top, or nil when it has none.
  var row: Int? {
    if case .row(let row) = found { return row }
    return nil
  }

  /// Whether the chat follows its last message. A jump stops that until its answer shows the prompt is missing.
  static func followsBottom(_ jump: ChatJump?) -> Bool { jump == nil || jump?.found == .missing }
}
