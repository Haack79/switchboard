import Foundation
import SwitchboardCore

/// Lists what `sb rm --done` removes and skips, asks the user to confirm,
/// then hands the sessions to sbd's removal job and waits for it. Without a
/// terminal or inside Claude, it needs --yes. With --json and without --yes,
/// it prints the plan and removes nothing. With --no-wait, it prints what the
/// job queued and returns.
func removeDone(_ a: Args) {
  if let session = a.positional.first {
    die("rm --done removes every Done session, so it takes no session. Run sb rm \(session) to remove one.")
  }
  if a.switches.contains("--delete-branch") {
    die("rm --done deletes a branch only when its PR merged it. Pass --worktree for that.")
  }
  if a.switches.contains("--delete-remote-branch") && !a.switches.contains("--worktree") {
    die("--delete-remote-branch needs --worktree")
  }
  let args: [String: JSON] = [
    "scope": "done",
    "worktree": .bool(a.switches.contains("--worktree")),
    "remote_branch": .bool(a.switches.contains("--delete-remote-branch")),
  ]
  let preview = call("rm-plan", args, timeout: 300)
  let yes = a.switches.contains("--yes")
  if a.json && !yes { return printJSON(preview) }
  let plan = decode(preview, as: RemovalPlan.self)
  let noWait = a.switches.contains("--no-wait")
  let text = describe(plan)
  if plan.remove.isEmpty {
    if noWait { return printQueued(RemovalQueued(queued: [], skipped: plan.skip), names: [:], json: a.json) }
    if a.json { return printJSON(encoded(RemovalResult(removed: [], skipped: plan.skip, partial: []))) }
    print(text)
    return
  }
  if !yes {
    let count = plan.remove.count == 1 ? "this session" : "these \(plan.remove.count) sessions"
    guard author != .claude else { die("pass --yes to remove \(count):\n\(text)") }
    confirm(verb: "remove", count, text, refused: "removed nothing")
  }
  let names = Dictionary(plan.remove.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  var queueArgs = args
  queueArgs["targets"] = .array(plan.remove.map { .string($0.id) })
  var queued = decode(call("rm-queue", queueArgs), as: RemovalQueued.self)
  queued.skipped = plan.skip + queued.skipped
  if noWait { return printQueued(queued, names: names, json: a.json) }

  let ended = waitForRemovals(queued.queued)
  let gone = Set(ended.gone)
  var result = RemovalResult(removed: ended.gone, skipped: queued.skipped, partial: [])
  for s in ended.stayed {
    let reason = s.failed ? keep(s.id, failedWith: s.reason) : s.reason
    result.skipped.append(.init(id: s.id, name: names[s.id] ?? s.id, reason: reason))
  }
  // sbd stores a notice in the step that forgets its session, so a notice for a gone id comes from this run.
  let notices = removalNotices().filter { gone.contains($0.session) }
  result.partial = notices.map { .init(id: $0.session, name: $0.name, reason: $0.message) }
  printResult(result, json: a.json)
  for notice in notices { dismiss(notice) }
}

/// Polls sbd until each of `ids` is gone or no longer waits in the removal
/// job, and returns the gone ids and each other id with the reason it stayed,
/// both in the order of `ids`. `failed` is true for a removal that failed
/// and that Keep can bring back, and false otherwise.
private func waitForRemovals(_ ids: [String]) -> (gone: [String], stayed: [Stayed]) {
  var retry = UnreachableRetry()
  while true {
    let sessions: [SessionSummary]
    do {
      // launchd may be restarting sbd, and the job resumes after the restart.
      guard let answer = try retry.attempt(client.sessions) else {
        Thread.sleep(forTimeInterval: 1)
        continue
      }
      sessions = answer
    } catch {
      die("\(error)")
    }
    let listed = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var gone: [String] = []
    var stayed: [Stayed] = []
    var waiting = false
    for id in ids {
      guard let session = listed[id] else {
        gone.append(id)
        continue
      }
      switch session.removal {
      case let removal? where removal.holdsSession:
        waiting = true
      case let removal?:
        let reason = removal.error ?? "\(session.name) failed to delete"
        // Keep would put back a folder whose worktree record git already deleted.
        if removal.released {
          stayed.append(
            (id, Wait.sentence(reason) + " git already dropped its worktree, so retry the delete in the Inbox.", false))
        } else {
          stayed.append((id, reason, true))
        }
      case nil:
        stayed.append((id, "\(session.name) is no longer being deleted", false))
      }
    }
    if !waiting { return (gone, stayed) }
    Thread.sleep(forTimeInterval: 1)
  }
}

private typealias Stayed = (id: String, reason: String, failed: Bool)

/// Sends `rm-keep` for a session whose removal failed, so the session goes
/// back to Done, and returns the skip's reason. A refused Keep adds its
/// refusal to the reason.
private func keep(_ id: String, failedWith reason: String) -> String {
  do {
    _ = try client.call("rm-keep", ["session": .string(id)])
    return Wait.sentence(reason) + " Kept in Done. Run sb rm --done again to retry."
  } catch {
    return Wait.sentence(reason) + " Keep failed: \(error)"
  }
}

private func dismiss(_ notice: RemovalNotice) {
  do {
    _ = try client.call("removal-notice-dismiss", ["id": .number(Double(notice.id))])
  } catch {
    warn("can't dismiss the removal notice for \(notice.session): \(error)")
  }
}

/// The removal notices, or none with a warning when sbd doesn't answer, so
/// the result still prints after `rm-keep` went out.
private func removalNotices() -> [RemovalNotice] {
  do {
    return try client.call("removal-notices", as: [RemovalNotice].self)
  } catch {
    warn("can't read the removal notices: \(error)")
    return []
  }
}

private func printResult(_ result: RemovalResult, json: Bool) {
  if json { return printJSON(encoded(result)) }
  print("removed \(result.removed.count), skipped \(result.skipped.count)")
  for s in result.partial { print("  \(s.id)  \(s.name): \(s.reason)".printable) }
  for s in result.skipped { print("  skipped \(s.id)  \(s.name): \(s.reason)".printable) }
}

private func printQueued(_ queued: RemovalQueued, names: [String: String], json: Bool) {
  if json { return printJSON(encoded(queued)) }
  print("queued \(queued.queued.count), skipped \(queued.skipped.count)")
  for id in queued.queued { print("  \(id)  \(names[id] ?? id)".printable) }
  for s in queued.skipped { print("  skipped \(s.id)  \(s.name): \(s.reason)".printable) }
}

private func encoded(_ value: some Encodable) -> JSON {
  do { return try JSON(encoding: value) } catch { die("\(error)") }
}

private func describe(_ plan: RemovalPlan) -> String {
  var lines: [String] = []
  if plan.remove.isEmpty { lines.append("No Done session to remove.") }
  for item in plan.remove {
    var parts = ["session"]
    if let worktree = item.worktree { parts.append("worktree \(worktree)") }
    if let branch = item.branch { parts.append("branch \(branch)") }
    if item.remoteBranch { parts.append("remote branch") }
    let pr = item.pr.map { " #\($0)" } ?? ""
    lines.append("  \(item.id)  \(item.name)\(pr): \(parts.joined(separator: ", "))".printable)
  }
  if !plan.skip.isEmpty { lines.append("Skipped:") }
  for s in plan.skip { lines.append("  \(s.id)  \(s.name): \(s.reason)".printable) }
  return lines.joined(separator: "\n")
}
