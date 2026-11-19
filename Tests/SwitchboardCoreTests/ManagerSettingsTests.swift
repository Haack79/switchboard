import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ManagerSettingsTests {
  // MARK: Decoding

  @Test(arguments: ["{}", #"{"manager": {}}"#, #"{"manager": {"future": 1}}"#, #"{"model": "opus"}"#])
  func configWithoutAManagerModelRunsSonnet(_ text: String) throws {
    #expect(try JSONCoding.decode(Config.self, from: text).manager.model == "sonnet")
  }

  @Test func configReadsTheManagerModelApartFromTheGlobalModel() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"manager": {"model": "haiku"}}"#)

    #expect(c.manager.model == "haiku")
    #expect(c.model == nil)
  }

  // MARK: Launch model

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator])
  func aStoredModelWinsForEveryKind(_ kind: SessionKind) {
    #expect(Manager.launchModel(for: kind, stored: "opus", managerModel: "haiku") == "opus")
  }

  @Test func aManagerConversationWithoutAStoredModelRunsTheManagerModel() {
    #expect(Manager.launchModel(for: .manager, stored: nil, managerModel: "haiku") == "haiku")
  }

  @Test(arguments: [SessionKind.work, .chat, .operator])
  func anyOtherKindWithoutAStoredModelRunsClaudesDefault(_ kind: SessionKind) {
    #expect(Manager.launchModel(for: kind, stored: nil, managerModel: "haiku") == nil)
  }

  // MARK: Model names

  @Test(arguments: ["", " ", "a b", "a\tb", " haiku", "haiku\n", "a\u{00A0}b", "-p", "--model"])
  func aBadModelNameHasAProblem(_ model: String) {
    #expect(Manager.modelProblem(model) != nil)
  }

  @Test(arguments: ["sonnet", "opus", "claude-sonnet-5-5", "sonnet[1m]"])
  func aModelNameHasNoProblem(_ model: String) {
    #expect(Manager.modelProblem(model) == nil)
  }
}
