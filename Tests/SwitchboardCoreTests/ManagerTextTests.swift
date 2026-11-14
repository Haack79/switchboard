import Testing

@testable import SwitchboardCore

@Suite struct ManagerTextTests {
  @Test(
    arguments: [
      (nil, "every MCP server (the full setup)"), ([], "switchboard only"), (["grafana"], "switchboard, grafana"),
    ] as [([String]?, String)])
  func serversTextNamesTheSetup(_ servers: [String]?, _ text: String) {
    #expect(Manager.serversText(servers) == text)
  }

  @Test func aManagerMCPAnswerForTheFullSetupEncodesItsServersAsNull() throws {
    let answer = ManagerMCPAnswer(session: "m", name: "Manager", servers: nil, available: ["grafana"], pending: false)

    #expect(try JSON(encoding: answer)["servers"] == .null)
  }

  @Test func theOperatorIsNamedOperator() {
    #expect(Manager.operatorName == "Operator")
  }

  @Test func theOperatorPromptSaysToCheckTheOperatorBeforeItReArmsALoop() {
    #expect(Manager.operatorPrompt.contains("`sb get \(Manager.operatorName)`"), "\(Manager.operatorPrompt)")
  }

  @Test func theOperatorPromptSaysToReportWithTheReportToolAndNeedsYou() {
    #expect(Manager.operatorPrompt.contains("`report`"), "\(Manager.operatorPrompt)")
    #expect(Manager.operatorPrompt.contains("`needsYou`"), "\(Manager.operatorPrompt)")
  }

  @Test func theOperatorPromptSaysThatTheAskFirstRulesApply() {
    #expect(Manager.operatorPrompt.contains("CLAUDE.md"), "\(Manager.operatorPrompt)")
  }
}
