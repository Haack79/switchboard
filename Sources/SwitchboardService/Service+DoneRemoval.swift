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
  /// inside it, as `rm` refuses it.
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
    let targets: [String]?
    switch args["targets"] {
    case nil, .null?:
      targets = nil
    case .array(let list)? where list.allSatisfy({ $0.string != nil }):
      targets = list.compactMap(\.string)
    default:
      throw APIError("rm-plan needs targets as a list of session ids")
    }
    guard targets != nil || scope == .done else { throw APIError("rm-plan with scope work needs targets") }
    return try JSON(encoding: planRemoval(targets, scope: scope, RemovalOptions(args, caller: caller)))
  }

  /// Sorts the sessions into those that `rm` would remove and those it
  /// refuses, by running `rm`'s checks. Nil `targets` takes every session
  /// that `scope` admits. A repeated target is planned once. The checks only
  /// read git, so they run concurrently.
  private func planRemoval(_ targets: [String]?, scope: RemovalScope, _ options: RemovalOptions) -> RemovalPlan {
    var seen = Set<String>()
    let ids =
      targets?.filter { seen.insert($0).inserted }
      ?? queue.sync { summaries().filter { scope.admits($0) }.map(\.id) }
    let outcomes: [Result<RemovalPlan.Item, Skipped>] = concurrentMap(ids) { id in
      switch removalTarget(id, scope: scope, options) {
      case .failure(let skipped):
        return .failure(skipped)
      case .success(let t):
        do {
          let checked = try checkRemoval(
            t.session, pr: t.pr, sharedWith: t.sharedWith,
            folderGone: !machine(for: t.session).exists(t.session.cwd), worktree: t.worktree,
            branch: t.branch)
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

  /// The `rm-done` and `rm-plan` arguments that apply to every target, and
  /// the caller's process ancestry when the worktree goes.
  private struct RemovalOptions {
    var worktree: Bool
    var remoteBranch: Bool
    var ancestry: Set<Int>?

    init(_ args: JSON, caller: Caller) throws {
      worktree = args["worktree"]?.bool == true
      remoteBranch = args["remote_branch"]?.bool == true
      ancestry = worktree ? try caller.ancestry(command: "sb rm --worktree") : nil
    }
  }

  private struct RemovalTarget {
    var session: Session
    var pr: PullRequest?
    var sharedWith: String?
    var worktree: Bool
    var branch: Bool
    var remoteBranch: Bool
  }

  private struct Skipped: Error {
    var skip: RemovalPlan.Skip
  }

  /// The arguments of the Done delete icon's `rm` for the session, without
  /// running git. A session that is gone, that `scope` doesn't admit, or
  /// that has an open to-do fails with the reason, and so does a session
  /// whose worktree would go while the caller runs inside it.
  private func removalTarget(_ id: String, scope: RemovalScope, _ options: RemovalOptions) -> Result<
    RemovalTarget, Skipped
  > {
    queue.sync {
      guard let e = entries[id] else {
        return .failure(Skipped(skip: .init(id: id, name: id, reason: "\(id) no longer exists")))
      }
      let s = e.session
      guard scope.admits(summary(id)) else {
        let reason =
          switch scope {
          case .done: "\(s.name) is no longer in Done"
          case .work:
            s.kind.label.map { "\(s.name) is \($0)" }
              ?? (s.waitsToStart ? "\(s.name) is a follow-up that hasn't started" : "\(s.name) isn't a work session")
          }
        return .failure(Skipped(skip: .init(id: id, name: s.name, reason: reason)))
      }
      do {
        try checkTodos(id, resolving: [])
      } catch {
        let reason = (error as? OpenTodoError).map { "\(s.name) has an open to-do: \($0.list)" } ?? "\(error)"
        return .failure(Skipped(skip: .init(id: id, name: s.name, reason: reason)))
      }
      let removesWorktree = options.worktree && s.repo != nil
      if removesWorktree, let refusal = insideRefusal(id, options.ancestry, command: "sb rm --worktree") {
        return .failure(Skipped(skip: .init(id: id, name: s.name, reason: "\(refusal)")))
      }
      let removesBranch = removesWorktree && s.branch != nil && e.facts.pr?.state == .merged
      return .success(
        RemovalTarget(
          session: s, pr: e.facts.pr, sharedWith: sharedSession(s), worktree: removesWorktree,
          branch: removesBranch, remoteBranch: removesBranch && options.remoteBranch))
    }
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
