import Foundation
import Testing

@testable import SwitchboardCore

/// `SkillCommand` finds the skill that a prompt or a tool call loads, as D14 of the plan defines it.
@Suite struct SkillCommandTests {
  // MARK: Prompts

  @Test(
    arguments: [
      ("/go", "go"),
      ("/go x", "go"),
      ("  /go x", "go"),
      ("\t/go", "go"),
      ("/go\nmore", "go"),
      ("/go\tx", "go"),
      ("/go --yolo https://github.com/o/r/issues/1", "go"),
      ("/p:s y", "p:s"),
      ("/plugin-name:skill_name.v2 args", "plugin-name:skill_name.v2"),
      ("/GO", "GO"),
      ("/a", "a"),
    ] as [(String, String)])
  func aPromptThatStartsWithACommandNamesIt(_ prompt: String, _ name: String) {
    #expect(SkillCommand.name(inPrompt: prompt) == name)
  }

  @Test(arguments: [
    "/Users/x",
    "/Users/x/notes.md",
    "//go",
    "/ go",
    "/",
    "",
    "   ",
    "hello /go",
    "go",
    "/go!",
    "/go/x",
    "/go,",
    "x\n/go",
  ])
  func aPromptWithoutACommandOnItsFirstLineNamesNone(_ prompt: String) {
    #expect(SkillCommand.name(inPrompt: prompt) == nil)
  }

  @Test func matchingIsCaseSensitive() {
    #expect(SkillCommand.name(inPrompt: "/GO") != "go")
  }

  // MARK: Tool calls

  @Test(
    arguments: [
      (["skill": "go"], "go"),
      (["skill": "/go"], "go"),
      (["skill": "p:s"], "p:s"),
      (["skill": "go", "args": "--yolo"], "go"),
      (["skill": " go "], "go"),
    ] as [(JSON, String)])
  func theSkillToolNamesItsSkill(_ input: JSON, _ name: String) {
    #expect(SkillCommand.name(inToolCall: "Skill", input: input) == name)
  }

  @Test(arguments: [[:], ["skill": 3], ["skill": ""], ["command": "/go"], .null] as [JSON])
  func aSkillCallWithoutASkillNameNamesNone(_ input: JSON) {
    #expect(SkillCommand.name(inToolCall: "Skill", input: input) == nil)
  }

  @Test func aSkillCallWithNoInputNamesNone() {
    #expect(SkillCommand.name(inToolCall: "Skill", input: nil) == nil)
  }

  @Test(
    arguments: [
      ("/go x", "go"),
      ("  /p:s", "p:s"),
      ("/go\nmore", "go"),
    ] as [(String, String)])
  func theLegacySlashCommandToolNamesItsCommandLikeAPrompt(_ command: String, _ name: String) {
    #expect(SkillCommand.name(inToolCall: "SlashCommand", input: ["command": .string(command)]) == name)
  }

  @Test(arguments: ["go", "/Users/x", "//go", "/ go", ""])
  func aLegacySlashCommandCallWithoutACommandNamesNone(_ command: String) {
    #expect(SkillCommand.name(inToolCall: "SlashCommand", input: ["command": .string(command)]) == nil)
  }

  @Test(
    arguments: [
      ("Bash", ["command": "/go"]),
      ("Read", ["file_path": "/Users/x/.claude/skills/go/SKILL.md"]),
      ("Agent", ["prompt": "/go x"]),
      ("skill", ["skill": "go"]),
      ("", ["skill": "go"]),
    ] as [(String, JSON)])
  func anotherToolNamesNoSkill(_ tool: String, _ input: JSON) {
    #expect(SkillCommand.name(inToolCall: tool, input: input) == nil)
  }

  // MARK: Resolving a typed name

  /// A name with a `:` is never a bare name. So `x:s` doesn't load `p:x:s`.
  @Test func aNameWithAColonResolvesOnlyToItself() {
    #expect(SkillCommand.resolve("x:s", among: ["p:x:s"]) == nil)
    #expect(SkillCommand.resolve("p:s", among: ["p:s"]) == "p:s")
  }

  @Test func aBareNameResolvesToTheOneNameWhosePartAfterTheFirstColonMatches() {
    #expect(SkillCommand.resolve("s", among: ["p:s", "p:ss", "s:p"]) == "p:s")
    #expect(SkillCommand.resolve("s", among: ["sp:s2"]) == nil)
  }
}
