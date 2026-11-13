import Foundation
import SwitchboardCore

/// sbd's removal job. `rm-queue` records a queued `Removal` on each session
/// and starts the job, which runs `rm`'s phases on one session at a time on
/// `removalQueue`, off the state queue.
extension Service {
  /// The refusal for a request that would start or reach a session that the
  /// removal job holds, or nil. It runs on the state queue.
  func removalRefusal(_ id: String) -> APIError? {
    entries[id]?.session.removal?.holdsSession == true ? APIError("\(id) is being deleted") : nil
  }

  /// The ids in `resolving` that a removal phase passes to `checkTodos`. The
  /// job runs a session's removal while the session's removal is running,
  /// and `rm` refuses such a session. For the job, it drops the ids whose
  /// to-dos are no longer open, so a to-do that the user resolved by hand
  /// does not fail the removal. For `rm`, it returns `resolving`, and
  /// `checkTodos` refuses an id that names no open to-do. It runs on the
  /// state queue.
  func removalResolving(_ id: String, _ resolving: Set<String>) -> Set<String> {
    guard let session = entries[id]?.session, session.removal?.state == .running else { return resolving }
    return resolving.intersection(session.openTodos.map(\.id))
  }

  /// `rm-retry` queues a failed removal again, and refuses a session that is
  /// starting, merging, or that `rm` or `cleanup` is removing. `rm-keep`
  /// moves the worktree's folder back from the trash, then clears the
  /// removal, and the session goes back to the state its events give it. A
  /// folder that can't move back keeps the removal.
  /// Both refuse a session with no failed removal. `removal-notices` lists the notices,
  /// oldest first. `removal-notice-dismiss` deletes the notice `id`.
  func removalRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "rm-retry", "rm-keep":
      let id = try lookup(args)
      if let refusal = removalRefusal(id) { throw refusal }
      guard entries[id]?.session.removal != nil else { throw APIError("\(id) has no failed removal") }
      if op == "rm-retry" {
        guard !removing.contains(id) else { throw APIError("\(id) is being deleted") }
        guard !starting.contains(id) else { throw APIError("\(id) is starting") }
        guard !merging.contains(id) else { throw APIError("\(id) is merging its PR") }
      }
      if op == "rm-keep" {
        try restoreFromTrash(id)
        try update(id) { $0.removal = nil }
      } else {
        try update(id) {
          $0.removal?.state = .queued
          $0.removal?.error = nil
        }
        removalOrder.append(id)
        runRemovals()
      }
      return try JSON(encoding: summary(id))
    case "removal-notices":
      return try JSON(encoding: store.removalNotices())
    default:
      guard let id = args["id"]?.int else { throw APIError("removal-notice-dismiss needs the notice's id") }
      try store.deleteRemovalNotice(id: Int64(id))
      return [:]
    }
  }

  /// Rebuilds the job's order from the stored removals after a restart, the
  /// running removal first, and starts the job. A running removal starts
  /// over from `rm`'s checks, or continues from the trash as `runRemoval`
  /// says. A failed removal waits for `rm-retry`. It runs on the state queue.
  func resumeRemovals() {
    let held = entries.values.compactMap { e in e.session.removal.map { (id: e.session.id, removal: $0) } }
      .filter(\.removal.holdsSession)
    removalOrder = held.sorted {
      ($0.removal.state == .running ? 0 : 1, $0.removal.requested, $0.id)
        < ($1.removal.state == .running ? 0 : 1, $1.removal.requested, $1.id)
    }.map(\.id)
    if !removalOrder.isEmpty { runRemovals() }
  }

  /// Runs the queued removals on `removalQueue`, one at a time, in the order
  /// that `removalOrder` gives, until none is left. A call while the job
  /// runs adds a pass that finds nothing to do.
  func runRemovals() {
    removalQueue.async { [self] in
      while let next = queue.sync(execute: { takeNextRemoval() }) {
        waitAtGate("hold-removal")
        runRemoval(next.id, next.removal)
      }
    }
  }

  /// Takes the next session in `removalOrder` whose removal is still queued
  /// or running, and records it as running. It runs on the state queue.
  private func takeNextRemoval() -> (id: String, removal: Removal)? {
    while !removalOrder.isEmpty {
      let id = removalOrder.removeFirst()
      guard var removal = entries[id]?.session.removal, removal.holdsSession else { continue }
      // `rm-queue` and `rm-retry` refuse a session that `rm` or `cleanup` is removing. This check covers any other path.
      if removing.contains(id) {
        failRemoval(id, APIError("\(id) is being deleted"))
        continue
      }
      removal.state = .running
      do {
        try update(id) { $0.removal = removal }
      } catch {
        logLine("can't record that the removal of \(id) runs: \(error)")
      }
      return (id, removal)
    }
    return nil
  }

  /// Runs `rm`'s phases on the session with the removal's arguments. The
  /// worktree goes through the trash as `releaseThroughTrash` says, and the
  /// trash folder is purged once the session is forgotten. A removal whose
  /// folder an earlier run moved to the trash continues from there, as
  /// `folderInTrash` says. It resolves the to-dos in the removal's `resolve`
  /// that are still open, and a to-do that is open and not in `resolve`
  /// fails the removal. A failure before the session is forgotten records
  /// the removal as failed with `rm`'s message, and the session stays. A
  /// branch or remote branch that stayed after the session was forgotten
  /// becomes a removal notice. It runs on `removalQueue`.
  private func runRemoval(_ id: String, _ removal: Removal) {
    let resolving = Set(removal.resolve ?? [])
    do {
      let inTrash = try folderInTrash(id, removal)
      let check = try checkBeforeRemoval(
        id, worktree: removal.worktree, branch: removal.branch, remoteBranch: removal.remoteBranch,
        resolving: resolving)
      let session = check.session
      let (repo, branch, supacode) = try stopForRemoval(
        session, pr: check.pr, sharedWith: check.sharedWith, folderGone: check.folderGone,
        worktree: removal.worktree, branch: removal.branch, resolving: resolving, ancestry: nil,
        command: "sb rm --worktree", again: "retry the delete")
      let trash = try releaseThroughTrash(
        session, removal, inTrash: inTrash, repo: repo, supacode: supacode, check: check)
      let released =
        trash == nil
        ? try releaseFiles(
          session, repo: repo, branch: branch, supacode: supacode, pr: check.pr, folderGone: check.folderGone,
          remoteBranch: check.remoteTarget)
        : releaseBranches(
          session, repo: repo, branch: branch, supacode: supacode, pr: check.pr, remoteBranch: check.remoteTarget)
      try forgetRemoved(session, released, resolving: resolving)
      if let trash { purge(trash) }
      if let kept = released.keptMessage(id, remoteBranch: removal.remoteBranch) {
        logLine(kept)
        queue.sync {
          do {
            try store.addRemovalNotice(session: id, name: session.name, message: kept)
          } catch {
            logLine("can't record the removal notice for \(id): \(error)")
          }
        }
      }
    } catch {
      queue.sync { failRemoval(id, error) }
    }
  }

  /// Records the removal as failed, and pastes the messages that waited
  /// while the job held the session. It runs on the state queue.
  private func failRemoval(_ id: String, _ error: any Error) {
    guard entries[id]?.session.removal != nil else {
      logLine("the removal of \(id) failed after the session went: \(error)")
      return
    }
    do {
      try update(id) {
        $0.removal?.state = .failed
        $0.removal?.error = "\(error)"
      }
    } catch {
      logLine("can't record that the removal of \(id) failed: \(error)")
    }
    deliverPending(id, after: 0)
  }
}
