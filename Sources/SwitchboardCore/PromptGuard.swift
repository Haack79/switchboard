import Foundation

/// The checks that decide whether a session can take a prompt that sbd
/// sends on its own.
public enum PromptGuard {
  /// The state of the session's claude process.
  public enum Process: Sendable { case running, starting, stopped }

  /// Returns "an open card" when the session shows a card, a permission
  /// prompt, or a question. A new prompt starts a new turn, which buries the
  /// card. The card from `sb summary set` does not count.
  public static func openCard(_ f: SessionFacts) -> String? {
    if !f.cards.isEmpty || f.openPermission != nil || f.openQuestion != nil { return "an open card" }
    return nil
  }

  /// The first reason that the session's turn or process can't take a
  /// prompt now. `messageWaiting` is true while a message is queued or in
  /// flight for the session.
  public static func turn(_ f: SessionFacts, process: Process, messageWaiting: Bool) -> String? {
    if f.turnRunning { return "a turn is running" }
    if messageWaiting { return "a message is on its way" }
    if process == .starting || (process == .running && !f.live) { return "claude is starting or stopping" }
    return nil
  }
}
