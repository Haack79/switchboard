import Foundation
import SwitchboardCore

extension Service {
  /// `rm-done` removes every Done session through `rm`, with the arguments
  /// that the Done delete icon sends: the worktree when `worktree` is set and
  /// sbd made it, the branch only when the session's PR merged, and the
  /// remote branch only with the branch and `remote_branch`. Without
  /// `confirmed`, it returns the `RemovalPlan` that `rm-plan` returns for
  /// `scope: done` and no targets. With `confirmed`, it removes each of
  /// `targets` that is still a removable Done session and returns a
  /// `RemovalResult`. A target that fails is skipped with `rm`'s message, and
  /// the rest continue. git runs off the state queue, as it does for `rm`.
  /// Both steps skip a session whose worktree would go when the caller runs
  /// inside it, as `rm` refuses it. An `sb` built before `rm-plan` and
  /// `rm-queue` sends it.
  func removeDone(_ args: JSON, caller: Caller) throws -> JSON {
    let options = try RemovalOptions(args, caller: caller)
    guard args["confirmed"]?.bool == true else {
      return try JSON(encoding: planRemoval(nil, scope: .done, options))
    }
    guard let targets = args["targets"]?.array?.compactMap(\.string) else {
      throw APIError("rm-done needs targets with confirmed")
    }
    var result = RemovalResult(removed: [], skipped: [], partial: [])
    for id in targets {
      let target: RemovalTarget
      switch removalTarget(id, scope: .done, options) {
      case .failure(let skip):
        result.skipped.append(skip.skip)
        continue
      case .success(let found):
        target = found
      }
      do {
        _ = try remove(
          [
            "session": .string(id), "worktree": .bool(target.worktree), "branch": .bool(target.branch),
            "remote_branch": .bool(target.remoteBranch),
          ], caller: caller)
        result.removed.append(id)
      } catch {
        let skip = RemovalPlan.Skip(id: id, name: target.session.name, reason: "\(error)")
        // `rm` throws after it forgets the session when only the branch or the remote branch stays.
        if queue.sync(execute: { entries[id] == nil }) {
          result.removed.append(id)
          result.partial.append(skip)
        } else {
          result.skipped.append(skip)
        }
      }
    }
    return try JSON(encoding: result)
  }

  /// `rm-plan` runs `rm`'s checks on each of `targets` and returns a
  /// `RemovalPlan`, with the arguments that `rm-done` uses. `scope` is `done`
  /// or `work` and decides which sessions the plan may take. Without
  /// `targets`, `scope: done` plans every removable Done session, as
  /// `rm-done` does, and `scope: work` is refused. The plan removes nothing.
  func removalPlan(_ args: JSON, caller: Caller) throws -> JSON {
    guard let scope = args["scope"]?.string.flatMap(RemovalScope.init(rawValue:)) else {
      throw APIError("rm-plan needs scope done or work")
    }
    let targets = (args["targets"] ?? .null) == .null ? nil : try idList(args, key: "targets", op: "rm-plan")
    guard targets != nil || scope == .done else { throw APIError("rm-plan with scope work needs targets") }
    return try JSON(encoding: planRemoval(targets, scope: scope, RemovalOptions(args, caller: caller)))
  }

