import Foundation
import Testing

@testable import SwitchboardCore

/// The one place that builds a `Pause`, so that the tests follow its initializer.
func pauseOf(
  by: Author = .you, from: Pause.Pauser? = nil, reason: String? = nil, since: Int64 = 1_000, until: Wait? = nil,
  message: String? = nil
) -> Pause {
  Pause(by: by, from: from, reason: reason, since: since, until: until, message: message)
}

let managerPauser = Pause.Pauser(id: "m1", name: "Manager", kind: .manager)
/// A chat's pauser names its group.
let flagsChatPauser = Pause.Pauser(id: "c1", name: "Flags", kind: .chat)
let workPauser = Pause.Pauser(id: "k3x9p", name: "flag-cache", kind: .work)

/// `session()` with the pause.
func pausedSession(_ pause: Pause = pauseOf(), done: Bool = false, waits: [Wait]? = nil) -> Session {
  var s = session(done: done)
  s.waits = waits
  s.pause = pause
  return s
}

private let mergeCondition = Wait(id: "w9", kind: .merge, pr: Wait.PullRequest(number: 123), created: 0)
private let sessionCondition = Wait(
  id: "w9", kind: .session, session: Wait.SessionTarget(id: "k3x9p", name: "flag-cache"), state: .done, created: 0)
private let nineAM = epochMs(2026, 11, 15, 9, 0, zone: .current)
private let dateCondition = Wait(id: "w9", kind: .date, until: nineAM, created: 0)

/// The suites nest under one name, so `--filter PauseCoreTests` runs them all.
@Suite struct PauseCoreTests {}

extension PauseCoreTests {
  @Suite struct ByText {
    @Test(arguments: [nil, managerPauser, flagsChatPauser, workPauser] as [Pause.Pauser?])
    func theUserIsYouWhateverTheSession(_ from: Pause.Pauser?) {
      #expect(pauseOf(by: .you, from: from).byText == "you")
    }

    @Test func claudeInTheManagerIsManager() {
      #expect(pauseOf(by: .claude, from: managerPauser).byText == "Manager")
    }

    @Test func claudeInAGroupChatIsThatGroupsChat() {
      #expect(pauseOf(by: .claude, from: flagsChatPauser).byText == "the Flags chat")
    }

    @Test func claudeInAWorkSessionIsThatSessionsName() {
      #expect(pauseOf(by: .claude, from: workPauser).byText == "flag-cache")
    }

    @Test func claudeWithNoSessionIsClaude() {
      #expect(pauseOf(by: .claude, from: nil).byText == "Claude")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Line {
    @Test func withoutAReasonOrAConditionNamesWhoPaused() {
      #expect(pauseOf().line == "Paused by you")
    }

    @Test func aReasonFollowsAColon() {
      #expect(
        pauseOf(by: .claude, from: managerPauser, reason: "free CPU for flags").line
          == "Paused by Manager: free CPU for flags")
    }

    @Test(arguments: [
      (mergeCondition, "#123 merges"), (sessionCondition, "flag-cache reaches Done"),
      (dateCondition, "at 2026-11-15 09:00"),
    ])
    func aConditionSaysWhenItResumes(_ until: Wait, _ phrase: String) {
      #expect(pauseOf(until: until).line == "Paused by you; resumes when \(phrase)")
    }

    @Test func aReasonComesBeforeTheCondition() {
      #expect(
        pauseOf(reason: "wait for the fix", until: mergeCondition).line
          == "Paused by you: wait for the fix; resumes when #123 merges")
    }

    @Test func aSessionConditionNamesTheStateItWaitsFor() {
      var until = sessionCondition
      until.state = .readyToMerge

      #expect(pauseOf(until: until).line == "Paused by you; resumes when flag-cache reaches Ready to merge")
    }
  }
}

