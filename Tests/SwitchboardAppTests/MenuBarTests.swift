import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The menu bar item cuts the Inbox line at `Triage.titleLength`, because a rule title can reach 100 characters.
@Suite struct MenuBarTitle {
  @Test func aLineOfSixtyCharactersStaysWhole() {
    let line = String(repeating: "a", count: Triage.titleLength)

    #expect(MenuBarContent.title(name: "flag-cache", line: line) == "flag-cache: \(line)")
  }

  @Test func aLongerLineIsCutToSixtyCharactersWithAnEllipsis() {
    let line = String(repeating: "a", count: Triage.titleLength + 1)

    #expect(
      MenuBarContent.title(name: "flag-cache", line: line)
        == "flag-cache: \(String(repeating: "a", count: Triage.titleLength - 1))…")
  }

  @Test func aHundredCharacterRuleTitleIsCut() {
    let line = "A review from PostHog/clickhouse on #135173: still open after 1d, and a lot more words after that"

    let title = MenuBarContent.title(name: "s", line: line)

    #expect(title == "s: " + truncated(line, max: Triage.titleLength))
  }

  /// Only the line is cut, so a long name keeps the line's 60 characters.
  @Test func theNameDoesNotCountTowardTheCut() {
    let name = String(repeating: "n", count: 40)
    let line = String(repeating: "a", count: Triage.titleLength)

    #expect(MenuBarContent.title(name: name, line: line) == "\(name): \(line)")
  }
}
