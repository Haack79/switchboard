import Foundation
import SwitchboardCore

/// Wait actions: when an action wait's condition is met, sbd runs the action with its checks on
/// `followThroughQueue`, off the state queue, and records the result. Anything that needs judgment goes to the
/// wait's holder as one question.
extension Service {
  /// What one run of an action ended with.
  enum ActionOutcome {
    /// The action ran or was already done. `report`, when set, becomes an info report on the operator.
    case done(result: String, detail: String, report: String?)
    /// Not yet. `message` goes to the subject once per `messageKey`.
    case hold(reason: String, message: String?, messageKey: String?)
    /// The subject is no longer in the wait's state, so the wait waits for its condition again.
    case rearm
    /// The holder must decide. `approval` is what `sb operator approve` approves, for a question about the reply,
    /// and `reply` is the last reply whose digest it covers.
    case judgment(question: String, approval: MergeGuard.Approval? = nil, reply: String? = nil)
  }

  /// Marks the action running, stores it, and runs it on `followThroughQueue`. A run keeps the fields of the status
  /// before it, so a hold's start time, its message key, and an approval survive it. `approval` replaces the stored
  /// one. It runs on the state queue.
  func startAction(_ holder: String, _ wait: Wait, approval: MergeGuard.Approval? = nil) throws {
    var status = wait.actionStatus ?? ActionStatus(kind: .running, since: nowMs())
    status.kind = .running
    status.retryAt = nil
    if let approval { status.approval = approval }
    try setActionStatus(holder, wait.id, status)
    followThroughQueue.async { [self] in runAction(holder, wait.id) }
  }

  /// The repository, PR, and files of the merge that an action made for `subject`, as `lastSbdMerges` holds it.
  private func lastSbdMerge(of subject: String) -> (repo: String, number: Int, files: Set<String>?)? {
    lastSbdMerges.first { $0.value.subject == subject }.map { ($0.key, $0.value.number, $0.value.files) }
  }

  /// Rebuilds `lastSbdMerges` from the newest `wait-resolved` events of merge actions that merged, so a restart
  /// keeps the hold on a base whose checks run on sbd's own merge. It runs on the state queue.
  func loadSbdMerges() {
    let events = (try? store.events(kind: "wait-resolved", limit: 500, newest: true)) ?? []
    for event in events.sorted(by: { $0.id < $1.id }) {
      let action = event.data["action"]
      guard action?["kind"]?.string == WaitAction.Kind.merge.rawValue,
        action?["result"]?.string == MergeAttempt.Result.merged.rawValue, let repo = action?["repo"]?.string,
        let number = action?["pr"]?.int, let subject = event.data["wait"]?["session"]?["id"]?.string
      else { continue }
      let files = action?["files"]?.array.map { Set($0.compactMap(\.string)) }
      lastSbdMerges[repo.lowercased()] = (subject, number, files)
    }
  }

  /// Runs the actions that were running when sbd stopped, from their checks. A merge that landed before the stop
  /// finishes as done. It runs on the state queue.
  func resumeActions() {
    for id in entries.keys.sorted() {
      for wait in entries[id]?.session.waits ?? [] where wait.actionStatus?.kind == .running {
        followThroughQueue.async { [self] in runAction(id, wait.id) }
      }
    }
  }

  private func setActionStatus(_ holder: String, _ waitId: String, _ status: ActionStatus?) throws {
    try update(holder) {
      $0.waits = $0.waits?.map { w in
        guard w.id == waitId else { return w }
        var w = w
        w.actionStatus = status
        return w
      }
    }
  }

  /// Runs the action of the wait and records how it ended. Any error becomes a question to the holder, so a wait
  /// never stays running. It runs on `followThroughQueue`.
  private func runAction(_ holder: String, _ waitId: String) {
    guard let wait = queue.sync(execute: { entries[holder]?.session.waits?.first { $0.id == waitId } }),
      let action = wait.action
    else { return }
    let outcome: ActionOutcome
    do {
      switch action.kind {
      case .merge: outcome = try runMerge(holder, wait)
      case .rmWorktree: outcome = try runRemoval(wait, worktree: true)
      case .rm: outcome = try runRemoval(wait, worktree: false)
      case .report: outcome = try runReport(wait)
      }
    } catch {
      outcome = .judgment(question: "sbd could not \(action.kind.skipped): \(error)")
    }
    queue.sync { finish(holder, waitId, outcome) }
  }

