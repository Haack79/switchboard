import Foundation

extension Attention {
  /// The verdict that the app and `sb` show. It is the one place that turns
  /// `evaluate`'s verdict into the shown verdict, by applying each display
  /// layer in order. sbd's own rules, such as waits, parent notices, and
  /// auto-continue, read `evaluate`'s verdict and never this one. A display
  /// layer therefore changes nothing that sbd does.
  public static func shown(_ verdict: Verdict, _ facts: SessionFacts, now: Int64, acknowledgedMs: Int64) -> Verdict {
    acknowledged(verdict, facts, now: now, acknowledgedMs: acknowledgedMs)
  }
}
