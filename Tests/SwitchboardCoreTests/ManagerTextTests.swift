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

/// The guides tell the Manager and each group chat to pause a session rather than stop it.
extension ManagerTextTests {
  /// The `## Commands` bullet that shows `sb pause`.
  static var pauseBullet: String? {
    Manager.guide.split(separator: "\n").map(String.init).first { $0.hasPrefix("- `sb pause") }
  }

  @Test func theManagerGuideShowsSbPauseWithAReasonAndACondition() throws {
    let bullet = try #require(Self.pauseBullet, "no `sb pause` bullet in the Manager guide")

    #expect(bullet.contains("--reason"), "\(bullet)")
    #expect(bullet.contains("--until"), "\(bullet)")
  }

  /// A stopped session lands in Needs you and wakes on the next message, which a pause prevents.
  @Test func theManagerGuideSaysWhyToPauseRatherThanStop() throws {
    let bullet = try #require(Self.pauseBullet, "no `sb pause` bullet in the Manager guide")

    #expect(bullet.contains("sb stop"), "\(bullet)")
    #expect(bullet.contains("Needs you"), "\(bullet)")
  }

  @Test(arguments: ["`pause`", "`resume`"]) func theChatGuideNamesThePauseTools(_ tool: String) throws {
    let tools = try #require(Chat.guide.components(separatedBy: "## Tools").dropFirst().first)

    #expect(tools.components(separatedBy: "\n## ").first?.contains(tool) == true, "\(tool)")
  }

  /// The chat guide names only tools that the server has.
  @Test(arguments: ["pause", "resume"]) func theServerHasThePauseToolsThatTheChatGuideNames(_ tool: String) {
    #expect(MCPToolServer.allTools.contains { $0.name == tool }, "\(tool)")
  }
}
