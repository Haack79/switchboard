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
