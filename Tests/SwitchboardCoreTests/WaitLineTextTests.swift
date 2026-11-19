import Foundation
import Testing

@testable import SwitchboardCore

private let targetID = "sdcs7r"
private let targetName = "docs-refresh"
private let otherID = "s3k9ap"
private let otherName = "fix-cache"
private let removedID = "sgcctv"
private let removedName = "old-flag-cleanup"
private let unknownID = "swxyz2"

private let names = SessionNames(
  live: [targetID: targetName, otherID: otherName], removed: [removedID: removedName])

private func sessionWait(
  _ target: Wait.SessionTarget?, state: AttentionState? = .done, note: String? = nil
) -> Wait {
  Wait(id: "w1", kind: .session, session: target, state: state, note: note, created: 0)
}

private func sessionWait(on id: String, named name: String, state: AttentionState? = .done, note: String? = nil)
  -> Wait
{
  sessionWait(Wait.SessionTarget(id: id, name: name), state: state, note: note)
}

private func linkRun(_ name: String, _ id: String) -> MarkdownText.Run {
  MarkdownText.Run(name, link: SessionLink.url(for: id).absoluteString)
}

/// The wait line as the app draws it: a session wait's target name links to the target session from the wait's own
/// target id, never from matching the line's text.
@Suite struct WaitLineTextTests {
  // MARK: A live target

  @Test func aSessionWaitOnALiveSessionLinksTheNameToTheTargetID() {
    let wait = sessionWait(on: targetID, named: targetName)

    let text = wait.lineText(names: names)

    #expect(text == MarkdownText([linkRun(targetName, targetID), MarkdownText.Run(" to reach Done")]))
  }

  @Test(arguments: AttentionState.allCases)
  func theTextAfterTheNameReadsAsTheWaitLineDoes(_ state: AttentionState) {
    let wait = sessionWait(on: targetID, named: targetName, state: state)

    let text = wait.lineText(names: names)

    #expect(text.runs.dropFirst() == [MarkdownText.Run(" to reach \(state.title)")])
  }