  /// Records how the action ended. Done removes the wait and records `wait-resolved` with the action, a
  /// `follow-through` event on the subject, and an info report for a merge or a removal. A hold sets the retry time
  /// and sends its message to the subject unless it already went. A hold for one reason past
  /// `operator.holdLimitSeconds` becomes a question. A question goes to the holder. It runs on the state queue.
  private func finish(_ holder: String, _ waitId: String, _ outcome: ActionOutcome) {
    guard let wait = entries[holder]?.session.waits?.first(where: { $0.id == waitId }), let action = wait.action
    else {
      logLine("wait \(waitId) of \(holder) went while its action ran")
      return
    }
    let now = nowMs()
    let old = wait.actionStatus ?? ActionStatus(kind: .running, since: now)
    let subject = (wait.subject ?? wait.session)?.id
    do {
      switch outcome {
      case .done(let result, let detail, let report):
        try update(holder) { $0.waits = ($0.waits ?? []).filter { $0.id != waitId } }
        var data: [String: JSON] = [
          "kind": .string(action.kind.rawValue), "result": .string(result), "detail": .string(detail),
        ]
        if let merged = subject.flatMap(lastSbdMerge(of:)) {
          data["repo"] = .string(merged.repo)
          data["pr"] = .number(Double(merged.number))
          data["files"] = merged.files.map { .array($0.sorted().map(JSON.string)) } ?? .null
        }
        var resolved: [String: JSON] = [
          "wait": try JSON(encoding: wait), "outcome": .string(detail), "action": .object(data),
        ]
        if let from = wait.handedFrom { resolved["from"] = .string(from.id) }
        record(holder, "wait-resolved", .object(resolved))
        if let subject, entries[subject] != nil {
          var event: [String: JSON] = [
            "wait": .string(waitId), "action": .string(action.kind.rawValue), "result": .string(result),
          ]
          if let from = wait.handedFrom { event["from"] = .string(from.id) }
          record(subject, "follow-through", .object(event))
        }
        if let report { try recordReport(report, needsYou: false, about: subject, wait: waitId) }
        if action.kind == .merge, let repo = subject.flatMap({ entries[$0]?.facts.pr?.repo }) {
          try retryHeldMerges(in: repo)
        }
      case .hold(let reason, let message, let key):
        var status = old
        if old.reason != reason { status.since = now }
        let limit = Int64(config.operator.holdLimitSeconds) * 1000
        if now - status.since >= limit {
          let hours = config.operator.holdLimitSeconds / 3600
          return finish(holder, waitId, .judgment(question: "still held after \(hours) h: \(reason)"))
        }
        status.kind = .held
        status.reason = reason
        status.retryAt = now + Int64(config.operator.holdRetrySeconds) * 1000
        status.subjectSince = subject.flatMap { entries[$0]?.facts.stateSince }
        try setActionStatus(holder, waitId, status)
        if let message, let subject, key != old.messageKey {
          // A failed send leaves the key unset, so the next hold sends the message again.
          do {
            _ = try send(subject, message, by: .sbd, trigger: .wait)
            status.messageKey = key
            try setActionStatus(holder, waitId, status)
          } catch {
            logLine("can't send the hold message of wait \(waitId) to \(subject): \(error)")
          }
        }
      case .rearm:
        try setActionStatus(holder, waitId, nil)
      case .judgment(let question, let approval, let reply):
        var status = old
        status.kind = .awaitingJudgment
        status.since = now
        status.reason = question
        status.retryAt = nil
        status.head = approval?.head
        status.replyDigest = approval?.replyDigest
        try setActionStatus(holder, waitId, status)
        do {
          let session = entries[holder]!.session
          let text = wait.judgmentMessage(
            question: question, holder: Wait.SessionTarget(id: holder, name: session.name),
            byOperator: session.kind == .operator, approvable: approval != nil, reply: reply)
          _ = try send(holder, text, by: .sbd, trigger: .wait)
        } catch {
          logLine("can't ask about wait \(waitId) of \(holder): \(error)")
          holdAfterFailure(holder, waitId, question)
        }
      }
    } catch {
      logLine("can't record the \(action.kind.rawValue) action of wait \(waitId) of \(holder): \(error)")
      holdAfterFailure(holder, waitId, "sbd could not record how the action ended")
    }
  }

