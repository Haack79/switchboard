import Foundation

/// Where in a transcript a message that sbd sent to claude can be, so `chat-log` can mark that message.
public struct SentMark: Equatable, Sendable {
  /// The id of the message's `sent` event.
  public var sent: Int64
  /// The claude conversation that the message went to. The transcript is `<conversation>.jsonl`.
  public var conversation: String
  /// The transcript's size just before the message went to claude.
  public var from: UInt64
  /// The transcript's size when sbd pasted the next message into the same conversation, or nil when it pasted none.
  public var before: UInt64?
  /// The text as claude received it, without image paths.
  public var text: String

  public init(sent: Int64, conversation: String, from: UInt64, before: UInt64?, text: String) {
    self.sent = sent
    self.conversation = conversation
    self.from = from
    self.before = before
    self.text = text
  }

  /// The mark of the `sent` event's message. `pastings` are the session's `pasting` events after `sent`, oldest
  /// first. `text` is the message's text without image paths.
  ///
  /// The mark starts at the last `pasting` that names `sent`, because a failed paste is pasted again. A launch
  /// with the prompt pastes nothing, so its `sent` event records the start itself. The mark ends at the next
  /// `pasting` of another message into the same conversation. A `pasting` that names no conversation came from an
  /// older sbd and counts as the same conversation, which can only shorten the mark.
  ///
  /// It is nil when the event is not a `sent` event, when the text is empty, or when no event records where the
  /// message started. A message that sbd restored from the log after a restart has a `pasting` that names no
  /// `sent`, so it gets no mark.
  public static func of(sent: Event, pastings: [Event], text: String) -> SentMark? {
    guard sent.kind == "sent", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let start: (data: JSON, after: Int)
    if let last = pastings.lastIndex(where: { names($0, sent.id) }) {
      start = (pastings[last].data, last + 1)
    } else if sent.data["delivery"]?.string == Delivery.resumed.rawValue, sent.data["transcript_bytes"] != nil {
      // Without a size, the mark would start at 0 and could find an earlier run's copy of the prompt.
      start = (sent.data, 0)
    } else {
      return nil
    }
    guard let conversation = start.data["conversation"]?.string else { return nil }
    let next = pastings[start.after...].first { pasting in
      !names(pasting, sent.id) && (pasting.data["conversation"]?.string ?? conversation) == conversation
    }
    return SentMark(
      sent: sent.id, conversation: conversation, from: offset(start.data),
      before: next.map { offset($0.data) }, text: text)
  }

  private static func names(_ pasting: Event, _ sent: Int64) -> Bool {
    pasting.data["sent"]?.int.map(Int64.init) == sent
  }

  /// A `pasting` that found no transcript records no size, because the file did not exist yet.
  private static func offset(_ data: JSON) -> UInt64 {
    UInt64(max(0, data["transcript_bytes"]?.int ?? 0))
  }
}
