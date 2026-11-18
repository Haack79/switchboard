import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let targetID = "sdcs7r"
private let targetName = "docs-refresh"
private let otherID = "s3k9ap"
private let otherName = "fix-cache"
private let removedID = "sgcctv"
private let removedName = "old-flag-cleanup"
private let unknownID = "swxyz2"

private let names = SessionNames(
  live: [targetID: targetName, otherID: otherName], removed: [removedID: removedName])

private func sessionWait(on id: String, named name: String, note: String? = nil) -> Wait {
  Wait(
    id: "w1", kind: .session, session: Wait.SessionTarget(id: id, name: name), state: .done, note: note, created: 0)
}

/// The segments that a wait line's `InlineText` draws, as the side panel and the Details Waits section draw them.
private func segments(_ wait: Wait, names: SessionNames = names, links: Bool = true) -> [InlineText.Segment] {
  InlineText.segments(wait.lineText(names: names), names: names, repo: nil, links: links).0
}

private func segments(plain: String) -> [InlineText.Segment] {
  InlineText.segments(MarkdownText(stringLiteral: plain), names: names, repo: nil, links: true).0
}

private func segment(reading text: String, _ segments: [InlineText.Segment]) throws -> InlineText.Segment {
  try #require(segments.first { String($0.text.characters) == text }, "segments: \(segments.map(\.text))")
}

private func referents(_ segments: [InlineText.Segment]) -> [Referent] { segments.compactMap(\.reference?.referent) }

private func characters(_ segments: [InlineText.Segment]) -> String { String(InlineText.joined(segments).characters) }

private func allLinks(_ segments: [InlineText.Segment]) -> Set<URL?> {
  Set(InlineText.joined(segments).runs.map(\.link))
}

extension InlineTextTests {
  /// A session wait's line names the target session, and the name opens that session and its card.
  @Suite struct WaitLines {
    // MARK: A live target

    @Test func theTargetsNameGivesASessionReferentForTheTargetID() throws {
      let found = try segment(reading: targetName, segments(sessionWait(on: targetID, named: targetName)))

      #expect(found.reference?.referent == .session(.id(targetID)))
    }

    @Test func theTargetsNameLinksToTheTargetsIDURL() throws {
      let found = try segment(reading: targetName, segments(sessionWait(on: targetID, named: targetName)))

      #expect(Set(found.text.runs.map(\.link)) == [SessionLink.url(for: targetID)])
    }

    @Test func theTextAfterTheNameHasNoLink() throws {
      let found = try segment(reading: " to reach Done", segments(sessionWait(on: targetID, named: targetName)))

      #expect(found.reference == nil)
      #expect(Set(found.text.runs.map(\.link)) == [nil])
    }

    @Test func theLineReadsAsTheWaitLine() {
      let wait = sessionWait(on: targetID, named: targetName, note: "after the deploy")

      #expect(characters(segments(wait)) == wait.line)
    }

    /// A link run is never split, so a name that holds a reference or another session's id is one referent.
    @Test(arguments: ["fix o/r#1", otherID, "Fix `sb ls` *now* [x]"])
    func aNameWithAReferenceOrAnIDGivesOnlyTheTargetsReferent(_ name: String) throws {
      let found = segments(sessionWait(on: targetID, named: name))

      #expect(referents(found) == [.session(.id(targetID))])
      #expect(try segment(reading: name, found).reference?.referent == .session(.id(targetID)))
    }

    // MARK: The rest of the line

    @Test func anIdInTheNoteStillReadsAsItsLinkedName() {
      let found = segments(sessionWait(on: targetID, named: targetName, note: "ask \(otherID)"))

      #expect(referents(found) == [.session(.id(targetID)), .session(.id(otherID))])
      #expect(characters(found) == "\(targetName) to reach Done (ask \(otherName))")
    }

    @Test func aSessionLinkInTheNoteStillGivesItsOwnReferent() {
      let note = "see [b](switchboard://session/\(otherID))"

      let found = segments(sessionWait(on: targetID, named: targetName, note: note))

      #expect(referents(found) == [.session(.id(targetID)), .session(.id(otherID))])
    }

    @Test func aReferenceInTheNoteStillGivesItsOwnReferent() throws {
      let found = segments(sessionWait(on: targetID, named: targetName, note: "o/r#1"))

      #expect(
        referents(found) == [.session(.id(targetID)), .github(try #require(GitHubRef(parsing: "o/r#1")))])
    }

    // MARK: No link

    @Test(arguments: [(removedID, removedName), (unknownID, "gone-session")])
    func aWaitOnARemovedOrUnknownSessionGivesNoReferent(_ id: String, _ name: String) {
      #expect(referents(segments(sessionWait(on: id, named: name))).isEmpty)
    }

    @Test(arguments: [(removedID, removedName), (unknownID, "gone-session")])
    func aWaitOnARemovedOrUnknownSessionDrawsPlain(_ id: String, _ name: String) {
      let wait = sessionWait(on: id, named: name)

      let found = segments(wait)

      #expect(characters(found) == wait.line)
      #expect(allLinks(found) == [nil])
    }

    /// A non-session wait draws exactly as `InlineText(plain: wait.line)` draws it today.
    @Test(arguments: [
      Wait(id: "w1", kind: .ci, pr: Wait.PullRequest(number: 1204), created: 0),
      Wait(id: "w1", kind: .merge, pr: Wait.PullRequest(repository: "o/r", number: 7), created: 0),
      Wait(id: "w1", kind: .manual, note: "ask \(otherID) about \(targetName)", created: 0),
      Wait(
        id: "w1", kind: .ci, session: Wait.SessionTarget(id: targetID, name: targetName), note: targetName, created: 0),
    ])
    func aWaitOfAnotherKindDrawsAsItsPlainLine(_ wait: Wait) {
      let drawn = segments(wait)
      let plain = segments(plain: wait.line)

      #expect(InlineText.joined(drawn) == InlineText.joined(plain))
      #expect(referents(drawn) == referents(plain))
    }

    // MARK: Without links

    @Test func withoutLinksTheTargetsNameHasNoLinkOrReferent() {
      let found = segments(sessionWait(on: targetID, named: targetName), links: false)

      #expect(referents(found).isEmpty)
      #expect(allLinks(found) == [nil])
    }

    // MARK: Parity

    /// The wait links its target exactly when the same id written in text links, so both read liveness the same way.
    @Test(arguments: [targetID, otherID, removedID, unknownID])
    func aTargetLinksExactlyWhenItsIDInTextLinks(_ id: String) {
      let fromWait = referents(segments(sessionWait(on: id, named: "some-name")))
      let fromText = referents(segments(plain: id))

      #expect(fromWait == fromText)
    }
  }
}
