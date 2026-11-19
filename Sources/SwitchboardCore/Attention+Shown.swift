import Foundation

extension Attention {
  /// The verdict that the app and `sb` show. It is the one place that turns
  /// `evaluate`'s verdict into the shown verdict, by applying each display
  /// layer in order. sbd's own rules, such as waits, parent notices, and
  /// auto-continue, read `evaluate`'s verdict and never this one. A display
  /// layer therefore changes nothing that sbd does, with one exception: when
  /// an acknowledgment expires, sbd reads the session's PR at the next poll.
  public static func shown(_ verdict: Verdict, _ facts: SessionFacts, now: Int64, acknowledgedMs: Int64) -> Verdict {
    snoozed(acknowledged(verdict, facts, now: now, acknowledgedMs: acknowledgedMs), facts, now: now)
  }
}
