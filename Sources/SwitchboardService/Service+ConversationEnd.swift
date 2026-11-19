import Foundation
import SwitchboardCore

/// Ending a Manager conversation, and the context size that suggests it.
/// `plans/end-manager-conversation.md` in the notes repo describes it.
extension Service {
  /// A serial queue keeps the reads in the order of their turns, so an older turn's slow read can't replace a newer
  /// turn's value.
  static let contextReads = DispatchQueue(label: "sbd.context")

  /// Reads the conversation's context size from its transcript off the state queue, then records a `context` event
  /// when the value changed. A read that finishes after a `/clear`, a compaction, a resume of another conversation,
  /// or the conversation's removal records nothing.
  func recordContext(_ id: String) {
    guard let e = entries[id] else { return }
    let findTranscript = transcriptFinder(id)
    let machine = site(for: e.session).machine
    let claudeSessionId = e.session.claudeSessionId
    let lastStart = e.facts.lastStart
    Self.contextReads.async { [self] in
      let tokens = findTranscript().flatMap { Transcript.contextTokens($0, on: machine) }
      queue.async { [self] in
        guard let now = entries[id], now.session.claudeSessionId == claudeSessionId,
          now.facts.lastStart == lastStart, now.facts.contextTokens != tokens
        else { return }
        record(id, "context", ["tokens": tokens.map { .number(Double($0)) } ?? .null])
      }
    }
  }
}
