import Foundation
import Testing

@testable import SwitchboardCore

private func config(_ text: String) throws -> Config { try JSONCoding.decode(Config.self, from: text) }

private func settings(_ managerSkills: String) throws -> ManagerSkillSettings {
  try config(#"{"managerSkills": \#(managerSkills)}"#).managerSkills
}

/// The `managerSkills` section of config.json. Decoding never throws: a bad
/// value keeps its default, so a typo can't make sbd ignore all of config.json.
@Suite struct ConfigManagerSkillsTests {
  @Test func configWithoutManagerSkillsUsesHaikuThirtySecondsAndNoOverrides() throws {
    let s = try config("{}").managerSkills

    #expect(s.model == "haiku")
    #expect(s.timeoutSeconds == 30)
    #expect(s.work.isEmpty)
    #expect(s.safe.isEmpty)
  }

  @Test func readsTheModelTimeoutAndBothLists() throws {
    let s = try settings(#"{"model": "sonnet", "timeoutSeconds": 45, "work": ["go"], "safe": ["note"]}"#)

    #expect(s.model == "sonnet")
    #expect(s.timeoutSeconds == 45)
    #expect(s.work == ["go"])
    #expect(s.safe == ["note"])
  }

  @Test func aPartialSectionKeepsTheOtherDefaults() throws {
    let s = try settings(#"{"work": ["go"]}"#)

    #expect(s.model == "haiku")
    #expect(s.timeoutSeconds == 30)
    #expect(s.safe.isEmpty)
  }

  @Test(arguments: ["121", "600", "1e9"])
  func aTimeoutAbove120IsCappedAt120(_ value: String) throws {
    #expect(try settings(#"{"timeoutSeconds": \#(value)}"#).timeoutSeconds == 120)
  }

  @Test func aTimeoutOfExactly120IsKept() throws {
    #expect(try settings(#"{"timeoutSeconds": 120}"#).timeoutSeconds == 120)
  }

  @Test(arguments: [#""thirty""#, "true", "[30]", #"{"s": 30}"#, "-5", "0"])
  func aBadTimeoutKeepsTheDefault(_ value: String) throws {
    #expect(try settings(#"{"timeoutSeconds": \#(value)}"#).timeoutSeconds == 30)
  }

  @Test(arguments: ["5", "true", "[]", "{}"])
  func aModelThatIsNotAStringKeepsHaiku(_ value: String) throws {
    #expect(try settings(#"{"model": \#(value)}"#).model == "haiku")
  }

  @Test func aNonStringEntryIsSkippedAndTheRestKept() throws {
    let s = try settings(#"{"work": ["go", 3, null, {"a": 1}, ["x"], true, "ship"], "safe": [1, "note"]}"#)

    #expect(s.work == ["go", "ship"])
    #expect(s.safe == ["note"])
  }

  @Test(arguments: [#""go""#, "5", #"{"go": true}"#])
  func aListThatIsNotAnArrayKeepsTheEmptyDefault(_ value: String) throws {
    let s = try settings(#"{"work": \#(value), "safe": \#(value)}"#)

    #expect(s.work.isEmpty)
    #expect(s.safe.isEmpty)
  }

  @Test func aNameInBothListsIsDroppedFromBoth() throws {
    let s = try settings(#"{"work": ["go", "ship"], "safe": ["go", "note"]}"#)

    #expect(s.work == ["ship"])
    #expect(s.safe == ["note"])
  }

  @Test func aLeadingSlashIsDropped() throws {
    let s = try settings(#"{"work": ["/go"], "safe": ["/note"]}"#)

    #expect(s.work == ["go"])
    #expect(s.safe == ["note"])
  }

  /// The both-lists check compares names after the slash is dropped, so `/go` and `go` are one name.
  @Test(arguments: [(#"["/go"]"#, #"["go"]"#), (#"["go"]"#, #"["/go"]"#), (#"["/go"]"#, #"["/go"]"#)])
  func aNameInBothListsWithOrWithoutASlashIsDroppedFromBoth(_ work: String, _ safe: String) throws {
    let s = try settings(#"{"work": \#(work), "safe": \#(safe)}"#)

    #expect(s.work.isEmpty)
    #expect(s.safe.isEmpty)
  }

  @Test func aPluginNameKeepsItsColon() throws {
    #expect(try settings(#"{"work": ["/plugin:review"]}"#).work == ["plugin:review"])
  }

  @Test(arguments: [#""all""#, "5", "[]", "true"])
  func aSectionThatIsNotAnObjectKeepsEveryDefault(_ value: String) throws {
    let s = try settings(value)

    #expect(s.model == "haiku")
    #expect(s.timeoutSeconds == 30)
    #expect(s.work.isEmpty)
    #expect(s.safe.isEmpty)
  }

  @Test func aBadSectionLeavesTheRestOfTheConfigRead() throws {
    let c = try config(#"{"managerSkills": {"timeoutSeconds": "x", "work": [1]}, "liveCap": 7}"#)

    #expect(c.liveCap == 7)
  }
}
