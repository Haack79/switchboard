import Foundation

/// Which sessions a removal plan may take. `done` is Delete All's rule,
/// `isRemovableDone`. `work` is a multi-select delete's rule, `isRemovableWork`.
public enum RemovalScope: String, Sendable {
  case done
  case work
}

/// What a removal would remove, and the sessions it skips with the reason
/// that `rm` gives.
public struct RemovalPlan: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var pr: Int?
    /// The worktree's path, or nil when the worktree stays.
    public var worktree: String?
    /// The local branch, or nil when the branch stays.
    public var branch: String?
    public var remoteBranch: Bool

    public init(id: String, name: String, pr: Int?, worktree: String?, branch: String?, remoteBranch: Bool) {
      self.id = id
      self.name = name
      self.pr = pr
      self.worktree = worktree
      self.branch = branch
      self.remoteBranch = remoteBranch
    }
  }

  public struct Skip: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var reason: String

    public init(id: String, name: String, reason: String) {
      self.id = id
      self.name = name
      self.reason = reason
    }
  }

  public var remove: [Item]
  public var skip: [Skip]

  public init(remove: [Item], skip: [Skip]) {
    self.remove = remove
    self.skip = skip
  }
}

public struct RemovalResult: Codable, Equatable, Sendable {
  public var removed: [String]
  public var skipped: [RemovalPlan.Skip]
  /// Sessions that were removed while their branch or remote branch stayed,
  /// with the reason. Their ids are in `removed` too.
  public var partial: [RemovalPlan.Skip]

  public init(removed: [String], skipped: [RemovalPlan.Skip], partial: [RemovalPlan.Skip]) {
    self.removed = removed
    self.skipped = skipped
    self.partial = partial
  }

  public mutating func add(_ other: RemovalResult) {
    removed += other.removed
    skipped += other.skipped
    partial += other.partial
  }
}

extension SessionSummary {
  /// A session that a multi-select delete may remove, in any state: a work
  /// session, not the Manager or a chat, and not a follow-up that hasn't started.
  public var isRemovableWork: Bool { kind == .work && !waitsToStart }

  /// A Done session that the Done delete icon and Delete All may remove.
  public var isRemovableDone: Bool { state == .done && isRemovableWork }
}
