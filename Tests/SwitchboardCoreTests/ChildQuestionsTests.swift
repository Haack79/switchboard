import Foundation
import Testing

@testable import SwitchboardCore

/// The part of a guide under `heading`, up to the next `## ` heading.
private func section(_ heading: String, of guide: String) throws -> String {
  let start = try #require(guide.range(of: heading))
  let rest = guide[start.upperBound...]
  return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
}

/// The lines of a prompt that are bullets.
private func bullets(_ text: String) -> [String] {
  text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
}

@Suite struct ChildQuestionsGuidanceTests {
  let guidance = ChildQuestions.guidance.lowercased()

  @Test func saysToLinkToTheSessionWithASessionLink() {
    #expect(guidance.contains("switchboard://session/"), "\(ChildQuestions.guidance)")
  }

  @Test(arguments: ["merge", "worktree", "several sessions"])
  func saysAParentStillAsksItsOwnDecisions(_ decision: String) {
    #expect(guidance.contains(decision), "\(ChildQuestions.guidance)")
  }

  @Test func isOneParagraph() {
    #expect(!ChildQuestions.guidance.contains("\n"), "\(ChildQuestions.guidance)")
  }

  @Test func theManagerGuideRulesIncludeTheGuidance() throws {
    #expect(try section("## Rules", of: Manager.guide).contains(ChildQuestions.guidance))
  }

  @Test func theChatGuideRulesIncludeTheGuidance() throws {
    #expect(try section("## Rules", of: Chat.guide).contains(ChildQuestions.guidance))
  }

  @Test func theDefaultSystemPromptIncludesTheGuidance() {
    #expect(TriageSettings().systemPrompt.contains(ChildQuestions.guidance))
  }

  @Test func theSystemPromptsThreeOrMoreRuleCoversOnlyDecisionsOfYourOwn() throws {
    let prompt = TriageSettings().systemPrompt
    let sentences = prompt.components(separatedBy: ". ")

    let rule = try #require(sentences.first { $0.contains("three or more") }, "\(prompt)")

    #expect(rule.contains("your own"), "\(rule)")
  }

  @Test func theOperatorPromptReportsAChildsOwnQuestionAsALinkedLineWithoutNeedsYou() throws {
    let prompt = Manager.operatorPrompt

    let bullet = try #require(bullets(prompt).first { $0.contains("Needs you") }, "\(prompt)")

    let lower = bullet.lowercased()
    #expect(lower.contains("link"), "\(bullet)")
    #expect(lower.contains("one line") || lower.contains("one-line"), "\(bullet)")
    #expect(bullet.contains("`needsYou`"), "\(bullet)")
    #expect(["don't", "do not", "without", "never"].contains { lower.contains($0) }, "\(bullet)")
  }

  @Test func theOperatorPromptKeepsNeedsYouForTheOperatorsOwnDecision() throws {
    let prompt = Manager.operatorPrompt

    let bullet = try #require(bullets(prompt).first { $0.contains("`--needs-you`") }, "\(prompt)")

    #expect(bullet.contains("your own") || bullet.contains("own decision"), "\(bullet)")
  }

  @Test func theSummaryHelpSaysDecisionsHoldsOnlyYourOwnDecisions() throws {
    let lines = TriageCard.instructions.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = try #require(lines.firstIndex { $0.hasPrefix("decisions ") }, "\(TriageCard.instructions)")
    let field = ([lines[start]] + lines[(start + 1)...].prefix { $0.hasPrefix(" ") }).joined(separator: "\n")

    let lower = field.lowercased()

    #expect(lower.contains("your own"), "\(field)")
    #expect(lower.contains("child") || lower.contains("you started"), "\(field)")
  }
}
