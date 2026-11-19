import Foundation
import Testing

@testable import SwitchboardCore

/// The Manager guide's `## Work skills` section, and the README paragraph that describes the gate.
@Suite struct ManagerSkillGuideTests {
  /// The `## ` headings of the guide, in order.
  private var headings: [String] {
    Manager.guide.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
  }

  /// The text of the `## Work skills` section, up to the next heading.
  private func workSkills() throws -> Substring {
    let guide = Manager.guide
    let start = try #require(guide.range(of: "\n## Work skills\n"))
    let end = guide.range(of: "\n## ", range: start.upperBound..<guide.endIndex)?.lowerBound ?? guide.endIndex
    return guide[start.upperBound..<end]
  }

  @Test func theWorkSkillsSectionSitsBetweenHostsAndMCPServers() throws {
    let index = try #require(headings.firstIndex(of: "## Work skills"), "\(headings)")

    #expect(index > 0 && headings[index - 1] == "## Hosts", "\(headings)")
    #expect(index + 1 < headings.count && headings[index + 1] == "## MCP servers", "\(headings)")
  }

  @Test func theGuideHasOneWorkSkillsSection() {
    #expect(headings.filter { $0 == "## Work skills" }.count == 1)
  }

  @Test(arguments: ["/go", "sb new", "--prompt", "Skill tool", "sb manager skills"])
  func theWorkSkillsSectionNames(_ text: String) throws {
    let section = try workSkills()

    #expect(section.contains(text), "\(section)")
  }

  @Test func theWorkSkillsSectionSaysNotToReadABlockedSkillsFile() throws {
    #expect(try workSkills().contains("SKILL.md"))
  }

  @Test func theWorkSkillsSectionSaysToFollowTheSessionWithAWait() throws {
    #expect(try workSkills().contains("wait"))
  }

  // MARK: README

  private static let readme = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("README.md")

  /// The paragraphs of the README, split at blank lines.
  private func paragraphs() throws -> [String] {
    try String(contentsOf: Self.readme, encoding: .utf8).components(separatedBy: "\n\n")
  }

  /// The operator's paragraphs moved under `#### Background follow-through` at the end of The Manager (#410).
  @Test func theReadmeDescribesTheGateRightAfterTheQuickAskParagraph() throws {
    let all = try paragraphs()
    let ask = try #require(all.firstIndex { $0.hasPrefix("`sb ask <question>` answers") })

    let next = try #require(all.indices.contains(ask + 1) ? all[ask + 1] : nil)

    #expect(next.hasPrefix("A Manager conversation and the operator don't run work skills"), "\(next.prefix(120))")
  }

  @Test(arguments: [
    "skill-labels.json", "skill_unchecked", "skill_blocked", "sb manager skills", "--run-here", "managerSkills",
  ])
  func theReadmeGateParagraphNames(_ text: String) throws {
    let paragraph = try #require(
      try paragraphs().first { $0.hasPrefix("A Manager conversation and the operator don't run work skills") })

    #expect(paragraph.contains(text))
  }
}
