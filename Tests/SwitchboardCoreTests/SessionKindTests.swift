import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct SessionKindTests {
  func session(manager: Bool? = nil, chat: String? = nil) -> Session {
    var s = Session(id: "s1", name: "s", cwd: "/tmp", claudeSessionId: "c1", created: 0)
    s.manager = manager
    s.chat = chat
    return s
  }

  @Test(
    arguments: [
      (nil, nil, SessionKind.work), (true, nil, .manager), (nil, "g1", .chat), (false, nil, .work),
    ] as [(Bool?, String?, SessionKind)])
  func aSessionsKindFollowsItsManagerAndChatFields(_ manager: Bool?, _ chat: String?, _ kind: SessionKind) {
    #expect(session(manager: manager, chat: chat).kind == kind)
  }

  @Test(
    arguments: [
      (true, true, nil, SessionKind.operator), (true, nil, nil, .operator), (true, true, "g1", .operator),
      (false, true, nil, .manager), (nil, true, nil, .manager), (false, nil, nil, .work),
    ] as [(Bool?, Bool?, String?, SessionKind)])
  func isOperatorWinsOverTheManagerAndChatFields(
    _ isOperator: Bool?, _ manager: Bool?, _ chat: String?, _ kind: SessionKind
  ) {
    var s = session(manager: manager, chat: chat)
    s.isOperator = isOperator

    #expect(s.kind == kind)
  }

  @Test func eachKindEncodesAsItsName() throws {
    let encoded = try JSON(encoding: [SessionKind.work, .manager, .chat, .operator])

    #expect(encoded == ["work", "manager", "chat", "operator"])
  }

  @Test func theOperatorKindDecodesFromItsName() throws {
    #expect(try JSONCoding.decode([SessionKind].self, from: #"["operator"]"#) == [.operator])
  }

  @Test(
    arguments: [(SessionKind.work, false), (.manager, true), (.chat, true), (.operator, true)] as [(SessionKind, Bool)])
  func onlyAWorkSessionDoesNotShowAsAChat(_ kind: SessionKind, _ showsAsChat: Bool) {
    #expect(kind.showsAsChat == showsAsChat)
  }

  @Test func theOperatorsLabelIsTheOperator() {
    #expect(SessionKind.operator.label == "the operator")
  }

  @Test func theOperatorIsNotSummarized() {
    #expect(!Triage.summarizes(.operator))
  }
}
