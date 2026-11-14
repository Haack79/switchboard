import Foundation
import SwitchboardCore
import Testing

extension MergedPRRepo {
  /// A Done session whose folder had the PR's branch checked out, then made the merged PR's head on
  /// `<branch>-v2` and pushed it. With `sessionOnV2`, sbd makes the worktree on `-v2`, so the session's own
  /// branch is `-v2`. Otherwise sbd makes it on the PR's branch, and the folder switches to `-v2`.
  fileprivate func doneOnV2(_ pr: RemovalPR, sessionOnV2: Bool) throws -> (
    session: SessionSummary, v2: String, tip: String
  ) {
    let v2 = "\(pr.branch)-v2"
    let s: SessionSummary
    if sessionOnV2 {
      s = try sbd.worktreeSession(repo, branch: v2)
      try sbd.git(s.cwd, "checkout", "-q", "-b", pr.branch)
      try sbd.git(s.cwd, "checkout", "-q", v2)
    } else {
      s = try sbd.worktreeSession(repo, branch: pr.branch)
      try sbd.git(s.cwd, "checkout", "-q", "-b", v2)
    }
    try sbd.commit(s.cwd, "v2.txt")
    try sbd.git(s.cwd, "push", "-q", "origin", v2)
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    try sbd.link(s, "PostHog/posthog", pr.number)
    github.change(pr.number) {
      $0["state"] = "MERGED"
      $0["headRefOid"] = .string(tip)
    }
    try pollUntilDone(s)
    return (s, v2, tip)
  }
}

extension Instance {
  /// `sb rm --done` waits for the removal job with no deadline, so a hung job would hold the test until CI's job
  /// timeout.
  fileprivate func rmDone(_ flags: String..., env: [String: String] = [:]) throws -> CommandResult {
    try run(["rm", "--done"] + flags, env: env, timeout: 300)
  }

  /// The `rm-done` preview.
  fileprivate func planDoneRemoval(worktree: Bool = true, remoteBranch: Bool = false) throws -> JSON {
    try client.call("rm-done", ["worktree": .bool(worktree), "remote_branch": .bool(remoteBranch)])
  }

  /// The `rm-plan` op. Nil `targets` leaves the field out.
  fileprivate func planRemoval(
    _ targets: [String]?, scope: String, worktree: Bool = true, remoteBranch: Bool = false
  ) throws -> JSON {
    var args: [String: JSON] = [
      "scope": .string(scope), "worktree": .bool(worktree), "remote_branch": .bool(remoteBranch),
    ]
    if let targets { args["targets"] = .array(targets.map(JSON.string)) }
    return try client.call("rm-plan", args)
  }

  /// A work session in its own worktree that the user acknowledged, so it is Waiting.
  fileprivate func waitingSession(_ repo: String, branch: String) throws -> SessionSummary {
    let s = try worktreeSession(repo, branch: branch)
    try waitFor(s.id, "the summary of the first reply") { $0.state == .needsYou && $0.triage?.source == .summary }
    try sb("ack", s.id)
    return try waitFor(s.id, "Waiting") { $0.state == .waiting }
  }

  /// The chat of a new group with no members.
  fileprivate func chatSession(_ group: String) throws -> SessionSummary {
    let g = try JSONCoding.decode(GroupSummary.self, from: sb("group", "add", "--json", group))
    return try JSONCoding.decode(SessionSummary.self, from: sb("chat", g.id, "--json"))
  }

  /// The confirmed `rm-done` on `targets`.
  fileprivate func removeDone(_ targets: [String], worktree: Bool = true) throws -> JSON {
    try client.call(
      "rm-done",
      ["worktree": .bool(worktree), "confirmed": true, "targets": .array(targets.map(JSON.string))],
      timeout: 300)
  }

  /// Starts `sb rm --done` with the flags on a thread of its own, so the test can read sbd while the command waits.
  fileprivate func startRmDone(_ flags: String...) -> Outcome<CommandResult> {
    let args = ["rm", "--done"] + flags
    return Outcome.detached { try self.run(args, timeout: 300) }
  }

  /// Waits until sbd's removal job holds every session in `ids`, with one of them running and the rest queued, and
  /// returns each session's removal state. The worker holds the running one at the `hold-removal` gate. A command
  /// that removes each session itself never records a removal and ends first, so this throws with its output.
  @discardableResult
  fileprivate func waitForJob(_ ids: [String], while command: Outcome<CommandResult>) throws -> [String: String] {
    var states: [String: String] = [:]
    try waitFor("the removal job to hold \(ids.joined(separator: ", "))", timeout: 30) {
      if let ended = command.result {
        let output = (try? ended.get()).map { "status \($0.status)\nstdout: \($0.stdout)\nstderr: \($0.stderr)" }
        throw TestError(
          description: "sb rm --done ended before the removal job held its sessions: \(output ?? "\(ended)")")
      }
      states = [:]
      for s in try listedSessions() {
        guard let id = s["id"]?.string, ids.contains(id), let state = s["removal"]?["state"]?.string else { continue }
        states[id] = state
      }
      return states.count == ids.count && states.values.filter { $0 == "running" }.count == 1
        && states.values.allSatisfy { $0 == "running" || $0 == "queued" }
    }
    return states
  }

  /// Waits for the command to exit and returns its result.
  fileprivate func finish(_ command: Outcome<CommandResult>, timeout: Double = 60) throws -> CommandResult {
    guard command.done.wait(timeout: .now() + timeout * Instance.timeoutScale) == .success else {
      throw TestError(description: "sb rm --done did not exit within \(timeout) s after the job was released")
    }
    return try #require(command.result).get()
  }

  fileprivate func noticeSessions() throws -> [String] { try removalNotices().map(\.session) }
}

/// The ids in the result's `removed`.
private func removed(_ result: JSON) -> Set<String> { Set(result["removed"]?.array?.compactMap(\.string) ?? []) }

/// The `skipped` or `skip` entry for the session, or nil when the list doesn't name it.
private func skip(_ list: JSON?, _ id: String) -> JSON? { list?.array?.first { $0["id"]?.string == id } }

/// The ids in a preview's `remove`.
private func planned(_ plan: JSON) -> Set<String> {
  Set(plan["remove"]?.array?.compactMap { $0["id"]?.string } ?? [])
}

private func item(_ plan: JSON, _ id: String) -> JSON? { plan["remove"]?.array?.first { $0["id"]?.string == id } }

/// The plan with `remove` and `skip` in id order, so two plans compare whatever order the checks finished in.
private func sorted(_ plan: RemovalPlan) -> RemovalPlan {
  RemovalPlan(remove: plan.remove.sorted { $0.id < $1.id }, skip: plan.skip.sorted { $0.id < $1.id })
}

/// A field that the preview sends as null, or leaves out as Swift's encoder does for nil.
private func isNull(_ value: JSON?) -> Bool { value == nil || value == .null }

private func parse(_ r: CommandResult) throws -> JSON {
  try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
}

