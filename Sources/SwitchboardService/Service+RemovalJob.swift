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

  /// The refusal for a request that would change a session whose files `rm` or `cleanup` is removing, or nil.
  /// It runs on the state queue.
  func removingRefusal(_ id: String) -> APIError? {
    removing.contains(id) ? APIError("\(id) is being deleted") : nil
  }

  /// The refusal for a request that would start or change a session that the removal job holds or that `rm` or
  /// `cleanup` is removing, or nil. It runs on the state queue.
  func beingDeletedRefusal(_ id: String) -> APIError? { removalRefusal(id) ?? removingRefusal(id) }

  /// The refusal for a removal of a session that `followup start` is starting or `merge` is merging, or nil. It
  /// runs on the state queue.
  func busyRefusal(_ id: String) -> APIError? {
    if starting.contains(id) { return APIError("\(mention(id)) is starting") }
    if merging.contains(id) { return APIError("\(mention(id)) is merging its PR") }
    return nil
  }

  /// Who runs `rm`'s phases on a session: a synchronous `rm`, or the removal job.
  enum RemovalRunner {
    case rm
    case job

    /// The clause, in lower case, that tells the user how to try the removal again.
    var again: String {
      switch self {
      case .rm: "run `\(Service.removalCommand)` again"
      case .job: "retry the delete"
      }
    }
  }

  /// The ids in `resolving` that a removal phase passes to `checkTodos`. For
  /// the job, it drops the ids whose to-dos are no longer open, so a to-do
  /// that the user resolved by hand does not fail the removal. For `rm`, it
  /// returns `resolving`, and `checkTodos` refuses an id that names no open
  /// to-do. It runs on the state queue.
  func removalResolving(_ id: String, _ resolving: Set<String>, for runner: RemovalRunner) -> Set<String> {
    guard runner == .job, let session = entries[id]?.session else { return resolving }
    return resolving.intersection(session.openTodos.map(\.id))
  }

  /// Runs `change` on each session in `ids` in one store transaction. `update` changes the entry before it saves,
  /// so when the store refuses, this puts each entry's session back as it was and throws. It runs on the state
  /// queue.
  func updateOrRestore(_ ids: [String], _ change: (String, inout Session) -> Void) throws {
    guard !ids.isEmpty else { return }
    let before = ids.map { entries[$0]?.session }
    do {
      try store.transaction {
        for id in ids { try update(id) { change(id, &$0) } }
      }
    } catch {
      for case (let id, let session?) in zip(ids, before) { entries[id]?.session = session }
      throw error
    }
  }

  /// How long after `rm-queue` the job starts a session, from `removalDelaySeconds`.
  var removalDelayMs: Int64 { Int64(config.removalDelaySeconds) * 1000 }

  /// `rm-retry` queues a failed removal again with no delay, and refuses a session that is
  /// starting, merging, or that `rm` or `cleanup` is removing. `rm-keep`
  /// moves the worktree's folder back from the trash, then clears the
  /// removal, and the session goes back to the state its events give it. A
  /// folder that can't move back keeps the removal, and so does one whose
  /// worktree record git already dropped.
  /// Both refuse a session with no failed removal. `removal-notices` lists the notices,
  /// oldest first. `removal-notice-dismiss` deletes the notice `id`.
  func removalRequest(_ op: String, _ args: JSON) throws -> JSON {
    switch op {
    case "rm-retry":
      let id = try failedRemoval(args)
      if let refusal = removingRefusal(id) ?? busyRefusal(id) { throw refusal }
      try update(id) {
        $0.removal?.state = .queued
        $0.removal?.notBefore = nowMs()
        $0.removal?.error = nil
      }
      removalOrder.append(id)
      runRemovals()
      return try JSON(encoding: summary(id))
    case "rm-keep":
      let id = try failedRemoval(args)
      try restoreFromTrash(id)
      try clearRemoval(id)
      return try JSON(encoding: summary(id))
    case "rm-cancel":
      return try JSON(encoding: cancelRemovals(args))
    case "removal-notices":
      return try JSON(encoding: store.removalNotices())
    case "removal-notice-dismiss":
      guard let id = args["id"]?.int else { throw APIError("removal-notice-dismiss needs the notice's id") }
      try store.deleteRemovalNotice(id: Int64(id))
      return [:]
    default:
      throw APIError("unknown request \(op)")
    }
  }

  /// Clears the session's removal, so its state comes from its events again. When the store can't save the change,
  /// the removal stays and this throws. It runs on the state queue.
  private func clearRemoval(_ id: String) throws {
    let removal = entries[id]?.session.removal
    do {
      try update(id) { $0.removal = nil }
    } catch {
      // `fold` can run inside `store.transaction`, so this can't use `updateOrRestore`.
      entries[id]?.session.removal = removal
      throw error
    }
  }

  /// Clears a failed removal after a main-session prompt, a launch, a resume, `undone`, or `unpaused`. It clears
  /// the removal only when the session runs on this Mac, a folder is at `cwd`, nothing is at the trash path, the
  /// removal has not recorded `released`, and `rm` or `cleanup` is not removing the session's files. `released` and
  /// the folder at `cwd` stand in for git still listing the worktree. Otherwise it keeps the removal and logs why. It never moves a folder, because moving one back from the
  /// trash is Keep's job. `fold` calls it for each new event, and replay at startup does not. It runs on the state
  /// queue.
  func dropStaleFailedRemoval(_ id: String, event: Event) {
    let comesBack =
      switch event.kind {
      case "UserPromptSubmit": !event.fromSubagent
      case "started", "resumed", "undone", "unpaused": true
      default: false
      }
    guard comesBack, let session = entries[id]?.session, let removal = session.removal, removal.state == .failed
    else { return }
    let kept: String? =
      if removing.contains(id) {
        "`rm` or `cleanup` is removing its files"
      } else if let host = session.host {
        "it runs on \(host), where sbd can't check its folder"
      } else if let trash = trashedFolder(id) {
        "its folder is in the trash at \(trash)"
      } else if removal.released {
        "git no longer lists \(session.cwd) as a worktree"
      } else if !folderExists(session.cwd) {
        "\(session.cwd) is not a folder"
      } else {
        nil
      }
    if let kept {
      logLine("kept the failed removal of \(id) after \(event.kind): \(kept)")
      return
    }
    do {
      try clearRemoval(id)
    } catch {
      logLine("can't clear the failed removal of \(id) after \(event.kind): \(error)")
    }
  }

  /// The session that `args` names, or throws unless it has a failed removal. It runs on the state queue.
  private func failedRemoval(_ args: JSON) throws -> String {
    let id = try lookup(args)
    if let refusal = removalRefusal(id) { throw refusal }
    guard entries[id]?.session.removal != nil else { throw APIError("\(id) has no failed removal") }
    return id
  }

  /// Clears the queued removal of each session in `sessions`. The job stopped nothing yet, so the session is as
  /// it was before `rm-queue`. It clears a queued removal whose `notBefore` passed too. It refuses each id that
  /// names no session, no removal, a running or failed removal, or a queued removal whose folder is in the trash.
  /// A refusal does not stop the other ids. It runs on the state queue.
  private func cancelRemovals(_ args: JSON) throws -> RemovalCancelled {
    var result = RemovalCancelled(cancelled: [], refused: [])
    for id in try idList(args, key: "sessions", op: "rm-cancel") {
      guard let session = entries[id]?.session else {
        result.refused.append(.init(id: id, name: id, reason: "no session \(id)"))
        continue
      }
      let refusal: String? =
        switch session.removal?.state {
        case nil: "\(id) is not being deleted"
        case .running: "\(id) is already being deleted"
        case .failed: "the delete of \(id) failed, and Keep brings it back"
        // A retried removal can be queued with its folder still in the trash, and clearing it would leave the
        // folder for the purge.
        case .queued: trashedFolder(id).map { "\(id) is already being deleted: its folder is in the trash at \($0)" }
        }
      if let refusal {
        result.refused.append(.init(id: id, name: session.name, reason: refusal))
        continue
      }
      do {
        try updateOrRestore([id]) { _, s in s.removal = nil }
      } catch {
        result.refused.append(.init(id: id, name: session.name, reason: "\(error)"))
        continue
      }
      removalOrder.removeAll { $0 == id }
      deliverPending(id, after: 0)
      result.cancelled.append(id)
    }
    if !result.cancelled.isEmpty { runRemovals() }
    return result
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
  /// that `removalOrder` gives, until none is due. A call while the job
  /// runs adds a pass that finds nothing to do. Every change to the queue
  /// calls it, and so does `removalWake`, so each pass sees the current
  /// queue and clock.
  func runRemovals() {
    removalQueue.async { [self] in
      while let next = queue.sync(execute: { takeNextRemoval() }) {
        waitAtGate("hold-removal")
        runRemoval(next.id, next.removal)
      }
    }
  }

  /// Takes the first session in `removalOrder` whose removal is running, or
  /// queued with its `notBefore` passed, and records it as running. It drops
  /// the sessions that the job no longer holds. When the rest all wait for
  /// their `notBefore`, it sets `removalWake` for the earliest one and
  /// returns nil. It runs on the state queue.
  private func takeNextRemoval() -> (id: String, removal: Removal)? {
    removalWake?.cancel()
    removalWake = nil
    let now = nowMs()
    while true {
      removalOrder.removeAll { entries[$0]?.session.removal?.holdsSession != true }
      guard let index = removalOrder.firstIndex(where: { entries[$0]?.session.removal?.startsAfter(now) == false })
      else {
        wakeRemovals(now: now)
        return nil
      }
      let id = removalOrder.remove(at: index)
      guard var removal = entries[id]?.session.removal else { continue }
      // `rm-queue` and `rm-retry` refuse a session that `rm` or `cleanup` is removing. This check covers any other path.
      if let refusal = removingRefusal(id) {
        failRemoval(id, refusal)
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
  }

  /// Sets `removalWake` to start a pass at the earliest `notBefore` in `removalOrder`. The timer counts wall time,
  /// so it keeps counting while the Mac sleeps. A `clock` advance in a test starts its own pass. It runs on the
  /// state queue.
  private func wakeRemovals(now: Int64) {
    guard let earliest = removalOrder.compactMap({ entries[$0]?.session.removal?.notBefore }).min() else { return }
    let wake = DispatchWorkItem { [self] in runRemovals() }
    removalWake = wake
    queue.asyncAfter(wallDeadline: .now() + .milliseconds(Int(clamping: max(earliest - now, 0))), execute: wake)
  }

  /// Runs `rm`'s phases on the session with the removal's arguments, at the
  /// session's site, as `removeAtSite` says. On this Mac, the worktree goes
  /// through the trash as `releaseThroughTrash` says, and the trash folder is
  /// purged once the session is forgotten. A removal whose folder an earlier
  /// run moved to the trash continues from there, as `folderInTrash` says.
  /// It resolves the to-dos in the removal's `resolve` that are still open,
  /// and a to-do that is open and not in `resolve` fails the removal. A
  /// failure before the session is forgotten records the removal as failed
  /// with `rm`'s message, and the session stays. A branch or remote branch
  /// that stayed becomes a removal notice, stored as the session is forgotten.
  /// It runs on `removalQueue`.
  private func runRemoval(_ id: String, _ removal: Removal) {
    do {
      let inTrash = try folderInTrash(id, removal)
      var trash: String?
      _ = try removeAtSite(
        id, worktree: removal.worktree, branch: removal.branch, remoteBranch: removal.remoteBranch,
        resolving: Set(removal.resolve), ancestry: nil, by: .job
      ) { check, checked, site in
        trash = try releaseThroughTrash(check, checked, removal, inTrash: inTrash)
        if trash == nil, let repo = checked.repo {
          try releaseWorktree(check.session, repo: repo, folderGone: check.folderGone, at: site)
        }
        return releaseBranches(
          check.session, repo: checked.repo, branch: checked.branch, supacode: checked.supacode, pr: checked.pr,
          remoteBranch: check.remoteTarget, at: site)
      }
      if let trash { purge(trash) }
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
