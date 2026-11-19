import Foundation

/// An Inbox verdict that the user acted on, as the state, the reason, and the
/// PR's head commit that the user saw.
public protocol SeenVerdict {
  var state: AttentionState { get }
  var reason: String { get }
  /// The PR's head commit when the user acted, or nil without a PR.
  var head: String? { get }
}

extension SeenVerdict {
  /// Whether the user saw this verdict for a session with these facts: the
  /// state, the reason, and the PR's head commit are the ones that the user saw.
  public func covers(_ verdict: Verdict, _ facts: SessionFacts) -> Bool {
    state == verdict.state && reason == verdict.reason && head == facts.pr?.headSha
  }
}

/// The Inbox item that the user marked as seen, as an `ack` event recorded it.
public struct Acknowledgment: Codable, Equatable, Sendable, SeenVerdict {
  public var state: AttentionState
  public var reason: String
  public var head: String?
  /// When the `ack` event was recorded. The event's time sets it, so the
  /// event's data leaves it out.
  public var at: Int64?

  public init(state: AttentionState, reason: String, head: String?, at: Int64? = nil) {
    self.state = state
    self.reason = reason
    self.head = head
    self.at = at
  }

  /// The acknowledgment of the verdict for a session with these facts.
  public init(_ verdict: Verdict, _ facts: SessionFacts) {
    self.init(state: verdict.state, reason: verdict.reason, head: facts.pr?.headSha)
  }
}

/// The cards, the permission prompt, and the question that wait on the user.
struct OpenPrompts {
  var cards: Set<Int64>
  var permission: ToolCall?
  var question: ToolCall?

  /// Whether a card, a prompt, or a question is open here that was not open in `before`.
  func opened(since before: OpenPrompts) -> Bool {
    !cards.isSubset(of: before.cards) || (permission != nil && permission != before.permission)
      || (question != nil && question != before.question)
  }
}

extension SessionFacts {
  var openPrompts: OpenPrompts {
    OpenPrompts(cards: Set(cards.map(\.id)), permission: openPermission, question: openQuestion)
  }

  /// `startTurn` clears the acknowledgment, so it covers one turn. A prompt
  /// that opens after `before` clears it too, because a new prompt is a new
  /// item even when its reason repeats the acknowledged one. sbd records
  /// `ack` after the prompt that it covers, so this never clears the
  /// acknowledgment of the prompt that the user saw.
  /// `before` is nil when no acknowledgment was set before the event.
  mutating func applyAcknowledgment(_ event: Event, promptsBefore before: OpenPrompts?) {
    switch event.kind {
    case "ack":
      acknowledgment = try? JSONCoding.convert(event.data, to: Acknowledgment.self)
      acknowledgment?.at = event.t
    case "unack": acknowledgment = nil
    default: if let before, openPrompts.opened(since: before) { acknowledgment = nil }
    }
  }
}

extension Attention {
  /// The Acknowledge layer of `shown`. An Inbox verdict that the user
  /// acknowledged moves to Waiting while its state, its reason, and the PR's
  /// head commit are the ones that the user saw, for `acknowledgedMs` after
  /// the acknowledgment. After that the verdict stays in the Inbox, and its
  /// reason says when the user acknowledged it.
  static func acknowledged(_ verdict: Verdict, _ facts: SessionFacts, now: Int64, acknowledgedMs: Int64) -> Verdict {
    guard let ack = covering(verdict, facts) else { return verdict }
    var out = verdict
    if acknowledgmentExpired(verdict, facts, now: now, acknowledgedMs: acknowledgedMs) {
      out.reason = "\(verdict.reason) (acknowledged \(Wait.formatTime(ack.at ?? now)), time to recheck)"
      return out
    }
    out.state = .waiting
    out.acknowledged = true
    return out
  }

  /// Whether the user acknowledged this Inbox verdict and `acknowledgedMs` passed since, so `shown` keeps it in
  /// the Inbox with "time to recheck".
  public static func acknowledgmentExpired(
    _ verdict: Verdict, _ facts: SessionFacts, now: Int64, acknowledgedMs: Int64
  ) -> Bool {
    guard let ack = covering(verdict, facts) else { return false }
    return now >= (ack.at ?? now) + acknowledgedMs
  }

  /// The session's acknowledgment when it covers this Inbox verdict, or nil.
  private static func covering(_ verdict: Verdict, _ facts: SessionFacts) -> Acknowledgment? {
    guard AttentionState.inbox.contains(verdict.state), let ack = facts.acknowledgment, ack.covers(verdict, facts)
    else { return nil }
    return ack
  }
}