extension PauseCoreTests {
  @Suite struct ResumeText {
    @Test func theOverrideIsSentVerbatim() {
      let p = pauseOf(reason: "free CPU", message: "stored")

      #expect(p.resumeText(outcome: "#123 merged", override: "  go on\n") == "  go on\n")
    }

    @Test func theStoredMessageIsSentVerbatimWithoutAnOverride() {
      let p = pauseOf(reason: "free CPU", message: "Rebase on main, then continue.")

      #expect(p.resumeText(outcome: "#123 merged", override: nil) == "Rebase on main, then continue.")
    }

    @Test func theDefaultNamesWhoPaused() {
      #expect(
        pauseOf().resumeText(outcome: nil, override: nil)
          == "Switchboard: You were paused by you. Continue where you left off.")
    }

    @Test func theDefaultAddsTheReasonInParentheses() {
      let p = pauseOf(by: .claude, from: managerPauser, reason: "free CPU for flags")

      #expect(
        p.resumeText(outcome: nil, override: nil)
          == "Switchboard: You were paused by Manager (free CPU for flags). Continue where you left off.")
    }

    @Test func theDefaultSaysWhyItResumes() {
      let p = pauseOf(until: mergeCondition)

      #expect(
        p.resumeText(outcome: "#123 merged", override: nil)
          == "Switchboard: You were paused by you. You resume because #123 merged. Continue where you left off.")
    }

    @Test func theDefaultHasTheReasonAndTheOutcome() {
      let p = pauseOf(by: .claude, from: workPauser, reason: "wait for the fix", until: mergeCondition)

      #expect(
        p.resumeText(outcome: "#123 merged", override: nil)
          == "Switchboard: You were paused by flag-cache (wait for the fix). You resume because #123 merged. "
          + "Continue where you left off.")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Blocker {
    @Test func aSessionThatIsNotPausedHasNone() {
      #expect(Pause.blocker(session()) == nil)
    }

    @Test(arguments: [
      (pauseOf(), "paused by you"), (pauseOf(by: .claude, from: managerPauser), "paused by Manager"),
      (pauseOf(by: .claude, from: flagsChatPauser), "paused by the Flags chat"),
      (pauseOf(by: .claude, from: workPauser), "paused by flag-cache"), (pauseOf(by: .claude), "paused by Claude"),
    ])
    func aPausedSessionNamesWhoPausedIt(_ pause: Pause, _ text: String) {
      #expect(Pause.blocker(pausedSession(pause)) == text)
    }

    @Test func aPausedSessionMarkedDoneStillHasOne() {
      #expect(Pause.blocker(pausedSession(done: true)) == "paused by you")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Storage {
    @Test func aSessionThatAnOlderSbdStoredDecodesWithNoPause() throws {
      var stored = try #require(try JSON(encoding: session()).object)
      stored["pause"] = nil

      let decoded = try JSONCoding.convert(JSON.object(stored), to: Session.self)

      #expect(decoded.pause == nil)
    }

    @Test(arguments: [
      pauseOf(),
      pauseOf(by: .claude, from: flagsChatPauser, reason: "free CPU", since: 42, until: mergeCondition, message: "go"),
      pauseOf(by: .claude, from: workPauser, until: sessionCondition),
      pauseOf(by: .claude, until: dateCondition),
    ])
    func aPausedSessionRoundTrips(_ pause: Pause) throws {
      let s = pausedSession(pause)

      let decoded = try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s))

      #expect(decoded == s)
      #expect(decoded.pause == pause)
    }

    @Test func aSessionThatIsNotPausedEncodesNoPauseKey() throws {
      #expect(try JSON(encoding: session())["pause"] == nil)
    }

    @Test func aPauseEncodesWhoPausedByTheirWireNames() throws {
      let json = try JSON(encoding: pauseOf(by: .claude, from: flagsChatPauser))

      #expect(json["by"] == "claude")
      #expect(json["from"]?["id"] == "c1")
      #expect(json["from"]?["name"] == "Flags")
      #expect(json["from"]?["kind"] == "chat")
    }
  }
}
