import Testing

@testable import SwitchboardCore

/// The model that a new session stores, and the model that sbd passes with `--model` at each launch.
@Suite struct SessionModelTests {
  // MARK: Stored at creation

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator])
  func theCallersModelWinsForEveryKind(_ kind: SessionKind) {
    #expect(SessionModel.stored(kind: kind, requested: "sonnet", workModel: "opus") == "sonnet")
  }

  @Test func aManagerConversationStoresNoModel() {
    #expect(SessionModel.stored(kind: .manager, requested: nil, workModel: "opus") == nil)
  }

  @Test(arguments: [SessionKind.work, .chat, .operator])
  func anyOtherKindStoresTheWorkModel(_ kind: SessionKind) {
    #expect(SessionModel.stored(kind: kind, requested: nil, workModel: "opus") == "opus")
  }

  @Test func withoutAWorkModelAWorkSessionStoresNone() {
    #expect(SessionModel.stored(kind: .work, requested: nil, workModel: nil) == nil)
  }

  // MARK: Passed at launch

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator])
  func aStoredModelWinsForEveryKind(_ kind: SessionKind) {
    #expect(SessionModel.launch(kind: kind, stored: "opus", coordinatorModel: "haiku") == "opus")
  }

  @Test func aManagerConversationWithoutAStoredModelRunsTheCoordinatorModel() {
    #expect(SessionModel.launch(kind: .manager, stored: nil, coordinatorModel: "haiku") == "haiku")
  }

  @Test(arguments: [SessionKind.work, .chat, .operator])
  func anyOtherKindWithoutAStoredModelRunsClaudesDefault(_ kind: SessionKind) {
    #expect(SessionModel.launch(kind: kind, stored: nil, coordinatorModel: "haiku") == nil)
  }
}