  /// Holds the action of a wait that `finish` could not move on, so the tick or the poller checks it again and the
  /// wait never stays running or asks nobody. It does nothing when the wait is gone.
  private func holdAfterFailure(_ holder: String, _ waitId: String, _ reason: String) {
    guard let wait = entries[holder]?.session.waits?.first(where: { $0.id == waitId }) else { return }
    let now = nowMs()
    var status = wait.actionStatus ?? ActionStatus(kind: .held, since: now)
    if status.kind == .held { return }
    status.kind = .held
    status.reason = reason
    status.since = now
    status.retryAt = now + Int64(config.operator.holdRetrySeconds) * 1000
    try? setActionStatus(holder, waitId, status)
  }

  /// Records a report on the operator, with the id of the wait whose action made it.
  private func recordReport(_ text: String, needsYou: Bool, about: String?, wait: String) throws {
    var data: [String: JSON] = [
      "text": .string(oneLine(text, max: TriageCard.lineLength)), "needsYou": .bool(needsYou), "wait": .string(wait),
    ]
    if let about, entries[about] != nil { data["about"] = .string(about) }
    try recordStored(try ensureOperator(), OperatorReport.event, .object(data))
  }

  /// Makes the held merges in `repo` due now, because a merge that one of them held behind just finished.
  private func retryHeldMerges(in repo: String) throws {
    let now = nowMs()
    for id in entries.keys.sorted() {
      for wait in entries[id]?.session.waits ?? [] {
        guard wait.action?.kind == .merge, var status = wait.actionStatus, status.kind == .held,
          let pr = wait.session.flatMap({ entries[$0.id]?.facts.pr }), Dependencies.sameRepo(pr.repo, repo)
        else { continue }
        status.retryAt = now
        try setActionStatus(id, wait.id, status)
      }
    }
  }

  // MARK: The approval

  /// The `wait-approve` request: the operator approves the merge that a question about the last reply asked about.
  /// The approval covers the head and the reply that the question covered, so a push or a new reply since makes sbd
  /// ask again. Only a client inside the operator's Claude pane may send it, and its `caller` must name the
  /// operator, because any process can set SB_SESSION_ID. It runs on the state queue, after `install` of a fresh
  /// snapshot.
  func approveWait(_ args: JSON, caller: Caller) throws -> JSON {
    let refusal = APIError("only the operator approves a wait, from its own pane")
    guard let op = operatorID(), args["caller"]?.string == op else { throw refusal }
    guard let ancestry = try caller.ancestry(command: "sb operator approve"), let pane = paneRow(op, .claude),
      !pane.dead, Processes.isValidPid(pane.pid), ancestry.contains(pane.pid)
    else { throw refusal }
    let waitId = args["wait"]?.string ?? ""
    guard let wait = entries[op]?.session.waits?.first(where: { $0.id == waitId }) else {
      throw APIError("the operator has no wait \(waitId)")
    }
    guard let status = wait.actionStatus, status.kind == .awaitingJudgment, let head = status.head,
      let digest = status.replyDigest
    else { throw APIError("wait \(waitId) isn't waiting for an approval of a merge") }
    try startAction(op, wait, approval: MergeGuard.Approval(head: head, replyDigest: digest))
    return try JSON(encoding: summary(op))
  }

  // MARK: Merge

  /// What `runMerge` reads on the state queue.
  private struct MergeFacts {
    var name: String
    var facts: SessionFacts
    var verdict: Verdict?
    var busy: Bool
    var earlier: [Int]
    var lastSbdMerge: MergeGuard.SbdMerge?
    var approval: MergeGuard.Approval?
  }

