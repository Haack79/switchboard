import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The parent `p1`, named planner, which the app lists as a live work session.
private func planner(manager: Bool = false) -> SessionSummary {
  var s = needsItem("p1", manager: manager, state: .working)
  s.name = "planner"
  return s
}

/// The child `kid`, a live work session.
private func kid(parent: String? = "p1") -> SessionSummary {
  var s = needsItem("kid")
  s.name = "kidname"
  s.parent = parent
  return s
}

private let plannerTombstone = RemovedSession(id: "p1", name: "planner", removed: 1_794_377_400_000)

/// The Risk 2 shapes. ParentLinkServiceTests.swift in SwitchboardServiceTests holds the same rows for sbd's half. A
/// row whose menu shows "Unlink from" must be a row whose clear sbd accepts.
enum ParentMenuShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case workParent, managerParent, docketChild, startedFollowup, unstartedFollowup, removedParent, selfParent, noParent

  var testDescription: String { rawValue }

  /// Whether the menu offers "Unlink from planner".
  var shown: Bool {
    switch self {
    case .workParent, .managerParent, .docketChild: true
    case .startedFollowup, .unstartedFollowup, .removedParent, .selfParent, .noParent: false
    }
  }

  /// Whether sbd accepts the clear, as ParentLinkServiceTests.swift checks.
  var accepted: Bool {
    switch self {
    case .workParent, .managerParent, .docketChild, .removedParent, .selfParent: true
    case .startedFollowup, .unstartedFollowup, .noParent: false
    }
  }

  /// The row's child, which `model()` lists.
  var child: SessionSummary {
    switch self {
    case .workParent, .managerParent, .removedParent: return kid()
    case .docketChild:
      var s = docketSession("kid")
      s.parent = "p1"
      return s
    case .startedFollowup:
      var s = kid()
      s.followup = Followup(prompt: "p")
      s.followup?.started = 1
      return s
    case .unstartedFollowup:
      var s = SwitchboardAppTests.unstartedFollowup("kid")
      s.parent = "p1"
      return s
    case .selfParent: return kid(parent: "kid")
    case .noParent: return kid(parent: nil)
    }
  }

  /// A model that lists the row's sessions as sbd's refresh gives them. A removed parent is a tombstone, and an
  /// unstarted follow-up comes in the follow-up list.
  @MainActor func model() -> BoardModel {
    let model = offlineModel()
    switch self {
    case .removedParent:
      model.apply(.success([child]), followups: nil, removed: [plannerTombstone])
    case .unstartedFollowup:
      model.apply(.success([planner()]), followups: [child])
    case .managerParent:
      model.apply(.success([planner(manager: true), child]), followups: nil)
    default:
      model.apply(.success([planner(), child]), followups: nil)
    }
    return model
  }
}

/// Records every request and refuses a `parent` request with `refusal` when it is set.
@MainActor
private func parentModel(refusing refusal: String? = nil) -> (BoardModel, SentRequests) {
  let (model, sent) = recordingModel { op, _ in op == "parent" ? refusal : nil }
  model.apply(.success([planner(), kid()]), followups: nil)
  return (model, sent)
}

/// The `parent` requests that sbd got, oldest first.
private func parentRequests(_ sent: SentRequests) -> [[String: JSON]] {
  sent.value.filter { $0.op == "parent" }.map(\.args)
}