  @Test func aNoteStaysInTheUnlinkedRunAfterTheName() {
    let wait = sessionWait(on: targetID, named: targetName, note: "after the deploy")

    let text = wait.lineText(names: names)

    #expect(
      text == MarkdownText([linkRun(targetName, targetID), MarkdownText.Run(" to reach Done (after the deploy)")]))
  }

  /// The wait keeps the name it had when the wait was set. sbd writes that name, and the app draws the line as
  /// written.
  @Test func aRenamedTargetKeepsTheNameTheWaitRecorded() {
    let wait = sessionWait(on: targetID, named: "docs-refresh-old")

    let text = wait.lineText(names: names)

    #expect(text.runs.first == linkRun("docs-refresh-old", targetID))
  }

  /// The link goes to the wait's target id even when the recorded name is another live session's name.
  @Test func aNameThatIsAnotherSessionsNameLinksToTheTargetID() {
    let wait = sessionWait(on: targetID, named: otherName)

    let text = wait.lineText(names: names)

    #expect(text.runs.first == linkRun(otherName, targetID))
  }

  /// Manager and chat names can hold Markdown characters. The line is built as runs, so no Markdown in the name is
  /// parsed or escaped.
  @Test(arguments: ["Fix `sb ls` *now* [x]", "a_b <c> & d", "Fix CI chat", "posthog-code/flag-evaluations-table"])
  func aNameWithMarkdownOrSpacesIsOneLinkRunAsWritten(_ name: String) {
    let wait = sessionWait(on: targetID, named: name)

    let text = wait.lineText(names: names)

    #expect(text.runs.first == linkRun(name, targetID))
  }

  /// U+0600 is a prepend character, so it joins the space after it in one `Character`. The split still falls where
  /// the name ends.
  @Test func aNameEndingInAPrependCharacterKeepsTheSpaceAfterIt() {
    let name = "build\u{0600}"
    let wait = sessionWait(on: targetID, named: name)

    let text = wait.lineText(names: names)

    #expect(text == MarkdownText([linkRun(name, targetID), MarkdownText.Run(" to reach Done")]))
  }

  @Test func aNameThatSpellsAnotherSessionsIDLinksToTheTargetID() {
    let wait = sessionWait(on: targetID, named: otherID)

    let text = wait.lineText(names: names)

    #expect(text.runs.first == linkRun(otherID, targetID))
  }

  // MARK: No link

  @Test func aSessionWaitOnARemovedSessionDrawsAsTheWaitLine() {
    let wait = sessionWait(on: removedID, named: removedName)

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  @Test func aSessionWaitOnAnUnknownSessionDrawsAsTheWaitLine() {
    let wait = sessionWait(on: unknownID, named: "gone-session")

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  @Test func withAnEmptyDirectoryASessionWaitDrawsAsTheWaitLine() {
    let wait = sessionWait(on: targetID, named: targetName)

    #expect(wait.lineText(names: .empty) == MarkdownText(stringLiteral: wait.line))
  }

  @Test func aSessionWaitWithNoTargetDrawsAsTheWaitLine() {
    let wait = sessionWait(nil)

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  /// An empty link run would draw nothing to click.
  @Test func aSessionWaitWithAnEmptyNameDrawsAsTheWaitLine() {
    let wait = sessionWait(on: targetID, named: "")

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  static let otherKinds: [Wait] = [
    Wait(id: "w1", kind: .ci, pr: Wait.PullRequest(number: 1204), created: 0),
    Wait(id: "w1", kind: .review, pr: Wait.PullRequest(number: 1204), who: "alex", created: 0),
    Wait(id: "w1", kind: .botReview, who: "copilot", created: 0),
    Wait(id: "w1", kind: .approval, pr: Wait.PullRequest(repository: "o/r", number: 7), who: "sam", created: 0),
    Wait(id: "w1", kind: .queue, created: 0),
    Wait(id: "w1", kind: .merge, pr: Wait.PullRequest(number: 1190), created: 0),
    Wait(id: "w1", kind: .deploy, environment: "prod-us", service: "web", created: 0),
    Wait(id: "w1", kind: .date, until: 1_800_000_000_000, created: 0),
    Wait(id: "w1", kind: .manual, until: 1_800_000_000_000, note: "check \(targetName)", created: 0),
    Wait(id: "w1", kind: .ci, note: "\(targetName) first", created: 0),
  ]

  @Test(arguments: otherKinds)
  func aWaitOfAnotherKindDrawsAsTheWaitLine(_ wait: Wait) {
    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  /// Only a `session` wait names its target in the line, so a target on another kind links nothing.
  @Test(arguments: [Wait.Kind.ci, .merge, .date, .manual])
  func aWaitOfAnotherKindThatCarriesALiveSessionTargetDrawsAsTheWaitLine(_ kind: Wait.Kind) {
    let wait = Wait(
      id: "w1", kind: kind, pr: Wait.PullRequest(number: 1204),
      session: Wait.SessionTarget(id: targetID, name: targetName),
      until: 1_800_000_000_000, note: "for \(targetName)", created: 0)

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  /// `handedFrom` names a Manager conversation, which the line never shows.
  @Test func aHandedFromConversationDoesNotLink() {
    var wait = Wait(id: "w1", kind: .ci, pr: Wait.PullRequest(number: 1204), created: 0)
    wait.handedFrom = Wait.SessionTarget(id: targetID, name: targetName)

    #expect(wait.lineText(names: names) == MarkdownText(stringLiteral: wait.line))
  }

  // MARK: Parity

  static let everyWait: [Wait] =
    otherKinds + [
      sessionWait(on: targetID, named: targetName),
      sessionWait(on: targetID, named: targetName, state: .needsYou, note: "ask \(otherID)"),
      sessionWait(on: targetID, named: "Fix `sb ls` *now* [x]"),
      sessionWait(on: removedID, named: removedName),
      sessionWait(on: unknownID, named: "gone-session"),
      sessionWait(on: targetID, named: ""),
      sessionWait(nil),
    ]

  /// The drawn text never changes a character of the line that sbd's `Wait.line` gives.
  @Test(arguments: everyWait)
  func theTextReadsAsTheWaitLine(_ wait: Wait) {
    #expect(wait.lineText(names: names).plain == wait.line)
  }

  /// A wait links its target exactly when the same id written in text would link: a live entry in the directory.
  @Test(arguments: [(targetID, true), (otherID, true), (removedID, false), (unknownID, false)])
  func aTargetLinksExactlyWhenItsIDIsLive(_ id: String, _ live: Bool) {
    let wait = sessionWait(on: id, named: "some-name")

    let linked = wait.lineText(names: names).runs.contains { $0.link != nil }

    #expect(linked == live)
  }
}
