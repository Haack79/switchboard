import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func named(_ s: SessionSummary, _ name: String) -> SessionSummary {
  var s = s
  s.name = name
  return s
}

private func operatorNamed(_ id: String, _ name: String = Manager.operatorName) -> SessionSummary {
  var s = named(needsItem(id, manager: true, state: .working), name)
  s.kind = .operator
  return s
}

private func conversation(_ id: String, _ name: String) -> SessionSummary {
  named(needsItem(id, manager: true, state: .working), name)
}

private func groupChat(_ id: String, _ name: String) -> SessionSummary {
  named(chatItem(id, group: "g-\(id)", state: .working), name)
}

private func work(_ id: String, _ name: String) -> SessionSummary {
  named(orgSession(id, "PostHog/\(id)"), name)
}

private func sessions(_ choices: [LoopEditor.Choice]) -> [String] { choices.map(\.session) }

/// A 30m loop whose prompt is "Run the Waiting audit".
private let loop = scheduleFixture("r1")

@MainActor
@Suite struct LoopEditorTests {
  // MARK: Session choices

  /// Each kind's names sort the opposite way to its ids, so the order shows both the kind order and the
  /// by-name order inside a kind.
  @Test func choicesListTheOperatorThenConversationsThenGroupChatsThenWorkSessionsEachByName() {
    let list = [
      work("w1", "zeta"), groupChat("c1", "Yankee"), conversation("m1", "Xray"), operatorNamed("op"),
      work("w2", "alpha"), conversation("m2", "Bravo"), groupChat("c2", "Charlie"),
    ]

    let choices = LoopEditor.sessionChoices(list, operatorID: "op")

    #expect(sessions(choices) == ["op", "m2", "m1", "c2", "c1", "w2", "w1"])
  }

  @Test func withNoOperatorTheFirstChoiceIsASyntheticOperatorThatSbdCreatesByName() throws {
    let choices = LoopEditor.sessionChoices([work("w1", "fix")], operatorID: nil)

    let first = try #require(choices.first)
    #expect(first.session == Manager.operatorName)
    #expect(first.name == Manager.operatorName)
    #expect(sessions(choices) == [Manager.operatorName, "w1"])
  }

  @Test func withNoSessionsAtAllTheSyntheticOperatorIsTheOnlyChoice() {
    #expect(sessions(LoopEditor.sessionChoices([], operatorID: nil)) == [Manager.operatorName])
  }

  @Test func anExistingOperatorIsTheFirstChoiceByItsIdAndNoSyntheticOneIsAdded() throws {
    let choices = LoopEditor.sessionChoices([work("w1", "fix"), operatorNamed("op")], operatorID: "op")

    let first = try #require(choices.first)
    #expect(first.session == "op")
    #expect(choices.filter { $0.session == "op" }.count == 1)
    #expect(!choices.contains { $0.session == Manager.operatorName })
  }

  /// sbd's `schedule` refuses a session with no folder through `refuseNotStarted`.
  @Test(arguments: [unstartedFollowup("f1", "PostHog/posthog"), docketSession("d1")])
  func aSessionWithNoFolderIsLeftOut(_ session: SessionSummary) {
    let choices = LoopEditor.sessionChoices([work("w1", "fix"), session], operatorID: nil)

    #expect(!choices.contains { $0.session == session.id })
    #expect(choices.contains { $0.session == "w1" })
  }

  @Test func aFollowupThatHasStartedIsOffered() {
    var started = work("f1", "started")
    started.followup = Followup(prompt: "p")

    let choices = LoopEditor.sessionChoices([started], operatorID: nil)

    #expect(choices.contains { $0.session == "f1" })
  }

  @Test func aNewLoopDefaultsToTheExistingOperator() {
    let choices = LoopEditor.sessionChoices([work("w1", "aaa"), operatorNamed("op")], operatorID: "op")

    #expect(LoopEditor.Form(new: choices).session == "op")
  }

  @Test func aNewLoopDefaultsToTheSyntheticOperatorWhenThereIsNone() {
    let choices = LoopEditor.sessionChoices([work("w1", "aaa")], operatorID: nil)

    #expect(LoopEditor.Form(new: choices).session == Manager.operatorName)
  }

  // MARK: Validation

  /// A new loop on the operator with a prompt, so only the interval decides whether Save is enabled.
  private func newForm(interval: String, prompt: String = "check the queue") -> LoopEditor.Form {
    var form = LoopEditor.Form(new: LoopEditor.sessionChoices([], operatorID: nil))
    form.interval = interval
    form.prompt = prompt
    return form
  }

  @Test func aReadableIntervalOfAtLeastAMinuteHasNoErrorAndAllowsSave() {
    let form = newForm(interval: "30m")

    #expect(form.intervalError == nil)
    #expect(form.canSave)
  }

  @Test func anIntervalUnderAMinuteShowsTheTooShortErrorAndDisablesSave() {
    let form = newForm(interval: "30s")

    #expect(form.intervalError?.contains("too short") == true, "\(form.intervalError ?? "nil")")
    #expect(!form.canSave)
  }