private let clearKid: [String: JSON] = ["session": "kid", "clear": true]
private let relinkKid: [String: JSON] = ["session": "kid", "parent": "p1"]

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelParent {
  // MARK: The requests

  @Test func unlinkParentSendsTheClear() async {
    let sent = await firstRequest {
      $0.apply(.success([planner(), kid()]), followups: nil)
      $0.unlinkParent("kid")
    }

    #expect(sent.op == "parent")
    #expect(sent.args == clearKid)
  }

  @Test func setParentSendsTheNewParent() async {
    let sent = await firstRequest { $0.setParent("kid", to: "p1") }

    #expect(sent.op == "parent")
    #expect(sent.args == relinkKid)
  }

  // MARK: Undo and redo

  /// A model whose unlink of `kid` sbd accepted, with a fresh undo manager that groups by hand. The undo manager
  /// holds the model weakly, so each test keeps the model alive until its last undo or redo.
  private func unlinked() async -> (BoardModel, SentRequests, UndoManager) {
    let (model, sent) = parentModel()
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.actionUndoManager = { undo }
    model.unlinkParent("kid")
    await settle { undo.canUndo }
    return (model, sent, undo)
  }

  @Test func anAcceptedUnlinkRegistersAnUndo() async {
    let (model, _, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }

    #expect(undo.canUndo)
  }

  @Test func theUndoIsNamedForTheParent() async {
    let (model, _, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }

    #expect(undo.undoActionName == "Unlink from planner")
  }

  @Test func undoSendsTheOldParent() async {
    let (model, sent, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }

    undo.undo()
    await settle { parentRequests(sent).count == 2 }

    #expect(parentRequests(sent) == [clearKid, relinkKid])
  }

  /// The redo must be registered while the undo manager undoes, so it is there before the request answers.
  @Test func undoLeavesARedoBeforeItsRequestAnswers() async {
    let (model, _, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }

    undo.undo()

    #expect(undo.canRedo)
    #expect(undo.redoActionName == "Unlink from planner")
  }

  @Test func redoSendsTheClearAgain() async {
    let (model, sent, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }
    undo.undo()
    await settle { parentRequests(sent).count == 2 }

    undo.redo()
    await settle { parentRequests(sent).count == 3 }

    #expect(parentRequests(sent) == [clearKid, relinkKid, clearKid])
  }

  @Test func redoLeavesAnUndoBeforeItsRequestAnswers() async {
    let (model, sent, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }
    undo.undo()
    await settle { parentRequests(sent).count == 2 }

    undo.redo()

    #expect(undo.canUndo)
    #expect(undo.undoActionName == "Unlink from planner")
  }

  /// A redo's undo relinks again, so the user can undo and redo as often as they like.
  @Test func aSecondUndoAfterARedoSendsTheOldParentAgain() async {
    let (model, sent, undo) = await unlinked()
    defer { withExtendedLifetime(model) {} }
    undo.undo()
    await settle { parentRequests(sent).count == 2 }
    undo.redo()
    await settle { parentRequests(sent).count == 3 }

    undo.undo()
    await settle { parentRequests(sent).count == 4 }

    #expect(parentRequests(sent) == [clearKid, relinkKid, clearKid, relinkKid])
  }

  @Test func aRefusedUnlinkRegistersNoUndo() async {
    let (model, sent) = parentModel(refusing: "kidname has no parent")
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.actionUndoManager = { undo }

    model.unlinkParent("kid")
    await sent.wait(for: "parent")
    await settle { model.actionError != nil }

    #expect(!undo.canUndo)
  }

  @Test func aRefusedUnlinkShowsSbdsError() async {
    let (model, sent) = parentModel(refusing: "kidname has no parent")
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.actionUndoManager = { undo }

    model.unlinkParent("kid")
    await sent.wait(for: "parent")
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains("kidname has no parent") == true, "\(model.actionError ?? "")")
  }

  /// With no key or main window there is no undo manager. The unlink still reaches sbd.
  @Test func anUnlinkWithNoUndoManagerStillSendsTheClear() async {
    let (model, sent) = parentModel()
    model.actionUndoManager = { nil }

    model.unlinkParent("kid")
    await sent.wait(for: "parent")

    #expect(parentRequests(sent) == [clearKid])
  }

  // MARK: Risk 2: the shape table, the app's half

  @Test(arguments: ParentMenuShape.allCases)
  func linkedParentNameNamesTheParentExactlyForTheRowsThatShowTheItem(_ shape: ParentMenuShape) {
    let model = shape.model()

    #expect(model.linkedParentName(of: shape.child) == (shape.shown ? "planner" : nil))
  }

  @Test(arguments: ParentMenuShape.allCases)
  func theMenuOffersUnlinkExactlyForTheRowsThatShowTheItem(_ shape: ParentMenuShape) {
    let model = shape.model()
    let child = shape.child

    let actions = SessionMenu.actions(
      for: child, selectionCount: nil, parentName: model.linkedParentName(of: child))

    #expect(actions.contains(.unlinkParent("Unlink from planner")) == shape.shown)
  }

  @Test(arguments: ParentMenuShape.allCases)
  func everyRowWhoseMenuShowsIsOneThatSbdAccepts(_ shape: ParentMenuShape) {
    #expect(!shape.shown || shape.accepted)
  }

  /// A parent that the app has never listed is not known, so the menu offers nothing.
  @Test func linkedParentNameIsNilForAParentTheAppDoesNotKnow() {
    let model = appliedModel([kid(parent: "sunknown")])

    #expect(model.linkedParentName(of: kid(parent: "sunknown")) == nil)
  }

  /// The name follows a rename of the parent.
  @Test func linkedParentNameReadsTheParentsCurrentName() {
    var renamed = planner()
    renamed.name = "architect"
    let model = appliedModel([renamed, kid()])

    #expect(model.linkedParentName(of: kid()) == "architect")
  }
}
