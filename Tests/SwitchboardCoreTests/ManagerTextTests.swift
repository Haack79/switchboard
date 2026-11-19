import Foundation
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

  /// The bullet goes in `## Commands`, which #252 leaves alone, and not in `## What changed`.
  @Test func theManagerGuideTeachesSchedulesInItsCommands() throws {
    let guide = Manager.guide
    let start = try #require(guide.range(of: "## Commands"))
    let end = try #require(guide.range(of: "## What changed", range: start.upperBound..<guide.endIndex))

    let commands = guide[start.upperBound..<end.lowerBound]

    #expect(commands.contains("`sb schedule "))
    #expect(commands.contains("add_schedule"))
  }

  @Test func theChatGuideNamesTheScheduleTools() {
    #expect(Chat.guide.contains("add_schedule"))
    #expect(Chat.guide.contains("remove_schedule"))
  }

  @Test func theOperatorIsNamedOperator() {
    #expect(Manager.operatorName == "Operator")
  }

  @Test(arguments: ["Operator", "Operator\nCheck the loops", "\n  Operator  \n"])
  func aPromptWhoseFirstLineIsTheOperatorsNameNamesNoConversation(_ prompt: String) {
    #expect(Manager.name(fromPrompt: prompt) == Manager.untitled)
  }

  @Test(arguments: ["Operator check", "operator", "Ask the Operator"])
  func aPromptThatOnlyMentionsTheOperatorStillNamesTheConversation(_ prompt: String) {
    #expect(Manager.name(fromPrompt: prompt) != Manager.untitled)
  }

  @Test func theOperatorPromptSaysToCheckTheOperatorBeforeItReArmsALoop() {
    #expect(Manager.operatorPrompt.contains("`sb get \(Manager.operatorName)`"), "\(Manager.operatorPrompt)")
  }

  @Test func theOperatorPromptSaysToKeepALoopAsASchedule() {
    #expect(Manager.operatorPrompt.contains("`sb schedule \(Manager.operatorName) "), "\(Manager.operatorPrompt)")
  }

  @Test func theOperatorPromptSaysToReportWithTheReportToolAndNeedsYou() {
    #expect(Manager.operatorPrompt.contains("`report`"), "\(Manager.operatorPrompt)")
    #expect(Manager.operatorPrompt.contains("`needsYou`"), "\(Manager.operatorPrompt)")
  }

  @Test func theOperatorPromptSaysThatTheAskFirstRulesApply() {
    #expect(Manager.operatorPrompt.contains("CLAUDE.md"), "\(Manager.operatorPrompt)")
  }

  // MARK: Asking for an MCP server

  /// The guide's "## MCP servers" section, up to the next heading.
  func mcpSection() throws -> String {
    let start = try #require(Manager.guide.range(of: "## MCP servers"))
    let rest = Manager.guide[start.upperBound...]
    return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
  }

  @Test func theGuidesMCPSectionNamesTheRequestTool() throws {
    let section = try mcpSection()

    #expect(section.contains("`request_mcp_server`"), "\(section)")
  }

  @Test func theParagraphThatNamesTheRequestToolSaysToEndTheTurn() throws {
    let section = try mcpSection()
    let paragraph = try #require(
      section.split(separator: "\n").first { $0.contains("request_mcp_server") }, "\(section)")

    let text = paragraph.lowercased()
    #expect(text.contains("end the turn") || text.contains("end your turn"), "\(paragraph)")
  }

  @Test func theGuideNoLongerAsksTheUserToRunAdd() {
    #expect(!Manager.guide.contains("sb manager mcp <id> add"), "\(Manager.guide)")
    #expect(!Manager.guide.contains("ask the user to run"), "\(Manager.guide)")
  }

  @Test func theGuideStillListsTheServersWithSbManagerMCP() throws {
    let section = try mcpSection()

    #expect(section.contains("sb manager mcp $SB_SESSION_ID"), "\(section)")
  }

  @Test func theGuideSaysAConnectorNeedsAll() throws {
    let section = try mcpSection()

    #expect(section.contains("Slack"), "\(section)")
    #expect(section.contains("`all`"), "\(section)")
  }

  @Test func theGuideSaysNotToWorkAroundAMissingTool() throws {
    let section = try mcpSection()

    for word in ["`sb`", "`curl`", "another session"] { #expect(section.contains(word), "\(word) in \(section)") }
  }

  @Test func theGuideSaysNotToRunAddItself() throws {
    let section = try mcpSection()

    #expect(section.contains("Do not run `sb manager mcp"), "\(section)")
  }

  @Test func theOperatorPromptSaysToReportANeededMCPServerWithNeedsYou() throws {
    let line = try #require(
      Manager.operatorPrompt.split(separator: "\n").first { $0.contains("MCP server") }, "\(Manager.operatorPrompt)")

    #expect(line.contains("`needsYou`"), "\(line)")
  }

  @Test func theOperatorPromptDoesNotOfferTheRequestTool() {
    #expect(!Manager.operatorPrompt.contains("call `request_mcp_server`"), "\(Manager.operatorPrompt)")
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

/// The Manager guide teaches `sb highlight` and the MCP `highlight` tool.
extension ManagerTextTests {
  @Test func theManagerGuideNamesSbHighlightAndTheHighlightTool() throws {
    let line = try #require(
      Manager.guide.split(separator: "\n").first { $0.contains("`sb highlight") }, "no `sb highlight` line")

    #expect(line.contains("`highlight`"), "\(line)")
    #expect(line.contains("--clear"), "\(line)")
    #expect(line.contains("Done"), "\(line)")
  }
}

/// The Manager guide teaches `sb parent` and the MCP `set_parent` tool, in the bullet after `sb highlight`.
extension ManagerTextTests {
  private var guideLines: [Substring] { Manager.guide.split(separator: "\n") }

  @Test func theManagerGuideNamesSbParentAndTheSetParentTool() throws {
    let line = try #require(guideLines.first { $0.contains("`sb parent") }, "no `sb parent` line")

    #expect(line.contains("`set_parent`"), "\(line)")
    #expect(line.contains("--clear"), "\(line)")
  }

  @Test func theSbParentBulletFollowsTheSbHighlightBullet() throws {
    let highlight = try #require(guideLines.firstIndex { $0.contains("`sb highlight") })
    let parent = try #require(guideLines.firstIndex { $0.contains("`sb parent") })

    #expect(parent == highlight + 1)
  }

  @Test func theServerHasTheSetParentToolThatTheManagerGuideNames() {
    #expect(MCPToolServer.allTools.contains { $0.name == "set_parent" })
  }
}

/// The Manager guide and the chat guide teach the brief form and the `full: true` argument that returns every field.
extension ManagerTextTests {
  @Test func theManagerGuidesCommandsNameTheBriefFlagAndTheFullArgument() throws {
    let guide = Manager.guide
    let start = try #require(guide.range(of: "## Commands"))
    let end = try #require(guide.range(of: "## What changed", range: start.upperBound..<guide.endIndex))

    let commands = guide[start.upperBound..<end.lowerBound]

    #expect(commands.contains("--brief`"), "\(commands)")
    #expect(commands.contains("`full: true`"), "\(commands)")
  }

  @Test func theChatGuideNamesTheFullArgument() {
    #expect(Chat.guide.contains("`full: true`"), "\(Chat.guide)")
  }
}
