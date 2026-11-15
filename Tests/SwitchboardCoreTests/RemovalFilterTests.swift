import Foundation
import Testing

@testable import SwitchboardCore

/// The app hides a session while sbd's removal job holds it, and shows it again once the removal fails.
@Suite struct RemovalFilterTests {
  /// A session with a removal in `state`, or with no removal when `state` is nil.
  static func summary(removal state: Removal.State?) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "s", cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: "c1", state: .done, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.removal = state.map { state in
      var removal = Removal(requested: 1, notBefore: 1, worktree: true, branch: false, remoteBranch: false, resolve: [])
      removal.state = state
      if state == .failed { removal.error = "/tmp has uncommitted files (1)." }
      return removal
    }
    return s
  }

  @Test(arguments: [Removal.State.queued, .running])
  func aSessionThatTheJobHoldsIsBeingRemoved(_ state: Removal.State) {
    #expect(Self.summary(removal: state).isBeingRemoved)
  }

  @Test func aSessionWhoseRemovalFailedIsNotBeingRemoved() {
    #expect(!Self.summary(removal: .failed).isBeingRemoved)
  }

  @Test func aSessionWithNoRemovalIsNotBeingRemoved() {
    #expect(!Self.summary(removal: nil).isBeingRemoved)
  }

  /// `ls --json` carries the removal, so the filter must read a decoded summary the same way.
  @Test(arguments: [("queued", true), ("running", true), ("failed", false)])
  func aDecodedRemovalGivesTheSameAnswer(_ state: String, _ held: Bool) throws {
    var json = try JSON(encoding: Self.summary(removal: nil))
    guard case .object(var object) = json else {
      Issue.record("a summary did not encode as an object")
      return
    }
    object["removal"] = [
      "state": .string(state), "requested": 1, "notBefore": 1, "worktree": true, "branch": false,
      "remoteBranch": false, "released": false, "resolve": [],
    ]
    json = .object(object)

    let s = try JSONCoding.decode(SessionSummary.self, from: json.text)

    #expect(s.isBeingRemoved == held)
  }
}