  /// `rm-queue` hands `targets` to the removal job and returns at once with a
  /// `RemovalQueued`. It runs `rm-plan`'s checks that read no git: `scope`,
  /// the session's open to-dos, and a caller inside a session whose worktree
  /// would go. It skips a session that is starting or merging, whose files
  /// `rm` or `cleanup` is removing, or that already has a removal. It records
  /// every queued removal in one store transaction, and a store that refuses
  /// it skips every target. `resolve` lists the open to-dos that the user
  /// confirmed. Each session takes the ids that name its own open to-dos,
  /// and a session with an open to-do that `resolve` doesn't list is skipped.
  /// The job runs git's checks when it takes the session.
  func queueRemovals(_ args: JSON, caller: Caller) throws -> JSON {
    guard let scope = args["scope"]?.string.flatMap(RemovalScope.init(rawValue:)) else {
      throw APIError("rm-queue needs scope done or work")
    }
    let targets = try idList(args, key: "targets", op: "rm-queue")
    var options = try RemovalOptions(args, caller: caller)
    options.resolve = try resolveArgument(args)
    let result: RemovalQueued = queue.sync {
      var result = RemovalQueued(queued: [], skipped: [])
      let now = nowMs()
      var removals: [String: Removal] = [:]
      var accepted: [String] = []
      for id in targets {
        switch checkedRemovalTarget(id, scope: scope, options) {
        case .failure(let skipped):
          result.skipped.append(skipped.skip)
        case .success(let t):
          accepted.append(id)
          removals[id] = Removal(
            requested: now, notBefore: now + removalDelayMs, worktree: t.worktree, branch: t.branch,
            remoteBranch: t.remoteBranch, resolve: t.resolve)
        }
      }
      do {
        try updateOrRestore(accepted) { id, s in s.removal = removals[id] }
      } catch {
        result.skipped += accepted.map { .init(id: $0, name: entries[$0]?.session.name ?? $0, reason: "\(error)") }
        return result
      }
      result.queued = accepted
      removalOrder += result.queued
      return result
    }
    if !result.queued.isEmpty { runRemovals() }
    return try JSON(encoding: result)
  }

  /// Sorts the sessions into those that `rm` would remove and those it
  /// refuses, by running `rm`'s checks. Nil `targets` takes every session
  /// that `scope` admits. The checks only read git, so they run concurrently.
  private func planRemoval(_ targets: [String]?, scope: RemovalScope, _ options: RemovalOptions) -> RemovalPlan {
    let ids = targets ?? queue.sync { summaries().filter { scope.admits($0) }.map(\.id) }
    let outcomes: [Result<RemovalPlan.Item, Skipped>] = concurrentMap(ids) { id in
      switch removalTarget(id, scope: scope, options) {
      case .failure(let skipped):
        return .failure(skipped)
      case .success(let t):
        do {
          // `checkRemoval` checks nothing for a removal that keeps the worktree.
          let checked: ReleaseTargets =
            t.worktree ? try removalCheck(t) : (repo: nil, branch: nil, supacode: false, pr: t.pr)
          return .success(
            .init(
              id: id, name: t.session.name, pr: t.pr?.number, worktree: t.worktree ? t.session.cwd : nil,
              branch: checked.branch?.name, remoteBranch: t.remoteBranch && (checked.branch != nil || !checked.supacode)
            ))
        } catch {
          return .failure(Skipped(skip: .init(id: id, name: t.session.name, reason: "\(error)")))
        }
      }
    }
    var plan = RemovalPlan(remove: [], skip: [])
    for outcome in outcomes {
      switch outcome {
      case .success(let item): plan.remove.append(item)
      case .failure(let skipped): plan.skip.append(skipped.skip)
      }
    }
    return plan
  }

  /// `rm`'s checks of the target's worktree, run at the session's site on one connection after sbd waited for a
  /// host.
  private func removalCheck(_ t: RemovalTarget) throws -> ReleaseTargets {
    let sharedWith = queue.sync { sharedSession(t.session) }
    let site = self.site(for: t.session)
    try awaitSite(site)
    return try site.scoped("the removal check of \(t.session.id)") { scope in
      try checkRemoval(
        t.session, pr: t.pr, sharedWith: sharedWith, folderGone: try folderIsGone(t.session.cwd, at: scope.site),
        worktree: t.worktree, branch: t.branch, at: scope.site)
    }
  }

  /// The `rm-done` and `rm-plan` arguments that apply to every target, and
  /// the caller's process ancestry when the worktree goes.
  private struct RemovalOptions {
    var worktree: Bool
    var remoteBranch: Bool
    var ancestry: Set<Int>?
    /// The open to-dos that the removal resolves, across every target.
    var resolve: Set<String> = []

