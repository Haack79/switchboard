import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct DeletingDoneSessions {
  func done(
    repo: String? = "/repos/posthog", branch: String? = "haacked/fix", pr: PRState? = .merged,
    state: AttentionState = .done, manager: Bool? = nil
  ) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "fix", cwd: "/worktrees/posthog/haacked/fix", repo: repo, branch: branch, claudeSessionId: "c",
      state: state, reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false,
      lastReply: nil, waits: [], notes: [])
    s.manager = manager
    s.kind = SessionKind(manager: manager, chat: nil)
    if let pr {
      s.pr = try! JSONDecoder().decode(
        PRSummary.self,
        from: Data(
          """
          {"number":7,"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"Fix","state":"\(pr.rawValue)","status":"\(pr == .merged ? "Merged" : "Closed")"}
          """.utf8))
    }
    return s
  }

  @Test func offersTheIconOnADoneSession() {
    #expect(done().isRemovableDone)
  }

  @Test func neverOffersTheIconOnTheManager() {
    #expect(!done(manager: true).isRemovableDone)
  }

  @Test func neverOffersTheIconOnAFollowupThatHasNotStarted() {
    var s = done()
    s.followup = Followup(prompt: "p")
    #expect(!s.isRemovableDone)
  }

  @Test func neverOffersTheIconOutsideTheDoneColumn() {
    for state in AttentionState.allCases where state != .done {
      #expect(!done(state: state).isRemovableDone)
    }
  }

  /// sbd adds the branch and the remote branch when the PR merged, and leaves out the worktree of a session
  /// that it made no worktree for.
  @Test func queuesTheSessionWithTheWorktreeAndTheRemoteBranch() {
    let request = BoardModel.queueRequest(["s1"], scope: .done)
    #expect(request == ["scope": "done", "targets": ["s1"], "worktree": true, "remote_branch": true])
  }

  @Test func keepsTheBranchWhenThePRIsNotMerged() {
    #expect(BoardModel.deletePlan(done(pr: .closed)).branch == nil)
    #expect(BoardModel.deletePlan(done(pr: nil)).branch == nil)
  }

  @Test func removesOnlyTheSessionWhenSbdMadeNoWorktree() {
    let plan = BoardModel.deletePlan(done(repo: nil, branch: nil))
    #expect(plan.worktree == nil)
    #expect(plan.branch == nil)
  }

  @Test func namesEverythingItDeletesInTheConfirmation() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("the session fix"))
    #expect(text.contains("/worktrees/posthog/haacked/fix"))
    #expect(text.contains("local branch haacked/fix"))
    #expect(text.contains("remote branch haacked/fix"))
    #expect(text.contains("only if it is still at the merged PR's head"))
  }

  @Test func saysThatTheBranchStaysWhenThePRIsNotMerged() {
    let text = BoardModel.deletePlan(done(pr: .closed)).message
    #expect(!text.contains("the remote branch haacked/fix"))
    #expect(text.contains("The branch stays"))
  }

  @Test func namesTheRefusalsInTheConfirmation() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("uncommitted files"))
    #expect(text.contains("checked out in another worktree"))
    #expect(text.contains("A refusal before anything stops deletes nothing"))
  }

  @Test func saysThatTheSessionAndWorktreeGoEvenWhenTheBranchCheckFails() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("fails its check after the worktree is gone"))
  }

  @Test func ignoresASecondDeleteWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      let session = done()
      model.deleteDone(session)
      model.deleteDone(session)
      #expect(model.deleting == [session.id])
    }
    #expect(sent.count == 1)
  }

  @Test func labelsTheIconWithWhatItRemoves() {
    #expect(BoardModel.deletePlan(done()).summary == "the session, its worktree, and its branch")
    #expect(BoardModel.deletePlan(done(pr: .closed)).summary == "the session and its worktree")
    #expect(BoardModel.deletePlan(done(repo: nil, branch: nil)).summary == "the session")
  }
}