@Suite(.blocking(timeLimit: .seconds(120))) struct DoneRemovalTests {
  // MARK: Removal

  @Test func removesMergedDoneSessionsWithTheirWorktreesAndBranches() throws {
    let s = try MergedPRRepo()
    let a = try s.finished(.breaker, state: "MERGED")
    let b = try s.finished(.groups, state: "MERGED")
    try s.pollUntilDone(a, b)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try parse(r)
    #expect(removed(result) == [a.id, b.id])
    #expect(result["skipped"]?.array?.isEmpty == true)
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.groups.branch))
  }

  @Test func resultDecodesAsADoneRemovalResult() throws {
    let s = try MergedPRRepo()
    let a = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(a)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(result.removed == [a.id])
    #expect(result.skipped.isEmpty)
  }

  @Test func skipsUnpushedCommitsOfAClosedPRAndUncommittedFiles() throws {
    let s = try MergedPRRepo()
    let unpushed = try s.finished(.cohort, state: "CLOSED")
    let dirty = try s.sbd.worktreeSession(s.repo, branch: "haacked/dirty")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try s.pollUntilDone(unpushed)
    try s.sbd.markSessionDone(dirty.id)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let unpushedReason = try #require(skip(result["skipped"], unpushed.id)?["reason"]?.string)
    #expect(unpushedReason.contains("not on a pushed branch"), Comment(rawValue: unpushedReason))
    let dirtyReason = try #require(skip(result["skipped"], dirty.id)?["reason"]?.string)
    #expect(dirtyReason.contains("uncommitted"), Comment(rawValue: dirtyReason))
    #expect(try s.sbd.listedIds() == [unpushed.id, dirty.id])
    #expect(FileManager.default.fileExists(atPath: unpushed.cwd))
    #expect(FileManager.default.fileExists(atPath: "\(dirty.cwd)/notes.txt"))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.cohort.branch))
  }

  /// A merged PR that the transcript linked from another repo makes the
  /// session Done, but only a merged PR of the session's own branch lets
  /// removal delete the branch. A PR whose head has the branch's name in
  /// another repo fails on its head commit.
  @Test(arguments: [
    (nil as String?, "has no merged PR"), ("haacked/no-pr-yet", "has commits that are not in its merged PR"),
  ])
  func skipsADoneSessionWhoseMergedPRIsFromAnotherRepo(_ head: String?, _ refusal: String) throws {
    let s = try MergedPRRepo()
    let foreign = try s.sbd.worktreeSession(s.repo, branch: "haacked/no-pr-yet")
    try s.sbd.commit(foreign.cwd, "unpushed.txt")
    let tip = try s.sbd.git(foreign.cwd, "rev-parse", "HEAD")
    try s.sbd.link(foreign, "haacked/review-code", 189)
    s.github.change(189) {
      $0["state"] = "MERGED"
      if let head { $0["headRefName"] = .string(head) }
    }
    try s.pollUntilDone(foreign)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], foreign.id)?["reason"]?.string)
    #expect(reason.contains(refusal), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: foreign.cwd))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/haacked/no-pr-yet") == tip)
  }

  /// The folder made the merged PR's head on `-v2`, so the session is Done. The PR merged its own
  /// branch, not `-v2`, so removal keeps both branches.
  @Test func keepsTheBranchesOfADoneSessionWhoseMergedPRUsesAnEarlierBranch() throws {
    let s = try MergedPRRepo()
    let (session, v2, tip) = try s.doneOnV2(.breaker, sessionOnV2: false)
    let original = try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(RemovalPR.breaker.branch)")

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty, Comment(rawValue: result.text))
    #expect(skip(result["skipped"], session.id) != nil, Comment(rawValue: result.text))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(RemovalPR.breaker.branch)") == original)
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(v2)") == tip)
  }

  @Test func skipsADoneSessionOnV2WhoseMergedPRUsesAnotherBranch() throws {
    let s = try MergedPRRepo()
    let (session, v2, tip) = try s.doneOnV2(.breaker, sessionOnV2: true)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], session.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("has no merged PR"), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(v2)") == tip)
  }

  @Test func cleanupRefusesADoneSessionOnV2WhoseMergedPRUsesAnotherBranch() throws {
    let s = try MergedPRRepo()
    let (session, v2, tip) = try s.doneOnV2(.breaker, sessionOnV2: true)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("has no merged PR"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(v2)") == tip)
  }

  @Test func skipsALockedWorktreeAndRemovesTheRest() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let locked = try sbd.worktreeSession(repo, branch: "haacked/locked")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(locked.id)
    try sbd.markSessionDone(clean.id)
    try sbd.git(repo, "worktree", "lock", "--reason", "Supacode", locked.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], locked.id)?["reason"]?.string)
    #expect(reason.contains("locked"), Comment(rawValue: reason))
    #expect(try sbd.intact(locked))
    #expect(removed(result) == [clean.id])
    #expect(!FileManager.default.fileExists(atPath: clean.cwd))
  }

  @Test func keepsTheBranchOfAClosedPRAndDeletesTheBranchOfAMergedPR() throws {
    let s = try MergedPRRepo()
    let closed = try s.finished(.cohort, state: "CLOSED", push: true)
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(closed, merged)

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [closed.id, merged.id])
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: closed.cwd))
    #expect(try !s.sbd.git(s.repo, "worktree", "list", "--porcelain").contains(closed.cwd))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.cohort.branch))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.cohort.branch))
    #expect(try !s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
  }

  @Test func leavesSessionsThatAreNotDone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    let active = try sbd.worktreeSession(repo, branch: "haacked/active")
    try sbd.markSessionDone(done.id)
    #expect(try sbd.get(active.id).state != .done)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result) == [done.id])
    #expect(skip(result["skipped"], active.id) == nil)
    #expect(try sbd.intact(active))
    #expect(try sbd.get(active.id).live)
    #expect(try sbd.localBranch(repo, "haacked/active"))
  }

  @Test func withoutWorktreeRemovesOnlyTheSessions() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id])
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(FileManager.default.fileExists(atPath: merged.cwd))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
  }

  @Test func deleteRemoteBranchDeletesTheRemoteBranchOfAMergedPR() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id])
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try !s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
  }

  @Test func withoutDeleteRemoteBranchKeepsTheRemoteBranch() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
  }

  /// The remote branch moved after the merge, so `rm` removes the session and keeps the remote branch.
  @Test func reportsARemovalThatKeptTheRemoteBranchAsRemovedAndPartial() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    let other = "\(s.sbd.home.path)/other"
    try s.sbd.git(s.sbd.home.path, "clone", "-q", s.origin, other)
    try s.sbd.git(other, "checkout", "-q", RemovalPR.breaker.branch)
    try s.sbd.commit(other, "later.txt")
    try s.sbd.git(other, "push", "-q", "origin", RemovalPR.breaker.branch)

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try parse(r)
    #expect(removed(result) == [merged.id])
    let reason = try #require(skip(result["partial"], merged.id)?["reason"]?.string)
    #expect(reason.contains("kept the remote branch"), Comment(rawValue: reason))
    #expect(skip(result["skipped"], merged.id) == nil)
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
  }

  // MARK: Every rm check skips the session

  @Test func skipsAWorktreeThatAnotherSessionRunsIn() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/shared")
    let other = try sbd.worktreeSession(repo, branch: "haacked/shared")
    #expect(other.cwd == done.cwd)
    try sbd.markSessionDone(done.id)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], done.id)?["reason"]?.string)
    #expect(reason.contains("also runs in"), Comment(rawValue: reason))
    #expect(removed(result).isEmpty)
    #expect(try sbd.intact(done))
    #expect(try sbd.intact(other))
  }

  @Test func skipsAMergedBranchWithACommitAfterTheMerge() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)
    try s.sbd.commit(merged.cwd, "later.txt")
    try s.sbd.markSessionDone(merged.id)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], merged.id)?["reason"]?.string)
    #expect(reason.contains("not in its merged PR"), Comment(rawValue: reason))
    #expect(try s.sbd.intact(merged))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
  }

  @Test func skipsAFolderThatIsNoLongerAWorktreeOfTheRepo() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/replaced")
    try sbd.markSessionDone(s.id)
    try sbd.git(repo, "worktree", "remove", "--force", s.cwd)
    try FileManager.default.createDirectory(atPath: s.cwd, withIntermediateDirectories: true)
    let keep = "\(s.cwd)/mine.txt"
    try "x".write(toFile: keep, atomically: true, encoding: .utf8)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string)
    #expect(reason.contains("is not a worktree of"), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: keep))
    #expect(try sbd.listedIds() == [s.id])
  }

  /// sbd didn't make the main checkout, so neither the preview nor the removal may delete it.
  @Test func neverRemovesAFolderThatSbdDidNotMake() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.client.call("new", ["path": .string(repo), "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.markSessionDone(s.id)

    let plan = try sbd.planDoneRemoval()
    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(isNull(try #require(item(plan, s.id))["worktree"]))
    #expect(removed(result) == [s.id])
    #expect(FileManager.default.fileExists(atPath: "\(repo)/.git"))
    #expect(try sbd.git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "main")
  }

  // MARK: Which sessions

  @Test func previewLeavesOutTheManagerAndAnUnstartedFollowupMarkedDone() throws {
    let sbd = try Instance()
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    let followup = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets"])
    let done = try sbd.new(prompt: "hello", name: "done")
    try sbd.waitFor(done.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.markSessionDone(manager.id)
    try sbd.markSessionDone(followup.id)
    try sbd.markSessionDone(done.id)

    let plan = try sbd.planDoneRemoval()

    #expect(planned(plan) == [done.id])
    #expect(skip(plan["skip"], manager.id) == nil)
    #expect(skip(plan["skip"], followup.id) == nil)
  }

  @Test func confirmedRemovalRefusesTheManagerAndAnUnstartedFollowupEvenAsTargets() throws {
    let sbd = try Instance()
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    let followup = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets"])
    try sbd.markSessionDone(manager.id)
    try sbd.markSessionDone(followup.id)

    let result = try sbd.removeDone([manager.id, followup.id])

    #expect(removed(result).isEmpty)
    #expect(try sbd.get(manager.id).manager == true)
    #expect(try sbd.get(followup.id).state == .done)
  }

  // MARK: rm-plan for a list of work sessions

  @Test func rmPlanForWorkPlansAWaitingSessionAndSkipsTheManagerAChatAndAnUnstartedFollowup() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let waiting = try sbd.waitingSession(repo, branch: "haacked/waiting")
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    let chat = try sbd.chatSession("Flags")
    let followup = try add(sbd, ["prompt": "Check the rollout.", "repository": "acme/widgets"])
    try #require(try sbd.get(waiting.id).state == .waiting)

    let plan = try sbd.planRemoval([waiting.id, manager.id, chat.id, followup.id], scope: "work")

    #expect(planned(plan) == [waiting.id], Comment(rawValue: plan.text))
    #expect(item(plan, waiting.id)?["worktree"]?.string == waiting.cwd)
    for (s, kind) in [(manager, "manager"), (chat, "chat"), (followup, "follow-up")] {
      let reason = try #require(skip(plan["skip"], s.id)?["reason"]?.string, Comment(rawValue: plan.text))
      #expect(reason.lowercased().contains(kind), Comment(rawValue: reason))
    }
  }

  @Test func rmPlanForWorkRemovesNothing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let waiting = try sbd.waitingSession(repo, branch: "haacked/waiting")

    _ = try sbd.planRemoval([waiting.id], scope: "work")

    #expect(try sbd.intact(waiting))
    #expect(try sbd.get(waiting.id).live)
    #expect(try sbd.localBranch(repo, "haacked/waiting"))
  }

  /// A multi-select delete is not limited to Done.
  @Test func rmPlanForWorkPlansADoneWorkSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(done.id)

    let plan = try sbd.planRemoval([done.id], scope: "work")

    #expect(planned(plan) == [done.id], Comment(rawValue: plan.text))
  }

  /// The Manager stays out of the plan in every state, not only in Done.
  @Test func rmPlanForWorkSkipsTheManagerMarkedDone() throws {
    let sbd = try Instance()
    let manager = try JSONCoding.decode(SessionSummary.self, from: sbd.sb("manager", "--json"))
    try sbd.markSessionDone(manager.id)

    let plan = try sbd.planRemoval([manager.id], scope: "work")

    #expect(planned(plan).isEmpty)
    let reason = try #require(skip(plan["skip"], manager.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.lowercased().contains("manager"), Comment(rawValue: reason))
  }

  @Test func rmPlanForWorkRunsRmsChecks() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.waitingSession(repo, branch: "haacked/dirty")
    let clean = try sbd.waitingSession(repo, branch: "haacked/clean")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)

    let plan = try sbd.planRemoval([dirty.id, clean.id], scope: "work")

    #expect(planned(plan) == [clean.id], Comment(rawValue: plan.text))
    let reason = try #require(skip(plan["skip"], dirty.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
  }

  @Test(arguments: [true, false])
  func rmPlanForWorkSkipsASessionWithAnOpenToDo(worktree: Bool) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.waitingSession(repo, branch: "haacked/held")
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let plan = try sbd.planRemoval([held.id], scope: "work", worktree: worktree)

    #expect(planned(plan).isEmpty)
    let reason = try #require(skip(plan["skip"], held.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(
      reason.contains("\(held.name) has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
  }

  @Test(arguments: ["work", "done"])
  func rmPlanSkipsATargetThatNamesNoSession(scope: String) throws {
    let sbd = try Instance()

    let plan = try sbd.planRemoval(["nope"], scope: scope)

    #expect(planned(plan).isEmpty)
    let reason = try #require(skip(plan["skip"], "nope")?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains("no longer exists"), Comment(rawValue: reason))
  }

  /// Delete All's rule still holds when the caller names the targets.
  @Test func rmPlanForDoneSkipsATargetThatIsNotDone() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let waiting = try sbd.waitingSession(repo, branch: "haacked/waiting")
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(done.id)

    let plan = try sbd.planRemoval([waiting.id, done.id], scope: "done")

    #expect(planned(plan) == [done.id], Comment(rawValue: plan.text))
    let reason = try #require(skip(plan["skip"], waiting.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains("is no longer in Done"), Comment(rawValue: reason))
  }

  /// sb runs below a's shell pane, so a plan that removes a's worktree must skip a, as `rm` refuses it.
  @Test func rmPlanForWorkFromInsideASessionSkipsThatSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/inside")
    let terminals = try sbd.client.terminals(a.id)
    try sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }
    // A tick installs a snapshot that holds the shell pane's pid.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "rm-plan", "args": ["scope": "work", "worktree": true, "targets": .array([.string(a.id)])],
    ]
    let client = [
      #"$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";"#,
      #"print $s "$ARGV[1]\n";"#,
      "print scalar <$s>",
    ].joined(separator: " ")
    try sbd.writeScript(
      "plan", "perl -MIO::Socket::UNIX -e \(shellQuote(client)) \"$SB_HOME/sbd.sock\" \(shellQuote(request.text))")

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/plan.sh\"")
    let r = try sbd.scriptResult("plan")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    let plan = try #require(response["result"], Comment(rawValue: response.text))
    #expect(planned(plan).isEmpty)
    let reason = try #require(skip(plan["skip"], a.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains(insideRefusal("sb rm --worktree", a.id)), Comment(rawValue: reason))
  }

  @Test(arguments: [nil, "Done", "all"] as [String?])
  func rmPlanRefusesAMissingOrUnknownScope(scope: String?) throws {
    let sbd = try Instance()
    var args: [String: JSON] = ["worktree": true]
    if let scope { args["scope"] = .string(scope) }

    #expect(failure(sbd, "rm-plan", args).contains("rm-plan needs scope done or work"))
  }

  @Test func rmPlanForWorkWithoutTargetsIsRefused() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    _ = try sbd.waitingSession(repo, branch: "haacked/waiting")

    #expect(failure(sbd, "rm-plan", ["scope": "work"]).contains("rm-plan with scope work needs targets"))
  }

  @Test(arguments: [.string("s1"), .array([.string("s1"), .number(2)])] as [JSON])
  func rmPlanRefusesTargetsThatAreNotAListOfIds(targets: JSON) throws {
    let sbd = try Instance()

    #expect(
      failure(sbd, "rm-plan", ["scope": "done", "targets": targets]).contains(
        "rm-plan needs targets as a list of session ids"))
  }

  /// An empty list plans nothing. It never stands for every Done session.
  @Test func rmPlanForDoneWithAnEmptyListPlansNothing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let done = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(done.id)

    let plan = try sbd.planRemoval([], scope: "done")

    #expect(planned(plan).isEmpty, Comment(rawValue: plan.text))
    #expect(plan["skip"]?.array?.isEmpty == true, Comment(rawValue: plan.text))
  }

  @Test func rmPlanPlansARepeatedTargetOnce() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let waiting = try sbd.waitingSession(repo, branch: "haacked/waiting")

    let plan = try sbd.planRemoval([waiting.id, waiting.id, "nope", "nope"], scope: "work")

    #expect(plan["remove"]?.array?.map { $0["id"]?.string } == [waiting.id], Comment(rawValue: plan.text))
    #expect(plan["skip"]?.array?.map { $0["id"]?.string } == ["nope"], Comment(rawValue: plan.text))
  }

  // MARK: rm-plan for Done matches rm-done's preview

  /// Each fixture session exercises a different rule: a clean Done session goes, one with uncommitted files and
  /// one with an open to-do fail rm's checks, and a session outside Done and the Manager marked Done stay out.
  @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
  func rmPlanForDoneWithoutTargetsMatchesRmDonesPreview(worktree: Bool, remoteBranch: Bool) throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    let dirty = try s.sbd.worktreeSession(s.repo, branch: "haacked/dirty")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    let held = try s.sbd.worktreeSession(s.repo, branch: "haacked/held")
    _ = try s.sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")
    let active = try s.sbd.worktreeSession(s.repo, branch: "haacked/active")
    let manager = try JSONCoding.decode(SessionSummary.self, from: s.sbd.sb("manager", "--json"))
    try s.pollUntilDone(merged)
    try s.sbd.markSessionDone(dirty.id)
    try s.sbd.markSessionDone(held.id)
    try s.sbd.markSessionDone(manager.id)
    #expect(try s.sbd.get(active.id).state != .done)

    let preview = try s.sbd.planDoneRemoval(worktree: worktree, remoteBranch: remoteBranch)
    let plan = try s.sbd.planRemoval(nil, scope: "done", worktree: worktree, remoteBranch: remoteBranch)

    let expected = sorted(try JSONCoding.decode(RemovalPlan.self, from: preview.text))
    let got = sorted(try JSONCoding.decode(RemovalPlan.self, from: plan.text))
    #expect(got == expected)
    #expect(expected.remove.map(\.id).contains(merged.id), Comment(rawValue: preview.text))
    #expect(expected.skip.map(\.id).contains(held.id), Comment(rawValue: preview.text))
    let listed = Set(expected.remove.map(\.id) + expected.skip.map(\.id))
    #expect(!listed.contains(active.id))
    #expect(!listed.contains(manager.id))
  }

  // MARK: Confirmation

  @Test func refusesInsideClaudeWithoutYes() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(s.id)

    let r = try sbd.rmDone("--worktree", env: ["CLAUDECODE": "1"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("--yes"), Comment(rawValue: r.stderr))
    #expect(!r.stderr.contains("without asking"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
  }

  /// runCommand gives sb /dev/null as stdin, which is not a terminal.
  @Test func refusesWithoutATerminalWithoutYes() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(s.id)

    let r = try sbd.rmDone("--worktree")

    #expect(r.status != 0)
    #expect(r.stderr.contains("without asking"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(s))
  }

  @Test func refusesASessionArgument() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let named = try sbd.worktreeSession(repo, branch: "haacked/named")
    let other = try sbd.worktreeSession(repo, branch: "haacked/other")
    try sbd.markSessionDone(named.id)
    try sbd.markSessionDone(other.id)

    let r = try sbd.run(["rm", named.id, "--done", "--worktree", "--yes"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("takes no session"), Comment(rawValue: r.stderr))
    #expect(try sbd.intact(named))
    #expect(try sbd.intact(other))
  }

  @Test func jsonWithoutYesPrintsThePreviewAndRemovesNothing() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED")
    let dirty = try s.sbd.worktreeSession(s.repo, branch: "haacked/dirty")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try s.pollUntilDone(merged)
    try s.sbd.markSessionDone(dirty.id)

    let r = try s.sbd.rmDone("--worktree", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let plan = try parse(r)
    #expect(plan["remove"]?.array != nil)
    #expect(plan["skip"]?.array != nil)
    #expect(planned(plan) == [merged.id])
    #expect(skip(plan["skip"], dirty.id)?["reason"]?.string?.contains("uncommitted") == true)
    #expect(try s.sbd.intact(merged))
    #expect(try s.sbd.intact(dirty))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
  }

  // MARK: The preview

  @Test func previewDescribesWhatEachRemovalDeletes() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    let closed = try s.finished(.cohort, state: "CLOSED", push: true)
    try s.pollUntilDone(merged, closed)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: true)

    let m = try #require(item(plan, merged.id))
    #expect(m["name"]?.string == merged.name)
    #expect(m["pr"]?.int == RemovalPR.breaker.number)
    #expect(m["worktree"]?.string == merged.cwd)
    #expect(m["branch"]?.string == RemovalPR.breaker.branch)
    #expect(m["remoteBranch"] == .bool(true))
    let c = try #require(item(plan, closed.id))
    #expect(c["pr"]?.int == RemovalPR.cohort.number)
    #expect(c["worktree"]?.string == closed.cwd)
    #expect(isNull(c["branch"]))
    #expect(c["remoteBranch"] == .bool(false))
  }

  @Test func previewOffersTheRemoteBranchOnlyWhenAsked() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: false)

    #expect(item(plan, merged.id)?["remoteBranch"] == .bool(false))
  }

  @Test func previewWithoutWorktreeListsNoWorktreeOrBranch() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let plan = try s.sbd.planDoneRemoval(worktree: false, remoteBranch: true)

    let m = try #require(item(plan, merged.id))
    #expect(isNull(m["worktree"]))
    #expect(isNull(m["branch"]))
    #expect(m["remoteBranch"] == .bool(false))
  }

  @Test func previewDecodesAsADoneRemovalPlan() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--json")

    let plan = try JSONCoding.decode(RemovalPlan.self, from: r.stdout)
    #expect(plan.remove.map(\.id) == [merged.id])
    #expect(plan.remove.first?.remoteBranch == true)
  }

  @Test func previewRemovesNothing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(s.id)

    _ = try sbd.planDoneRemoval()

    #expect(try sbd.intact(s))
    #expect(try sbd.localBranch(repo, "haacked/done"))
  }

  // MARK: The confirmed op

  @Test func confirmedRemovalSkipsATargetThatLeftDoneAndRemovesTheOthers() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let left = try sbd.worktreeSession(repo, branch: "haacked/left")
    let stays = try sbd.worktreeSession(repo, branch: "haacked/stays")
    try sbd.markSessionDone(left.id)
    try sbd.markSessionDone(stays.id)
    #expect(planned(try sbd.planDoneRemoval()) == [left.id, stays.id])
    try sbd.sb("undone", left.id)
    try sbd.waitFor(left.id, "not Done") { $0.state != .done }

    let result = try sbd.removeDone([left.id, stays.id])

    #expect(removed(result) == [stays.id])
    let reason = try #require(skip(result["skipped"], left.id)?["reason"]?.string)
    #expect(reason.lowercased().contains("done"), Comment(rawValue: reason))
    #expect(try sbd.intact(left))
    #expect(!FileManager.default.fileExists(atPath: stays.cwd))
  }

  /// The confirmed op runs rm's checks again, so a change after the preview skips that target.
  @Test func confirmedRemovalSkipsATargetThatFailsACheckAfterThePreviewAndRemovesTheOthers() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let failing = try sbd.worktreeSession(repo, branch: "haacked/failing")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(failing.id)
    try sbd.markSessionDone(clean.id)
    #expect(planned(try sbd.planDoneRemoval()) == [failing.id, clean.id])
    try "x".write(toFile: "\(failing.cwd)/notes.txt", atomically: true, encoding: .utf8)

    let result = try sbd.removeDone([failing.id, clean.id])

    let reason = try #require(skip(result["skipped"], failing.id)?["reason"]?.string)
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    #expect(removed(result) == [clean.id])
    #expect(FileManager.default.fileExists(atPath: "\(failing.cwd)/notes.txt"))
    #expect(try sbd.listedIds() == [failing.id])
  }

  @Test func confirmedRemovalSkipsATargetThatNamesNoSession() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/done")
    try sbd.markSessionDone(s.id)

    let result = try sbd.removeDone(["snope1", s.id])

    #expect(removed(result) == [s.id])
    #expect(skip(result["skipped"], "snope1")?["reason"]?.string?.isEmpty == false)
  }

  @Test func confirmedRemovalAccountsForEveryTarget() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let active = try sbd.worktreeSession(repo, branch: "haacked/active")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try sbd.markSessionDone(clean.id)
    try sbd.markSessionDone(dirty.id)
    let targets = [clean.id, dirty.id, active.id]

    let result = try sbd.removeDone(targets)

    let skipped = Set(result["skipped"]?.array?.compactMap { $0["id"]?.string } ?? [])
    #expect(removed(result).union(skipped) == Set(targets))
    #expect(removed(result).isDisjoint(with: skipped))
  }

  // MARK: To-dos

  /// Without --worktree, rm skips its worktree checks. The to-do check must still run.
  @Test(arguments: [true, false])
  func previewSkipsASessionWithAnOpenToDoAndNamesTheToDo(worktree: Bool) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(held.id)
    try sbd.markSessionDone(clean.id)
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let plan = try sbd.planDoneRemoval(worktree: worktree)

    #expect(planned(plan) == [clean.id])
    let reason = try #require(skip(plan["skip"], held.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(
      reason.contains("\(held.name) has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
    #expect(try sbd.intact(held))
  }

  @Test(arguments: [true, false])
  func confirmedRemovalSkipsATargetWhoseToDoWasAddedAfterThePreview(worktree: Bool) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(held.id)
    try sbd.markSessionDone(clean.id)
    #expect(planned(try sbd.planDoneRemoval(worktree: worktree)) == [held.id, clean.id])
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let result = try sbd.removeDone([held.id, clean.id], worktree: worktree)

    #expect(removed(result) == [clean.id])
    let reason = try #require(skip(result["skipped"], held.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(
      reason.contains("has an open to-do: \(todo.id) \"tell Alex in #flags that the fix shipped\""),
      Comment(rawValue: reason))
    #expect(try sbd.intact(held))
    #expect(try sbd.isOpenTodo(held.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  // MARK: Removal from inside a session

  /// sb runs below a's shell pane, so removing a's worktree would stop sb's own parents. The preview skips a with
  /// rm's refusal, and the confirmed run removes b and leaves a and its claude running.
  @Test func rmDoneSkipsTheCallersOwnSession() throws {
    let s = try MergedPRRepo()
    let a = try s.finished(.breaker, state: "MERGED")
    let b = try s.finished(.groups, state: "MERGED")
    // The shell pane starts before a is Done, so it can't change a's state.
    let terminals = try s.sbd.client.terminals(a.id)
    let claude = try #require(try s.sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    try s.pollUntilDone(a, b)
    // The preview reads the installed snapshot. A tick installs one that holds the shell pane's pid.
    try s.sbd.advanceClock(1)
    try s.sbd.writeSbScript("preview", ["rm", "--done", "--worktree", "--json"])
    try s.sbd.writeSbScript("confirmed", ["rm", "--done", "--worktree", "--yes", "--json"])
    let refusal = insideRefusal("sb rm --worktree", a.id)

    try s.sbd.typeInShell(terminals, "sh \"$SB_HOME/preview.sh\"")
    let preview = try s.sbd.scriptResult("preview")
    try s.sbd.typeInShell(terminals, "sh \"$SB_HOME/confirmed.sh\"")
    let confirmed = try s.sbd.scriptResult("confirmed")

    #expect(preview.status == 0, Comment(rawValue: preview.stderr))
    let plan = try parse(preview)
    #expect(planned(plan) == [b.id])
    let planReason = try #require(skip(plan["skip"], a.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(planReason.contains(refusal), Comment(rawValue: planReason))
    let result = try parse(confirmed)
    #expect(removed(result) == [b.id])
    let reason = try #require(skip(result["skipped"], a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(refusal), Comment(rawValue: reason))
    #expect(try s.sbd.listedIds() == [a.id])
    #expect(FileManager.default.fileExists(atPath: a.cwd))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(Processes.exists(claude), "sbd ended a's claude")
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.groups.branch))
  }

  /// sb sends only the preview's `remove` as targets, so a perl client in a's shell pane sends the confirmed op
  /// with a as a target. The confirmed op must skip a with the refusal that the preview gives.
  @Test func confirmedRmDoneFromInsideASessionSkipsThatSessionAsATarget() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/inside")
    let terminals = try sbd.client.terminals(a.id)
    let claude = try #require(try sbd.waitFor(a.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    try sbd.markSessionDone(a.id)
    // A tick installs a snapshot that holds the shell pane's pid, so `doneTarget` skips a before `rm` runs.
    try sbd.advanceClock(1)
    let request: JSON = [
      "op": "rm-done", "args": ["worktree": true, "confirmed": true, "targets": .array([.string(a.id)])],
    ]
    let client = [
      #"$s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";"#,
      #"print $s "$ARGV[1]\n";"#,
      "print scalar <$s>",
    ].joined(separator: " ")
    try sbd.writeScript(
      "confirmed",
      "perl -MIO::Socket::UNIX -e \(shellQuote(client)) \"$SB_HOME/sbd.sock\" \(shellQuote(request.text))")

    try sbd.typeInShell(terminals, "sh \"$SB_HOME/confirmed.sh\"")
    let r = try sbd.scriptResult("confirmed")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let response = try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    let result = try #require(response["result"], Comment(rawValue: response.text))
    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], a.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(insideRefusal("sb rm --worktree", a.id)), Comment(rawValue: reason))
    #expect(try sbd.intact(a))
    #expect(try sbd.localBranch(repo, "haacked/inside"))
    #expect(Processes.exists(claude), "sbd ended a's claude")
  }

  // MARK: The removal job

  /// The CLI hands every planned session to sbd's removal job in one `rm-queue`, so while the worker holds the
  /// first one, the others are already queued and the command still waits. The uncommitted file appears after the
  /// plan, so only the job's own checks find it, and the command reports that failure as skipped.
  @Test func waitsForTheJobAndReportsWhatItRemovedAndWhatFailedAsJSON() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    for s in [dirty, a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes", "--json")
    try sbd.waitForJob([dirty.id, a.id, b.id], while: command)
    #expect(command.result == nil, "sb rm --done returned while the job still held its sessions")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try sbd.release(holdRemoval)
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(Set(result.removed) == [a.id, b.id], Comment(rawValue: r.stdout))
    let reason = try #require(result.skipped.first { $0.id == dirty.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    #expect(result.partial.isEmpty, Comment(rawValue: r.stdout))
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: b.cwd))
    #expect(try sbd.intact(dirty))
    #expect(try sbd.removalState(dirty.id) == nil, "sb rm --done did not keep the session whose removal failed")
  }

  @Test func waitsForTheJobAndReportsWhatItRemovedAndWhatFailedAsText() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    for s in [dirty, a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes")
    try sbd.waitForJob([dirty.id, a.id, b.id], while: command)
    #expect(command.result == nil, "sb rm --done returned while the job still held its sessions")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    try sbd.release(holdRemoval)
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let lines = r.stdout.split(separator: "\n").map(String.init)
    #expect(lines.first == "removed 2, skipped 1", Comment(rawValue: r.stdout))
    let skipLine = try #require(
      lines.first { $0.hasPrefix("  skipped \(dirty.id)  \(dirty.name): ") }, Comment(rawValue: r.stdout))
    #expect(skipLine.contains("uncommitted"), Comment(rawValue: skipLine))
    #expect(try sbd.listedIds() == [dirty.id])
    #expect(try sbd.removalState(dirty.id) == nil, "sb rm --done did not keep the session whose removal failed")
  }

  /// launchd may restart sbd while the command waits. The job resumes after the restart, and the command waits
  /// through the restart until the job ends.
  @Test func waitsThroughARestartOfSbd() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    for s in [a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes", "--json")
    try sbd.waitForJob([a.id, b.id], while: command)
    sbd.killSbd()
    try sbd.release(holdRemoval)
    try sbd.startSbd()
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(Set(result.removed) == [a.id, b.id], Comment(rawValue: r.stdout))
    #expect(result.skipped.isEmpty, Comment(rawValue: r.stdout))
  }

  /// A to-do arrives after git dropped the worktree's record, so the removal fails with `released` set and Keep can't
  /// move the folder back. The command sends no `rm-keep` and says to retry the delete.
  @Test func reportsAFailureAfterGitDroppedTheWorktreeWithoutKeepingIt() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.markSessionDone(a.id)
    sbd.hold(holdReleased)
    defer { try? sbd.release(holdReleased) }

    let command = sbd.startRmDone("--worktree", "--yes", "--json")
    _ = try sbd.waitFor("\(a.id)'s removal to record released", timeout: 60, fetch: { try sbd.removal(a.id) }) {
      $0["released"]?.bool == true
    }
    try sbd.addTodo(a.id, "close the incident")
    try sbd.release(holdReleased)
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    let reason = try #require(result.skipped.first { $0.id == a.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains("retry the delete in the Inbox"), Comment(rawValue: reason))
    #expect(!reason.contains("Keep failed") && !reason.contains("Kept in Done"), Comment(rawValue: reason))
    #expect(try sbd.removalState(a.id) == "failed")
  }

  /// The app's Undo cancels a session while the command waits out the delay. The command reports it as skipped and
  /// sends no `rm-keep`, because the session is already back in Done with no removal.
  @Test func reportsASessionThatUndoBringsBackAsSkipped() throws {
    let sbd = try Instance(idleStopSeconds: 3600, config: ["removalDelaySeconds": 600])
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    for s in [a, b] { try sbd.markSessionDone(s.id) }

    let command = sbd.startRmDone("--worktree", "--yes", "--json")
    try sbd.waitFor("the removal job to queue a and b", timeout: 30) {
      if command.result != nil { throw TestError(description: "sb rm --done ended before the delay passed") }
      return try sbd.removalState(a.id) == "queued" && sbd.removalState(b.id) == "queued"
    }
    let cancel = try sbd.client.call("rm-cancel", ["sessions": [.string(a.id)]])
    #expect(cancel["cancelled"]?.array?.compactMap(\.string) == [a.id], Comment(rawValue: cancel.text))
    try sbd.advanceClock(601_000)
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(result.removed == [b.id], Comment(rawValue: r.stdout))
    let reason = try #require(result.skipped.first { $0.id == a.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains("no longer being deleted"), Comment(rawValue: reason))
    #expect(!reason.contains("Keep failed"), Comment(rawValue: reason))
    #expect(try sbd.intact(a))
    #expect(try sbd.removal(a.id) == nil)
    #expect(try sbd.get(a.id).state == .done)
  }

  /// The remote branch moved after the merge, so the job forgets the session, keeps the remote branch, and records
  /// a removal notice. The command reports that notice as a partial removal, as `rm` reported its error before.
  @Test(arguments: [true, false])
  func reportsARemovalNoticeFromTheJobAsPartial(json: Bool) throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    let other = "\(s.sbd.home.path)/other"
    try s.sbd.git(s.sbd.home.path, "clone", "-q", s.origin, other)
    try s.sbd.git(other, "checkout", "-q", RemovalPR.breaker.branch)
    try s.sbd.commit(other, "later.txt")
    try s.sbd.git(other, "push", "-q", "origin", RemovalPR.breaker.branch)
    s.sbd.hold(holdRemoval)
    defer { try? s.sbd.release(holdRemoval) }

    let flags = ["--worktree", "--delete-remote-branch", "--yes"] + (json ? ["--json"] : [])
    let command = Outcome.detached { try s.sbd.run(["rm", "--done"] + flags) }
    try s.sbd.waitForJob([merged.id], while: command)
    try s.sbd.release(holdRemoval)
    let r = try s.sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    if json {
      let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
      #expect(result.removed == [merged.id], Comment(rawValue: r.stdout))
      let reason = try #require(result.partial.first { $0.id == merged.id }?.reason, Comment(rawValue: r.stdout))
      #expect(reason.contains("kept the remote branch"), Comment(rawValue: reason))
      #expect(result.skipped.isEmpty, Comment(rawValue: r.stdout))
    } else {
      let lines = r.stdout.split(separator: "\n").map(String.init)
      #expect(lines.first == "removed 1, skipped 0", Comment(rawValue: r.stdout))
      let partial = try #require(
        lines.first { $0.hasPrefix("  \(merged.id)  \(merged.name): ") }, Comment(rawValue: r.stdout))
      #expect(partial.contains("kept the remote branch"), Comment(rawValue: partial))
    }
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
    #expect(try s.sbd.noticeSessions().isEmpty, "sb rm --done did not dismiss the notice it reported")
  }

  /// A notice stays until someone dismisses it, so a notice from an earlier removal is still listed when the command
  /// runs. Only the notices about the command's own sessions are its partial removals.
  @Test func aRemovalNoticeFromAnEarlierRemovalIsNotReportedAsPartial() throws {
    let s = try MergedPRRepo()
    let earlier = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(earlier)
    let other = "\(s.sbd.home.path)/other"
    try s.sbd.git(s.sbd.home.path, "clone", "-q", s.origin, other)
    try s.sbd.git(other, "checkout", "-q", RemovalPR.breaker.branch)
    try s.sbd.commit(other, "later.txt")
    try s.sbd.git(other, "push", "-q", "origin", RemovalPR.breaker.branch)
    #expect(queued(try s.sbd.queueRemoval([earlier.id], remoteBranch: true)) == [earlier.id])
    try s.sbd.waitUntilGone(earlier.id)
    try s.sbd.waitFor("the earlier removal's notice") { try s.sbd.noticeSessions().contains(earlier.id) }
    let plain = try s.sbd.worktreeSession(s.repo, branch: "haacked/plain")
    try s.sbd.markSessionDone(plain.id)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(result.removed == [plain.id], Comment(rawValue: r.stdout))
    #expect(result.partial.isEmpty, Comment(rawValue: r.stdout))
    #expect(try s.sbd.noticeSessions() == [earlier.id], "sb rm --done dismissed a notice it did not report")
  }

  // MARK: --no-wait

  /// The dirty session fails the plan's checks, so the command never queues it and lists it with the sessions that
  /// `rm-queue` skipped.
  @Test func noWaitPrintsTheQueuedIdsAsJSONAndReturnsWhileTheJobHoldsThem() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    for s in [dirty, a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes", "--no-wait", "--json")
    let returned = command.done.wait(timeout: .now() + 20) == .success

    #expect(returned, "sb rm --done --no-wait waited for the job")
    let r = try #require(try command.result?.get())
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalQueued.self, from: r.stdout)
    #expect(Set(result.queued) == [a.id, b.id], Comment(rawValue: r.stdout))
    let reason = try #require(result.skipped.first { $0.id == dirty.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    for s in [a, b] {
      let state = try sbd.removalState(s.id)
      #expect(state == "queued" || state == "running", "\(s.id)'s removal is \(state ?? "missing")")
    }
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(a.id, b.id)
    #expect(try sbd.intact(dirty))
  }

  @Test func noWaitPrintsTheQueuedIdsAsTextAndReturnsWhileTheJobHoldsThem() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let dirty = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    try "x".write(toFile: "\(dirty.cwd)/notes.txt", atomically: true, encoding: .utf8)
    for s in [dirty, a, b] { try sbd.markSessionDone(s.id) }
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes", "--no-wait")
    let returned = command.done.wait(timeout: .now() + 20) == .success

    #expect(returned, "sb rm --done --no-wait waited for the job")
    let r = try #require(try command.result?.get())
    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let lines = r.stdout.split(separator: "\n").map(String.init)
    #expect(lines.first == "queued 2, skipped 1", Comment(rawValue: r.stdout))
    for s in [a, b] {
      #expect(lines.contains { $0.hasPrefix("  \(s.id)  \(s.name)") }, Comment(rawValue: r.stdout))
    }
    let skipLine = try #require(
      lines.first { $0.hasPrefix("  skipped \(dirty.id)  \(dirty.name): ") }, Comment(rawValue: r.stdout))
    #expect(skipLine.contains("uncommitted"), Comment(rawValue: skipLine))
    #expect(try sbd.removalState(a.id) != nil)
    #expect(try sbd.removalState(b.id) != nil)
  }

  // MARK: To-dos through the job

  /// The plan names no to-do for the command to resolve, so a Done session with an open to-do is skipped and its
  /// to-do stays open.
  @Test func skipsADoneSessionWithAnOpenToDoAndLeavesTheToDoOpen() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(held.id)
    try sbd.markSessionDone(clean.id)
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(result.removed == [clean.id], Comment(rawValue: r.stdout))
    let reason = try #require(result.skipped.first { $0.id == held.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains("has an open to-do: \(todo.id)"), Comment(rawValue: reason))
    #expect(try sbd.intact(held))
    #expect(try sbd.isOpenTodo(held.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }

  /// The to-do arrives after the command queued the session, so the job's own to-do check keeps the session, and
  /// the command reports that failure as skipped.
  @Test func aToDoAddedWhileTheJobHoldsTheSessionKeepsItAndIsReportedAsSkipped() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let held = try sbd.worktreeSession(repo, branch: "haacked/held")
    let clean = try sbd.worktreeSession(repo, branch: "haacked/clean")
    try sbd.markSessionDone(held.id)
    try sbd.markSessionDone(clean.id)
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }

    let command = sbd.startRmDone("--worktree", "--yes", "--json")
    try sbd.waitForJob([held.id, clean.id], while: command)
    let todo = try sbd.addTodo(held.id, "tell Alex in #flags that the fix shipped")
    try sbd.release(holdRemoval)
    let r = try sbd.finish(command)

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let result = try JSONCoding.decode(RemovalResult.self, from: r.stdout)
    #expect(result.removed == [clean.id], Comment(rawValue: r.stdout))
    let reason = try #require(result.skipped.first { $0.id == held.id }?.reason, Comment(rawValue: r.stdout))
    #expect(reason.contains(todo.id), Comment(rawValue: reason))
    #expect(try sbd.intact(held))
    #expect(try sbd.isOpenTodo(held.id, todo.id))
    #expect(try sbd.resolvedTodos().isEmpty)
  }
}