  /// Lands the subject's PR when `MergeGuard` acts. The checks that need no live read run first, so a wait that
  /// can't merge runs no gh command. A PR that is already merged, in the facts or the live read, finishes as done,
  /// which is how a merge that landed before a restart ends. `operator.mergeRepos` is read from config.json again,
  /// so a repository that the user took off the list stops merging without a restart. It runs on
  /// `followThroughQueue`.
  private func runMerge(_ holder: String, _ wait: Wait) throws -> ActionOutcome {
    guard let subject = wait.session?.id else {
      return .judgment(question: "the wait names no session to merge")
    }
    let mergeRepos = home.loadConfig().operator.mergeRepos
    let read = queue.sync { mergeFacts(subject, wait) }
    let facts = read.facts
    if let pr = facts.pr, pr.state == .merged { return alreadyMerged(pr, subject, read.name) }
    if read.busy, let pr = facts.pr {
      return .hold(reason: "\(read.name) is merging #\(pr.number) or being deleted", message: nil, messageKey: nil)
    }
    if let verdict = MergeGuard.checkFacts(mergeRepos: mergeRepos, verdict: read.verdict, facts: facts) {
      return outcome(of: verdict, input: nil)
    }
    let pr = facts.pr!
    let live = livePR(pr)
    if live?.state == .merged { return alreadyMerged(pr, subject, read.name) }
    let compared = live.flatMap { compare(pr.repo, base: $0.base, head: $0.head) }
    let baseTip = compared?.baseTip
    let files = changedFiles(pr.repo, pr.number)
    let input = MergeGuard.Input(
      mergeRepos: mergeRepos, verdict: read.verdict, facts: facts, live: live, behindBy: compared?.behindBy,
      baseTip: baseTip, baseRollup: baseTip.flatMap { baseRollup(pr.repo, $0) }, files: files,
      earlierFiles: read.earlier.map { changedFiles(pr.repo, $0) },
      lastSbdMerge: read.lastSbdMerge,
      approval: read.approval)
    let verdict = MergeGuard.check(input)
    guard verdict == .act, let approval = read.approval else { return outcome(of: verdict, input: input) }
    if let changed = queue.sync(execute: { takeForMerge(holder, wait.id, subject, pr, approval) }) { return changed }
    defer { queue.sync { _ = merging.remove(subject) } }
    let attempt: MergeAttempt
    do {
      attempt = try landPR(subject, pr: pr, method: facts.mergeMethod)
    } catch {
      return .judgment(question: "\(error)")
    }
    if attempt.result == .merged {
      queue.sync { lastSbdMerges[pr.repo.lowercased()] = (subject, pr.number, files) }
    }
    let landed = "\(facts.mergeMethod.pastTense.capitalized) #\(pr.number) of \(read.name) at \(pr.headSha.prefix(7))"
    return .done(result: attempt.result.rawValue, detail: landed, report: landed)
  }

