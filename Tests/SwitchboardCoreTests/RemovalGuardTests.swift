import Foundation
import Testing

@testable import SwitchboardCore

/// `RemovalGuard.check` decides whether an `rm` or `rm-worktree` action removes its subject now. Each test breaks one
/// part of an input that removes.
@Suite struct RemovalGuardTests {
  static func removable(worktree: Bool = true) -> RemovalGuard.Input {
    RemovalGuard.Input(
      name: "fix-cache", exists: true, busy: false, host: nil, worktree: worktree, pr: samplePR(state: .merged),
      turnRunning: false, messageWaiting: false)
  }

  static func check(worktree: Bool = true, _ edit: (inout RemovalGuard.Input) -> Void) -> RemovalGuard.Verdict {
    var input = removable(worktree: worktree)
    edit(&input)
    return RemovalGuard.check(input)
  }

  static func holds(_ verdict: RemovalGuard.Verdict) -> Bool {
    if case .hold = verdict { return true }
    return false
  }

  static func asks(_ verdict: RemovalGuard.Verdict) -> Bool {
    if case .judgment = verdict { return true }
    return false
  }

  @Test(arguments: [true, false])
  func aMergedIdleSessionIsRemoved(_ worktree: Bool) {
    #expect(RemovalGuard.check(Self.removable(worktree: worktree)) == .remove)
  }

  @Test(arguments: [true, false])
  func aSessionThatIsGoneIsDone(_ worktree: Bool) {
    #expect(Self.check(worktree: worktree) { $0.exists = false } == .gone)
  }

  /// The removal job holds the session, `rm` removes it, or a start or a merge runs on it.
  @Test(arguments: [true, false])
  func aBusySessionHolds(_ worktree: Bool) {
    #expect(Self.holds(Self.check(worktree: worktree) { $0.busy = true }))
  }

  @Test(arguments: [true, false])
  func aSessionOnAHostAsksForJudgment(_ worktree: Bool) {
    #expect(Self.asks(Self.check(worktree: worktree) { $0.host = "mini" }))
  }

  @Test func aWorktreeWithoutAPRAsksForJudgment() {
    #expect(Self.asks(Self.check { $0.pr = nil }))
  }

  @Test(arguments: [PRState.open, .closed])
  func aWorktreeWhosePRDidNotMergeAsksForJudgment(_ state: PRState) {
    #expect(Self.asks(Self.check { $0.pr = samplePR(state: state) }))
  }

  /// `rm` keeps the folder, so it needs no merged PR.
  @Test(arguments: [nil, samplePR(state: .closed)] as [PullRequest?])
  func rmNeedsNoMergedPR(_ pr: PullRequest?) {
    #expect(Self.check(worktree: false) { $0.pr = pr } == .remove)
  }

  @Test(arguments: [true, false])
  func aRunningTurnHolds(_ worktree: Bool) {
    #expect(Self.holds(Self.check(worktree: worktree) { $0.turnRunning = true }))
  }

  /// A message on its way, such as the merge's post-merge message, starts a turn that `remove` would stop.
  @Test(arguments: [true, false])
  func aMessageOnItsWayHolds(_ worktree: Bool) {
    #expect(Self.holds(Self.check(worktree: worktree) { $0.messageWaiting = true }))
  }

  /// A busy session holds before anything asks the holder.
  @Test func busyComesBeforeTheMergedPRCheck() {
    #expect(
      Self.holds(
        Self.check {
          $0.busy = true
          $0.pr = nil
        }))
  }
}
