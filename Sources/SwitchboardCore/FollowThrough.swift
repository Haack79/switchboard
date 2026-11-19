import Foundation

/// What sbd does when a wait's condition is met, in place of resuming the holder with the note. A wait holds one
/// action, which the request's `then` names.
public struct WaitAction: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    /// Lands the subject's PR the way `sb merge` does.
    case merge
    /// Removes the subject and its worktree, as `sb rm <subject> --worktree` does.
    case rmWorktree = "rm-worktree"
    /// Removes the subject, as `sb rm <subject>` does.
    case rm
    /// Records the wait's note as a report.
    case report

    /// What `sb wait` prints after it arms the action.
    public var confirmation: String {
      switch self {
      case .merge: "sbd merges this when it's ready"
      case .rmWorktree: "sbd removes the session and its worktree when this resolves"
      case .rm: "sbd removes the session when it's done"
      case .report: "sbd records the note as a report when this resolves"
      }
    }
  }

  public var kind: Kind
  /// For `report`, makes the report an Inbox item. Nil means an info report.
  public var needsYou: Bool?

  public init(kind: Kind, needsYou: Bool? = nil) {
    self.kind = kind
    self.needsYou = needsYou
  }

  /// Refuses a wait that the action can't go on, with the shape that the action takes.
  func requireShape(of wait: Wait) throws {
    let allowed: Bool
    let shape: String
    switch kind {
    case .merge:
      allowed = wait.kind == .session && wait.state == .readyToMerge
      shape = "a session wait with state ready_to_merge"
    case .rmWorktree:
      allowed =
        (wait.kind == .session && wait.state == .done) || (wait.kind == .merge && wait.pr?.repository != nil)
      shape = "a session wait with state done, or a merge wait whose target is a PR with its repository (owner/name#N)"
    case .rm:
      allowed = wait.kind == .session && wait.state == .done
      shape = "a session wait with state done"
    case .report:
      allowed = wait.kind != .manual
      shape = "a wait of any kind but manual"
    }
    guard allowed else { throw APIError("then \(kind.rawValue) goes only on \(shape)") }
  }
}

/// Where an action stands after its wait's condition was met. A wait with no status waits for its condition.
public enum ActionStatus: String, Codable, CaseIterable, Sendable {
  case running
  case held
  case awaitingJudgment = "awaiting-judgment"
}

/// The `operator` settings in config.json.
public struct OperatorSettings: Codable, Equatable, Sendable {
  /// The repositories, as `owner/name`, where sbd may merge a PR for a wait's action. The user edits this list.
  public var mergeRepos: [String] = []
  /// How long a held action waits before sbd checks it again.
  public var holdRetrySeconds = 120
  /// How long an action may stay held for one reason before sbd asks for judgment.
  public var holdLimitSeconds = 21600
  /// The model that answers judgment calls.
  public var judgeModel = "sonnet"

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = OperatorSettings()
    mergeRepos = try c.decodeIfPresent([String].self, forKey: .mergeRepos) ?? d.mergeRepos
    holdRetrySeconds = try c.decodeIfPresent(Int.self, forKey: .holdRetrySeconds) ?? d.holdRetrySeconds
    holdLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .holdLimitSeconds) ?? d.holdLimitSeconds
    judgeModel = try c.decodeIfPresent(String.self, forKey: .judgeModel) ?? d.judgeModel
  }

  /// Whether sbd may merge a PR of `repository`. The match ignores case.
  public func mergesIn(_ repository: String) -> Bool {
    mergeRepos.contains { Dependencies.sameRepo($0, repository) }
  }
}