  /// Checks again what may have changed during the live reads, and when nothing did, puts the subject in `merging`
  /// in the same step, so the merge runs only for a wait that is still running, at the head that the guard read,
  /// for the reply that the holder approved, while the subject is still Ready to merge. It returns the outcome that
  /// replaces the merge, or nil. It runs on the state queue.
  private func takeForMerge(
    _ holder: String, _ waitId: String, _ subject: String, _ pr: PullRequest, _ approval: MergeGuard.Approval
  ) -> ActionOutcome? {
    guard entries[holder]?.session.waits?.first(where: { $0.id == waitId })?.actionStatus?.kind == .running else {
      return .rearm
    }
    guard let e = entries[subject], beingDeletedRefusal(subject) == nil, !merging.contains(subject) else {
      return .hold(reason: "the session is merging #\(pr.number) or being deleted", message: nil, messageKey: nil)
    }
    guard Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState).state == .readyToMerge else {
      return .rearm
    }
    guard e.facts.pr?.headSha == pr.headSha else {
      return .hold(reason: "the head of #\(pr.number) moved during the checks", message: nil, messageKey: nil)
    }
    let digest = MergeGuard.replyDigest(e.facts.lastReply)
    guard digest == approval.replyDigest else {
      return .judgment(
        question: "\(e.session.name) replied again while sbd checked #\(pr.number) at \(pr.headSha.prefix(7)). Does "
          + "the new reply ask the user a question, leave a decision for the user, or say that /go did not finish?",
        approval: MergeGuard.Approval(head: pr.headSha, replyDigest: digest), reply: e.facts.lastReply)
    }
    merging.insert(subject)
    return nil
  }

  /// The facts that `runMerge` reads on the state queue. A subject that is gone or being deleted has no verdict.
  /// The earlier merges are the other open merge waits on an open PR in the same repository, set before this one.
  private func mergeFacts(_ subject: String, _ wait: Wait) -> MergeFacts {
    guard let e = entries[subject] else {
      return MergeFacts(
        name: wait.session?.name ?? subject, facts: SessionFacts(), verdict: nil, busy: false, earlier: [],
        lastSbdMerge: nil, approval: wait.actionStatus?.approval)
    }
    let deleting = beingDeletedRefusal(subject) != nil
    let verdict = deleting ? nil : Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
    var earlier: [Int] = []
    var last: MergeGuard.SbdMerge?
    if let repo = e.facts.pr?.repo {
      for holder in entries.values {
        for other in holder.session.waits ?? [] {
          guard other.id != wait.id, other.action?.kind == .merge, (other.created, other.id) < (wait.created, wait.id),
            let pr = other.session.flatMap({ entries[$0.id]?.facts.pr }), pr.state == .open,
            Dependencies.sameRepo(pr.repo, repo)
          else { continue }
          earlier.append(pr.number)
        }
      }
      if let merged = lastSbdMerges[repo.lowercased()] {
        let pr = entries[merged.subject]?.facts.pr
        last = MergeGuard.SbdMerge(commit: pr?.number == merged.number ? pr?.mergeCommit : nil, files: merged.files)
      }
    }
    return MergeFacts(
      name: e.session.name, facts: e.facts, verdict: verdict, busy: merging.contains(subject), earlier: earlier,
      lastSbdMerge: last, approval: wait.actionStatus?.approval)
  }

  /// The outcome for a PR that merged before this run, such as a merge that landed before a restart. It counts as
  /// sbd's last merge in the repository with unknown files, so a pending base after it holds an overlapping merge.
  private func alreadyMerged(_ pr: PullRequest, _ subject: String, _ name: String) -> ActionOutcome {
    queue.sync { lastSbdMerges[pr.repo.lowercased()] = (subject, pr.number, nil) }
    let text = "#\(pr.number) of \(name) is merged"
    return .done(result: "merged", detail: text, report: text)
  }

  /// The action's outcome for a verdict that does not act. A hold's message goes once per head and base tip. A
  /// question about the reply carries the approval that would let `input` act.
  private func outcome(of verdict: MergeGuard.Verdict, input: MergeGuard.Input?) -> ActionOutcome {
    switch verdict {
    case .act:
      return .judgment(question: "sbd could not decide whether to merge")
    case .hold(let reason, let message):
      let key = input.map { "\($0.live?.head ?? "")@\($0.baseTip ?? "")" }
      return .hold(reason: reason, message: message, messageKey: message == nil ? nil : key)
    case .rearm:
      return .rearm
    case .judgment(let question):
      let approval = input.flatMap(MergeGuard.replyGate)
      return .judgment(question: question, approval: approval, reply: approval == nil ? nil : input?.facts.lastReply)
    }
  }

  // MARK: Live reads

  /// gh's output as JSON, or nil when gh failed or printed something else.
  private func ghJSON(_ args: [String]) -> JSON? {
    (try? runGh(args, timeout: 30)).flatMap(JSON.parse)
  }

  /// The PR as GitHub has it now.
  private func livePR(_ pr: PullRequest) -> MergeGuard.LivePR? {
    guard
      let json = ghJSON([
        "pr", "view", String(pr.number), "--repo", pr.repo, "--json",
        "headRefOid,state,isDraft,mergeable,baseRefName,statusCheckRollup",
      ]), let head = json["headRefOid"]?.string, let state = json["state"]?.string.flatMap(PRState.init(rawValue:)),
      let draft = json["isDraft"]?.bool, let base = json["baseRefName"]?.string
    else { return nil }
    return MergeGuard.LivePR(
      head: head, state: state, draft: draft, mergeable: json["mergeable"]?.string.flatMap(Mergeable.init(rawValue:)),
      base: base, rollup: Service.rollup(json["statusCheckRollup"]?.array ?? []))
  }

  /// How many commits the head lacks from the base branch, and the base branch's tip.
  private func compare(_ repo: String, base: String, head: String) -> (behindBy: Int, baseTip: String)? {
    guard let json = ghJSON(["api", "repos/\(repo)/compare/\(base)...\(head)"]),
      let behind = json["behind_by"]?.int, let tip = json["base_commit"]?["sha"]?.string
    else { return nil }
    return (behind, tip)
  }

  /// The rollup of a commit's check runs and statuses. A list longer than one page is unknown.
  private func baseRollup(_ repo: String, _ sha: String) -> String? {
    guard let runs = ghJSON(["api", "repos/\(repo)/commits/\(sha)/check-runs?per_page=100"]),
      let list = runs["check_runs"]?.array, (runs["total_count"]?.int ?? 0) <= list.count,
      let status = ghJSON(["api", "repos/\(repo)/commits/\(sha)/status"])
    else { return nil }
    // GitHub's combined state is pending for a commit without statuses.
    let statuses = (status["total_count"]?.int ?? 0) > 0 ? [JSON.object(["state": status["state"] ?? .null])] : []
    return Service.rollup(list + statuses)
  }

  /// The PR's changed files, or nil when a page failed or the PR has more files than 30 pages hold.
  private func changedFiles(_ repo: String, _ number: Int) -> Set<String>? {
    var files = Set<String>()
    for page in 1...30 {
      guard let list = ghJSON(["api", "repos/\(repo)/pulls/\(number)/files?per_page=100&page=\(page)"])?.array
      else { return nil }
      files.formUnion(list.compactMap { $0["filename"]?.string })
      if list.count < 100 { return files }
    }
    return nil
  }

  /// One state for a list of check runs and statuses: FAILURE when any failed, PENDING when any still runs, and
  /// SUCCESS when all passed. A check run carries `status` and `conclusion`, and a status carries `state`. An
  /// empty list has no state.
  static func rollup(_ contexts: [JSON]) -> String? {
    guard !contexts.isEmpty else { return nil }
    var pending = false
    for c in contexts {
      if let state = c["state"]?.string?.uppercased() {
        switch state {
        case "SUCCESS": continue
        case "PENDING", "EXPECTED": pending = true
        default: return "FAILURE"
        }
      } else if c["status"]?.string?.uppercased() != "COMPLETED" {
        pending = true
      } else if !["SUCCESS", "NEUTRAL", "SKIPPED"].contains(c["conclusion"]?.string?.uppercased() ?? "") {
        return "FAILURE"
      }
    }
    return pending ? "PENDING" : "SUCCESS"
  }

  // MARK: Removal and report

  /// Removes the subject as `sb rm` does, with its worktree for `rm-worktree`, when `RemovalGuard` allows it. Each
  /// refusal of `remove` becomes a question that quotes it. It runs on `followThroughQueue`.
  private func runRemoval(_ wait: Wait, worktree: Bool) throws -> ActionOutcome {
    guard let target = wait.subject ?? wait.session else {
      return .judgment(question: "the wait names no session to remove")
    }
    let subject = target.id
    let input = queue.sync {
      let e = entries[subject]
      return RemovalGuard.Input(
        name: e?.session.name ?? target.name, exists: e != nil,
        busy: beingDeletedRefusal(subject) != nil || busyRefusal(subject) != nil, host: e?.session.host,
        worktree: worktree, pr: e?.facts.pr, turnRunning: e?.facts.turnRunning ?? false,
        messageWaiting: e?.messageWaiting(now: nowMs()) ?? false)
    }
    switch RemovalGuard.check(input) {
    case .gone:
      return .done(result: "removed", detail: "\(target.name) was already removed", report: nil)
    case .hold(let reason):
      return .hold(reason: reason, message: nil, messageKey: nil)
    case .judgment(let question):
      return .judgment(question: question)
    case .remove:
      break
    }
    do {
      _ = try remove(["session": .string(subject), "worktree": .bool(worktree)], caller: .inProcess)
    } catch {
      return .judgment(question: "sbd could not remove \(target.name): \(error)")
    }
    let detail = worktree ? "Removed \(target.name) and its worktree" : "Removed \(target.name)"
    return .done(result: "removed", detail: detail, report: detail)
  }

  /// Records the wait's note as a report on the operator, once: a report that already carries the wait's id, from a
  /// run before a restart, counts as done. It runs on `followThroughQueue`.
  private func runReport(_ wait: Wait) throws -> ActionOutcome {
    try queue.sync {
      let op = try ensureOperator()
      let reports = try store.events(session: op, kind: OperatorReport.event, limit: Int.max, newest: true)
      if !reports.contains(where: { $0.data["wait"]?.string == wait.id }) {
        try recordReport(
          wait.note ?? "", needsYou: wait.action?.needsYou == true, about: (wait.subject ?? wait.session)?.id,
          wait: wait.id)
      }
      return .done(result: "reported", detail: "Recorded the report", report: nil)
    }
  }
}