  @Test func aCompoundIntervalShowsTheOneUnitErrorAndDisablesSave() {
    let form = newForm(interval: "1h30m")

    #expect(form.intervalError?.contains("more than one unit") == true, "\(form.intervalError ?? "nil")")
    #expect(!form.canSave)
  }

  @Test func theIntervalErrorIsTheCoreParsersError() throws {
    let form = newForm(interval: "soon")

    let error = try #require(form.intervalError)
    #expect(error.contains("can't read the interval soon"))
  }

  @Test func anEmptyIntervalDisablesSave() {
    #expect(!newForm(interval: "").canSave)
  }

  @Test(arguments: ["", " ", "  \n\t "])
  func aPromptThatIsEmptyAfterTrimmingDisablesSave(_ prompt: String) {
    let form = newForm(interval: "30m", prompt: prompt)

    #expect(form.intervalError == nil)
    #expect(!form.canSave)
  }

  // MARK: Editing

  /// An edit form for `loop` with `interval` and `prompt` typed over the loop's own values.
  private func editForm(interval: String? = nil, prompt: String? = nil) -> LoopEditor.Form {
    var form = LoopEditor.Form(editing: loop)
    if let interval { form.interval = interval }
    if let prompt { form.prompt = prompt }
    return form
  }

  @Test func anEditOpensWithTheLoopsIntervalAndPrompt() {
    let form = LoopEditor.Form(editing: loop)

    #expect(form.interval == Schedule.intervalText(loop.every))
    #expect(form.interval == "30m")
    #expect(form.prompt == loop.prompt)
  }

  @Test func anUnchangedEditDisablesSaveAndChangesNothing() {
    let form = editForm()

    #expect(!form.canSave)
    #expect(form.changedInterval == nil)
    #expect(form.changedPrompt == nil)
  }

  @Test func anIntervalOnlyEditChangesOnlyTheInterval() {
    let form = editForm(interval: "1h")

    #expect(form.canSave)
    #expect(form.changedInterval == "1h")
    #expect(form.changedPrompt == nil)
  }

  @Test func aPromptOnlyEditChangesOnlyThePrompt() {
    let form = editForm(prompt: "Run the Done audit")

    #expect(form.canSave)
    #expect(form.changedInterval == nil)
    #expect(form.changedPrompt == "Run the Done audit")
  }

  @Test func anEditOfBothChangesBoth() {
    let form = editForm(interval: "1h", prompt: "Run the Done audit")

    #expect(form.canSave)
    #expect(form.changedInterval == "1h")
    #expect(form.changedPrompt == "Run the Done audit")
  }

  @Test func aChangedPromptIsSentTrimmed() {
    let form = editForm(prompt: "  Run the Done audit\n")

    #expect(form.changedPrompt == "Run the Done audit")
  }

  /// sbd trims the prompt, so spaces around the loop's own prompt change nothing.
  @Test func spacesAroundTheSamePromptAreNoChange() {
    let form = editForm(prompt: "  \(loop.prompt)\n")

    #expect(form.changedPrompt == nil)
    #expect(!form.canSave)
  }

  /// The interval is compared by its length, so the same interval in another unit changes nothing.
  @Test func theSameIntervalWrittenInAnotherUnitIsNoChange() {
    var form = LoopEditor.Form(editing: scheduleFixture("r1", every: 60 * minuteMs))
    form.interval = "60m"

    #expect(form.changedInterval == nil)
    #expect(!form.canSave)
  }

  @Test(arguments: ["30s", "1h30m", "soon", ""])
  func anEditWithAnUnreadableIntervalDisablesSaveEvenWithANewPrompt(_ interval: String) {
    let form = editForm(interval: interval, prompt: "Run the Done audit")

    #expect(!form.canSave)
  }

  @Test(arguments: ["", "  \n "])
  func anEditThatEmptiesThePromptDisablesSave(_ prompt: String) {
    let form = editForm(interval: "1h", prompt: prompt)

    #expect(!form.canSave)
  }

  @Test func theIntervalIsReadAndSentWithoutSurroundingSpaces() {
    let form = newForm(interval: " 30m\n")

    #expect(form.intervalError == nil)
    #expect(form.canSave)
    #expect(form.changedInterval == "30m")
  }

  @Test func aDayWrittenAsHoursIsNoChange() {
    var form = LoopEditor.Form(editing: scheduleFixture("r1", every: 24 * 60 * minuteMs))
    form.interval = "24h"

    #expect(form.changedInterval == nil)
    #expect(!form.canSave)
  }

  /// Only the ends are trimmed, so a change of the spaces inside the prompt is a change.
  @Test func aChangeOfTheSpacesInsideThePromptIsAChange() {
    let form = editForm(prompt: "Run the  Waiting audit")

    #expect(form.changedPrompt == "Run the  Waiting audit")
    #expect(form.canSave)
  }
}