// MARK: - Worktrees that Supacode locked

private func calls(_ log: String) -> [String] {
  ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Suite(.blocking(timeLimit: .seconds(120))) struct SupacodeLockTests {
  @Test func deleteAllRemovesAWorktreeThatSupacodeLockedThroughSupacode() throws {
    let s = try MergedPRRepo()
    let kept = try s.finished(.breaker, state: "MERGED")
    let inMain = try s.finished(.groups, state: "MERGED")
    // origin/main contains the second branch's tip, as after a merge commit. The first is like a squash merge.
    try s.sbd.git(inMain.cwd, "push", "-q", "origin", "HEAD:main")
    try s.sbd.git(s.repo, "fetch", "-q", "origin")
    try s.pollUntilDone(kept, inMain)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, kept.cwd)
    try s.sbd.lockForSupacode(s.repo, inMain.cwd)

    let plan = try s.sbd.planDoneRemoval()
    #expect(planned(plan) == [kept.id, inMain.id], Comment(rawValue: plan.text))
    #expect(isNull(item(plan, kept.id)?["branch"]))
    #expect(item(plan, inMain.id)?["branch"]?.string == RemovalPR.groups.branch)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [kept.id, inMain.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.client.sessions().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: kept.cwd))
    #expect(!FileManager.default.fileExists(atPath: inMain.cwd))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.groups.branch))
    let made = calls(log)
    #expect(made.count == 2, Comment(rawValue: made.joined(separator: "\n")))
    for call in made {
      #expect(call.hasPrefix("worktree delete --worktree %2F"), Comment(rawValue: call))
      #expect(call.hasSuffix("%2F --background"), Comment(rawValue: call))
      #expect(!call.contains("/"), Comment(rawValue: call))
    }
  }

  @Test func skipsAWorktreeThatSupacodeLockedWhenSupacodeFails() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markSessionDone(s.id)
    _ = try sbd.useSupacodeStub(failing: true)
    try sbd.lockForSupacode(repo, s.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("Supacode is not running"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
    #expect(try sbd.git(repo, "worktree", "list", "--porcelain").contains("supacode"))
  }

  @Test func skipsAWorktreeThatSupacodeSaysItDeletedWhenGitStillListsIt() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markSessionDone(s.id)
    _ = try sbd.useSupacodeStub(removes: false)
    try sbd.lockForSupacode(repo, s.cwd)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("still lists"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
  }

  @Test func skipsAWorktreeThatSupacodeLockedWhenSupacodeIsMissing() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/locked")
    try sbd.markSessionDone(s.id)
    try sbd.restart(setting: "supacode", to: .string("\(sbd.home.path)/no-such-supacode"))
    try sbd.lockForSupacode(repo, s.cwd)

    let plan = try sbd.planDoneRemoval()

    let reason = try #require(skip(plan["skip"], s.id)?["reason"]?.string, Comment(rawValue: plan.text))
    #expect(reason.contains("can't find"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
  }

  @Test func skipsAWorktreeThatSupacodeLockedWithUncommittedFilesWithoutCallingSupacode() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let s = try sbd.worktreeSession(repo, branch: "haacked/dirty")
    try sbd.markSessionDone(s.id)
    let log = try sbd.useSupacodeStub()
    try sbd.lockForSupacode(repo, s.cwd)
    try "draft".write(toFile: "\(s.cwd)/draft.txt", atomically: true, encoding: .utf8)

    let result = try parse(try sbd.rmDone("--worktree", "--yes", "--json"))

    let reason = try #require(skip(result["skipped"], s.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("uncommitted"), Comment(rawValue: reason))
    #expect(try sbd.intact(s))
    #expect(calls(log).isEmpty)
  }

  @Test func cleanupRefusesAWorktreeThatSupacodeLockedWhenItsMergedPRIsFromAnotherRepo() throws {
    let s = try MergedPRRepo()
    let session = try s.sbd.worktreeSession(s.repo, branch: "haacked/no-pr-yet")
    try s.sbd.link(session, "haacked/review-code", 189)
    s.github.change(189) { $0["state"] = "MERGED" }
    try s.pollUntilDone(session)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("has no merged PR"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(calls(log).isEmpty)
  }

  @Test func rmDoneSkipsAWorktreeThatSupacodeLockedWhenItsMergedPRIsFromAnotherRepo() throws {
    let s = try MergedPRRepo()
    let session = try s.sbd.worktreeSession(s.repo, branch: "haacked/no-pr-yet")
    try s.sbd.link(session, "haacked/review-code", 189)
    s.github.change(189) { $0["state"] = "MERGED" }
    try s.pollUntilDone(session)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let result = try parse(try s.sbd.rmDone("--worktree", "--yes", "--json"))

    #expect(removed(result).isEmpty)
    let reason = try #require(skip(result["skipped"], session.id)?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains("has no merged PR"), Comment(rawValue: reason))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(calls(log).isEmpty)
  }

  @Test func cleanupRemovesAWorktreeThatSupacodeLockedAndKeepsTheSession() throws {
    let s = try MergedPRRepo()
    let session = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(session)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(!FileManager.default.fileExists(atPath: session.cwd))
    #expect(try s.sbd.client.sessions().map(\.id) == [session.id])
    #expect(calls(log).count == 1)
    // origin/main doesn't contain the branch's tip, so the branch stays.
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    let kept = try s.sbd.waitFor(session.id, "the kept branch in the reason") {
      $0.reason.contains("kept \(RemovalPR.breaker.branch)")
    }
    #expect(kept.state == .done)
  }

  /// Supacode deletes the branch with the worktree, and the commit after the merge is only on that branch.
  @Test func keepsABranchWithACommitAfterTheMergeThatSupacodeDeleted() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED")
    try s.pollUntilDone(merged)
    try s.sbd.commit(merged.cwd, "later.txt")
    try s.sbd.markSessionDone(merged.id)
    let tip = try s.sbd.git(merged.cwd, "rev-parse", "HEAD")
    try s.sbd.git(s.repo, "config", "branch.\(RemovalPR.breaker.branch).remote", "origin")
    _ = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, merged.cwd)

    let r = try s.sbd.rmDone("--worktree", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(RemovalPR.breaker.branch)") == tip)
    #expect(try s.sbd.git(s.repo, "config", "branch.\(RemovalPR.breaker.branch).remote") == "origin")
  }

  /// The plan keeps the squash-merged branch, so the remote branch stays too.
  @Test func keepsTheRemoteBranchOfABranchThatTheSupacodePathKeeps() throws {
    let s = try MergedPRRepo()
    let merged = try s.finished(.breaker, state: "MERGED", push: true)
    try s.pollUntilDone(merged)
    _ = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, merged.cwd)

    let plan = try s.sbd.planDoneRemoval(remoteBranch: true)
    #expect(item(plan, merged.id)?["remoteBranch"] == .bool(false), Comment(rawValue: plan.text))

    let r = try s.sbd.rmDone("--worktree", "--delete-remote-branch", "--yes", "--json")

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    #expect(removed(try parse(r)) == [merged.id], Comment(rawValue: r.stdout))
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try s.sbd.localBranch(s.origin, RemovalPR.breaker.branch))
  }

  @Test func cleanupRefusesAWorktreeThatSupacodeLockedWhenItsMergedPRUsesAnotherBranch() throws {
    let s = try MergedPRRepo()
    let (session, v2, tip) = try s.doneOnV2(.breaker, sessionOnV2: true)
    let log = try s.sbd.useSupacodeStub()
    try s.sbd.lockForSupacode(s.repo, session.cwd)

    let r = try s.sbd.run(["cleanup", session.id, "--json"])

    #expect(r.status != 0)
    #expect(r.stderr.contains("has no merged PR"), Comment(rawValue: r.stderr))
    #expect(FileManager.default.fileExists(atPath: session.cwd))
    #expect(calls(log).isEmpty)
    #expect(try s.sbd.git(s.repo, "rev-parse", "refs/heads/\(v2)") == tip)
  }
}
