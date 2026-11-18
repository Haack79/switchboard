extension SessionSummary {
  /// Whether sbd can merge or enqueue the session's PR: it is Ready to merge
  /// and sbd knows how its repository merges.
  public var canMerge: Bool {
    guard state == .readyToMerge, let method = pr?.mergeMethod else { return false }
    return method != .unknown
  }

  /// Whether the user can acknowledge the session's item, or undo that.
  public var canAcknowledge: Bool { acknowledged == true || AttentionState.inbox.contains(state) }

  /// Whether sbd accepts a snooze of the session: a work session that isn't marked done.
  public var canSnooze: Bool { kind == .work && !markedDone }

  /// Whether sbd accepts a highlight of the session: a work session that isn't Done.
  public var canHighlight: Bool { kind == .work && state != .done }

  public var isHighlighted: Bool { highlighted == true }

  /// False for a follow-up that hasn't started, a docket row, and a session whose worktree the cleanup removed.
  public var hasTerminals: Bool { runsClaude && cleanup?.state != .removed }
}
