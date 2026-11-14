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

  /// True while sbd's removal job holds the session. The app leaves such a session out of every list.
  public var isBeingRemoved: Bool { removal?.holdsSession == true }
}

/// A session's place in sbd's removal job, stored in the session's JSON.
/// `worktree`, `branch`, and `remoteBranch` are the `rm` arguments that the
/// job runs with.
public struct Removal: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case queued
    case running
    /// The job stopped before it forgot the session. `error` says why.
    case failed
  }

  public var state: State
  /// When `rm-queue` queued the session, in ms since the epoch.
  public var requested: Int64
  /// The time before which the job does not start the session, in ms since the epoch.
  public var notBefore: Int64?
  public var worktree: Bool
  public var branch: Bool
  public var remoteBranch: Bool
  /// `rm`'s message for a failed removal.
  public var error: String?
  /// The trash path of the worktree's folder, written before the folder moves there.
  public var trash: String?
  /// True once the trash check passed and git dropped the worktree's record,
  /// before the branch deletes. A restart then continues without the check,
  /// because the record that the check needs is gone.
  public var released: Bool?
  /// The ids of the session's open to-dos that the removal resolves.
  public var resolve: [String]?

  public init(requested: Int64, worktree: Bool, branch: Bool, remoteBranch: Bool, resolve: [String]) {
    self.state = .queued
    self.requested = requested
    self.worktree = worktree
    self.branch = branch
    self.remoteBranch = remoteBranch
    self.resolve = resolve
  }

  /// True while the job holds the session: queued or running.
  public var holdsSession: Bool { state != .failed }
}

/// A branch or remote branch that a removal kept after it forgot the session,
/// so no session is left to show the error.
public struct RemovalNotice: Codable, Equatable, Sendable {
  public var id: Int64
  public var session: String
  public var name: String
  public var message: String

  public init(id: Int64, session: String, name: String, message: String) {
    self.id = id
    self.session = session
    self.name = name
    self.message = message
  }
}

/// What `rm-queue` returns: the sessions it queued, and those it skipped with the reason.
public struct RemovalQueued: Codable, Equatable, Sendable {
  public var queued: [String]
  public var skipped: [RemovalPlan.Skip]

  public init(queued: [String], skipped: [RemovalPlan.Skip]) {
    self.queued = queued
    self.skipped = skipped
  }
}
