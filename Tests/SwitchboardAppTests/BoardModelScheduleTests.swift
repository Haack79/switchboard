import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A model whose `send` records every request and answers each with a schedule row, as sbd answers `schedule`
/// and `edit-schedule`.
@MainActor
private func rowAnsweringModel() -> (BoardModel, SentRequests) {
  let model = offlineModel()
  let sent = SentRequests()
  model.send = { op, args in
    sent.append(op, args)
    return try JSON(encoding: ScheduleRow(session: "s1", name: "s1", schedule: scheduleFixture("r1")))
  }
  return (model, sent)
}

@MainActor
@Suite struct BoardModelScheduleTests {
  @Test func pausingAScheduleSendsPauseScheduleWithPausedTrue() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: true) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": true])
  }

  @Test func resumingAScheduleSendsPauseScheduleWithPausedFalse() async {
    let sent = await firstRequest { $0.pauseSchedule("r1", paused: false) }

    #expect(sent.op == "pause-schedule")
    #expect(sent.args == ["schedule": "r1", "paused": false])
  }

  @Test func removingAScheduleSendsRemoveScheduleWithTheId() async {
    let sent = await firstRequest { $0.removeSchedule("r1") }

    #expect(sent.op == "remove-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }

  @Test func runningAScheduleNowSendsRunScheduleWithTheId() async {
    let sent = await firstRequest { $0.runSchedule("r1") }

    #expect(sent.op == "run-schedule")
    #expect(sent.args == ["schedule": "r1"])
  }

  // MARK: New Loop and Edit

  @Test func addingALoopSendsScheduleWithTheSessionIntervalPromptAndTheUserAsAuthor() async {
    let sent = await firstRequest { $0.addSchedule(session: "s1", every: "30m", prompt: "check the queue") }

    #expect(sent.op == "schedule")
    #expect(sent.args == ["session": "s1", "every": "30m", "prompt": "check the queue", "by": "you"])
  }

  /// sbd's `schedule` creates the operator when the session is its name and none exists yet.
  @Test func addingALoopOnTheSyntheticOperatorSendsTheOperatorsName() async throws {
    let choice = try #require(LoopEditor.sessionChoices([], operatorID: nil).first)

    let sent = await firstRequest { $0.addSchedule(session: choice.session, every: "30m", prompt: "check the queue") }

    #expect(sent.op == "schedule")
    #expect(sent.args["session"] == .string(Manager.operatorName))
  }

  @Test func editingOnlyTheIntervalSendsEditScheduleWithOnlyEvery() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: "1h", prompt: nil) }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "every": "1h"])
  }

  @Test func editingOnlyThePromptSendsEditScheduleWithOnlyThePrompt() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: nil, prompt: "Run the Done audit") }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "prompt": "Run the Done audit"])
  }

  @Test func editingBothSendsEditScheduleWithBoth() async {
    let sent = await firstRequest { $0.editSchedule("r1", every: "1h", prompt: "Run the Done audit") }

    #expect(sent.op == "edit-schedule")
    #expect(sent.args == ["schedule": "r1", "every": "1h", "prompt": "Run the Done audit"])
  }

  @Test(arguments: [LoopEditorRequest.new, .edit("r1")])
  func theOpenLoopEditorCountsAsASheet(_ request: LoopEditorRequest) throws {
    let model = offlineModel()
    try #require(!model.presentingSheet)

    model.loopEditor = request
    #expect(model.presentingSheet)
    model.loopEditor = nil
    #expect(!model.presentingSheet)
  }

  @Test func aNewLoopThatSbdAddsClosesTheEditor() async {
    let (model, sent) = rowAnsweringModel()
    model.loopEditor = .new

    model.addSchedule(session: "s1", every: "30m", prompt: "check the queue")
    await settle { sent.ops.contains("schedule") && model.loopEditor == nil }

    #expect(model.loopEditor == nil)
  }

  @Test func aNewLoopThatSbdRefusesKeepsTheEditorOpenAndShowsTheError() async {
    let (model, _) = recordingModel { op, _ in op == "schedule" ? "s1 has 10 schedules" : nil }
    model.loopEditor = .new

    model.addSchedule(session: "s1", every: "30m", prompt: "check the queue")
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains("s1 has 10 schedules") == true, "\(model.actionError ?? "nil")")
    #expect(model.loopEditor == .new)
  }

  @Test func anEditThatSbdAppliesClosesTheEditor() async {
    let (model, sent) = rowAnsweringModel()
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    await settle { sent.ops.contains("edit-schedule") && model.loopEditor == nil }

    #expect(model.loopEditor == nil)
  }

  @Test func anEditThatSbdRefusesKeepsTheEditorOpenAndShowsTheError() async {
    let (model, _) = recordingModel { op, _ in op == "edit-schedule" ? "no schedule r1" : nil }
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains("no schedule r1") == true, "\(model.actionError ?? "nil")")
    #expect(model.loopEditor == .edit("r1"))
  }

  /// An answer to the first editor's save must not close an editor that the user opened after cancelling it.
  @Test func aSaveThatSbdAppliesAfterTheUserOpenedAnotherEditorLeavesThatEditorOpen() async {
    let (model, release, _) = heldModel()
    model.loopEditor = .edit("r1")
    model.editSchedule("r1", every: "1h", prompt: nil)
    #expect(model.savingLoop)

    model.loopEditor = .edit("r2")
    release.signal()
    await settle { !model.savingLoop }

    #expect(!model.savingLoop)
    #expect(model.loopEditor == .edit("r2"))
  }

  @Test func aSaveThatSbdAppliesAfterTheUserReopenedTheSameEditorLeavesItOpen() async {
    let (model, release, _) = heldModel()
    model.loopEditor = .new
    model.addSchedule(session: "s1", every: "1h", prompt: "check")

    model.loopEditor = nil
    model.loopEditor = .new
    release.signal()
    await settle { !model.savingLoop }

    #expect(model.loopEditor == .new)
  }

  @Test func aSecondSaveWhileTheFirstIsOutSendsNothing() async {
    let (model, release, requests) = heldModel()
    model.loopEditor = .new
    model.addSchedule(session: "s1", every: "1h", prompt: "check")
    model.addSchedule(session: "s1", every: "1h", prompt: "check")
    release.signal()
    release.signal()
    await settle { !model.savingLoop }

    #expect(requests.value == 1)
  }

  @Test func aRefusedSaveEndsTheSaving() async {
    let (model, _) = recordingModel { _, _ in "no schedule r1" }
    model.loopEditor = .edit("r1")

    model.editSchedule("r1", every: "1h", prompt: nil)
    #expect(model.savingLoop)
    await settle { !model.savingLoop }

    #expect(!model.savingLoop)
  }
}