    init(_ args: JSON, caller: Caller) throws {
      worktree = args["worktree"]?.bool == true
      remoteBranch = args["remote_branch"]?.bool == true
      ancestry = worktree ? try caller.ancestry(command: Service.removalCommand) : nil
    }
  }

  private struct RemovalTarget {
    var session: Session
    var pr: PullRequest?
    var worktree: Bool
    var branch: Bool
    var remoteBranch: Bool
    /// The ids in `RemovalOptions.resolve` that name the session's open to-dos.
    var resolve: [String]
  }

  private struct Skipped: Error {
    var skip: RemovalPlan.Skip
  }

  private func removalTarget(_ id: String, scope: RemovalScope, _ options: RemovalOptions) -> Result<
    RemovalTarget, Skipped
  > {
    queue.sync { checkedRemovalTarget(id, scope: scope, options) }
  }

  /// The arguments of the Done delete icon's `rm` for the session, without
  /// running git. A session that is gone, that already has a removal, that
  /// is starting or merging, whose files `rm` or `cleanup` is removing, that
  /// `scope` doesn't admit, or that has an open
  /// to-do that `options.resolve` doesn't list fails with the reason, and so
  /// does a session whose worktree would go while the caller runs inside it.
  /// It runs on the state queue.
  private func checkedRemovalTarget(_ id: String, scope: RemovalScope, _ options: RemovalOptions) -> Result<
    RemovalTarget, Skipped
  > {
    func skip(_ name: String, _ reason: String) -> Result<RemovalTarget, Skipped> {
      .failure(Skipped(skip: .init(id: id, name: name, reason: reason)))
    }
    guard let e = entries[id] else { return skip(removedNames[id] ?? id, "\(mention(id)) no longer exists") }
    let s = e.session
    if let removal = s.removal {
      return skip(
        s.name, removal.holdsSession ? "\(s.name) is being deleted" : "\(s.name) failed to delete. Retry it or keep it")
    }
    if let refusal = busyRefusal(id) ?? removingRefusal(id) { return skip(s.name, "\(refusal)") }
    guard scope.admits(summary(id)) else {
      let reason =
        switch scope {
        case .done: "\(s.name) is no longer in Done"
        case .work:
          s.kind.label.map { "\(s.name) is \($0)" }
            ?? (s.waitsToStart ? "\(s.name) is a follow-up that hasn't started" : "\(s.name) isn't a work session")
        }
      return skip(s.name, reason)
    }
    let resolve = options.resolve.intersection(s.openTodos.map(\.id))
    do {
      try checkTodos(id, resolving: resolve)
    } catch {
      return skip(s.name, (error as? OpenTodoError).map { "\(s.name) has an open to-do: \($0.list)" } ?? "\(error)")
    }
    let removesWorktree = options.worktree && s.repo != nil
    if removesWorktree, let refusal = insideRefusal(id, options.ancestry, command: Self.removalCommand) {
      return skip(s.name, "\(refusal)")
    }
    let removesBranch = removesWorktree && s.branch != nil && e.facts.pr?.state == .merged
    return .success(
      RemovalTarget(
        session: s, pr: e.facts.pr, worktree: removesWorktree,
        branch: removesBranch, remoteBranch: removesBranch && options.remoteBranch, resolve: resolve.sorted()))
  }
}

extension Service {
  /// The session ids in `args[key]`, each once, in the order given. It throws, naming `op`, unless the value is
  /// a list of strings.
  func idList(_ args: JSON, key: String, op: String) throws -> [String] {
    guard let ids = args[key]?.strings else { throw APIError("\(op) needs \(key) as a list of session ids") }
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }
}

extension RemovalScope {
  fileprivate func admits(_ s: SessionSummary) -> Bool {
    switch self {
    case .done: s.isRemovableDone
    case .work: s.isRemovableWork
    }
  }
}
