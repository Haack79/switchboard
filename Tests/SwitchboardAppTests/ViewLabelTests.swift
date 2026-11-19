import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct ViewPickerLabels {
  @Test func showsTheCountWithoutParentheses() {
    #expect(ContentView.viewLabel("Inbox", 5) == "Inbox 5")
  }

  @Test func leavesOutAZeroCount() {
    #expect(ContentView.viewLabel("Issues", 0) == "Issues")
  }
}

/// The bar that a Manager's chat pane shows in place of sending a work skill's command.
@Suite struct WorkSkillOfferViewLabels {
  @Test func theButtonsReadSpawnRunHereAndCancel() {
    #expect(WorkSkillOfferBar.spawnTitle == "Spawn a session with this")
    #expect(WorkSkillOfferBar.runHereTitle == "Run here anyway")
    #expect(WorkSkillOfferBar.cancelTitle == "Cancel")
  }

  /// The block reason of sbd's hook names the first two buttons, so a user who reads it finds them.
  @Test func theBlockReasonNamesTheSpawnAndRunHereButtons() {
    let reason = ManagerSkillGate.promptReason(skill: "go", session: "m")

    #expect(reason.contains(WorkSkillOfferBar.spawnTitle), "\(reason)")
    #expect(reason.contains(WorkSkillOfferBar.runHereTitle), "\(reason)")
  }

  @Test func theMessageNamesTheCommandAndTheCost() {
    #expect(
      WorkSkillOfferBar.message(skill: "go")
        == "/go is a work skill. A Manager conversation pays for its text on every later turn.")
  }
}
