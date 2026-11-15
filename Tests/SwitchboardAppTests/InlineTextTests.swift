import Foundation
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct InlineTextTests {
  /// Emphasis, code, a link, and a footnote, with no session id.
  static let styled = MarkdownText([
    MarkdownText.Run("Read "), MarkdownText.Run("this", .emphasis), MarkdownText.Run(", run "),
    MarkdownText.Run("sb ls", .code), MarkdownText.Run(", see "),
    MarkdownText.Run("the docs", link: "https://example.com/docs"), MarkdownText.Run("."),
    MarkdownText.Run("1", .footnote),
  ])

  @Test func attributedKeepsEmphasisCodeLinksAndFootnotes() {
    let result = Self.styled.attributed

    var emphasis = AttributedString("this")
    emphasis.inlinePresentationIntent = .emphasized
    var code = AttributedString("sb ls")
    code.inlinePresentationIntent = .code
    var link = AttributedString("the docs")
    link.link = URL(string: "https://example.com/docs")
    var footnote = AttributedString("1")
    footnote.baselineOffset = 6
    footnote.font = .caption2
    var expected = AttributedString("Read ")
    expected += emphasis
    expected += AttributedString(", run ")
    expected += code
    expected += AttributedString(", see ")
    expected += link
    expected += AttributedString(".")
    expected += footnote
    #expect(result == expected)
  }

  /// Plain text keeps Markdown syntax as literal characters.
  @Test(arguments: ["**x**", "[a](https://example.com)", "`c`", "<a href=\"x\">y</a>", "one\ntwo", "_y_ ~z~", ""])
  func plainKeepsTheTextVerbatim(_ s: String) {
    #expect(MarkdownText(stringLiteral: s).attributed == AttributedString(s))
  }
}

// MARK: - Session names

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let removedID = "sgcctv"
private let removedName = "old-flag-cleanup"
private let otherID = "s3k9ap"
private let otherName = "flag-cache-race"

private let names = SessionNames(
  live: [liveID: liveName, otherID: otherName], removed: [removedID: removedName])
private let noNames = SessionNames(live: [:], removed: [:])

private func render(_ text: MarkdownText, names: SessionNames = names, repo: String? = nil, links: Bool = true) -> (
  text: AttributedString, help: String?
) {
  let (attributed, help) = InlineText.attributed(text, names: names, repo: repo, links: links)
  return (attributed, help)
}

private func render(plain: String, names: SessionNames = names, repo: String? = nil, links: Bool = true) -> (
  text: AttributedString, help: String?
) {
  render(MarkdownText(stringLiteral: plain), names: names, repo: repo, links: links)
}

/// Each distinct link in the part of `text` that reads `substring`, nil for a run with no link.
private func links(in text: AttributedString, of substring: String) throws -> Set<URL?> {
  let range = try #require(text.range(of: substring))
  return Set(text[range].runs.map { $0.link })
}

/// Each distinct link anywhere in `text`.
private func allLinks(_ text: AttributedString) -> Set<URL?> { Set(text.runs.map { $0.link }) }

extension InlineTextTests {
  @Suite struct Names {
    // MARK: Links

    @Test func aLiveIdReadsAsTheSessionsName() {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(String(result.text.characters) == "Ask \(liveName) to rebase.")
    }

    @Test func aLiveNameLinksToTheSessionURL() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: liveName) == [URL(string: "switchboard://session/\(liveID)")])
    }

    @Test func aLiveNameLinksToTheURLThatSessionLinkMakes() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
    }

    @Test func theTextAroundALiveNameHasNoLink() throws {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(try links(in: result.text, of: "Ask ") == [nil])
      #expect(try links(in: result.text, of: " to rebase.") == [nil])
    }

    @Test func twoLiveIdsEachLinkToTheirOwnSession() throws {
      let result = render(plain: "\(liveID),\(otherID)")

      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
      #expect(try links(in: result.text, of: otherName) == [SessionLink.url(for: otherID)])
    }

    @Test func aRemovedIdReadsAsItsNameWithNoLink() {
      let result = render(plain: "Ask \(removedID) to rebase.")

      #expect(String(result.text.characters) == "Ask \(removedName) to rebase.")
      #expect(allLinks(result.text) == [nil])
    }

    @Test func withoutLinksALiveIdReadsAsItsNameWithNoLink() {
      let result = render(plain: "Ask \(liveID) to rebase.", links: false)

      #expect(String(result.text.characters) == "Ask \(liveName) to rebase.")
      #expect(allLinks(result.text) == [nil])
    }

    @Test func aCollapsedNameAndIdLinksOnce() throws {
      let result = render(plain: "\(liveName) (\(liveID)) is done")

      #expect(String(result.text.characters) == "\(liveName) is done")
      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
    }

    @Test func anUnknownLookAlikeWordStaysAsWrittenWithNoLink() {
      let result = render(plain: "stream the switch to sgxxxx")

      #expect(String(result.text.characters) == "stream the switch to sgxxxx")
      #expect(allLinks(result.text) == [nil])
    }

    /// A Markdown link keeps its own URL, so the window's handler passes it to the browser.
    @Test func aMarkdownLinkWhoseTextIsAnIdKeepsItsTextAndURL() {
      let text = MarkdownText([MarkdownText.Run(liveID, link: "https://example.com/x")])

      let result = render(text)

      #expect(String(result.text.characters) == liveID)
      #expect(allLinks(result.text) == [URL(string: "https://example.com/x")])
    }

    // MARK: Styles

    @Test func aStrongIdKeepsItsStrongStyleAndLinks() throws {
      let text = MarkdownText([MarkdownText.Run("Ask "), MarkdownText.Run(liveID, .strong)])

      let result = render(text)

      let range = try #require(result.text.range(of: liveName))
      #expect(result.text[range].inlinePresentationIntent == .stronglyEmphasized)
      #expect(result.text[range].link == SessionLink.url(for: liveID))
    }

    @Test func anExactIdCodeSpanDropsTheCodeStyle() throws {
      let text = MarkdownText([MarkdownText.Run("Ask "), MarkdownText.Run(liveID, .code)])

      let result = render(text)

      let range = try #require(result.text.range(of: liveName))
      #expect(result.text[range].inlinePresentationIntent?.contains(.code) != true)
    }

    @Test func aCommandCodeSpanStaysAsWritten() {
      let text = MarkdownText([MarkdownText.Run("sb send \(liveID) hi", .code)])

      let result = render(text)

      var expected = AttributedString("sb send \(liveID) hi")
      expected.inlinePresentationIntent = .code
      #expect(result.text == expected)
    }

    // MARK: Unchanged output

    @Test(arguments: [true, false])
    func aTextWithoutIdsDrawsLikeMarkdownTextAttributed(_ links: Bool) {
      let result = render(InlineTextTests.styled, links: links)

      #expect(result.text == InlineTextTests.styled.attributed)
    }

    /// With no names to resolve, the text draws exactly as `MarkdownText.attributed` draws it.
    @Test func anEmptyDirectoryDrawsTheTextAsWritten() {
      let text = MarkdownText(stringLiteral: "Ask \(liveID) to rebase.")

      let result = render(text, names: noNames)

      #expect(result.text == text.attributed)
    }

    @Test func anEmptyDirectoryAddsNoHelp() {
      let result = render(plain: "Ask \(liveID) to rebase.", names: noNames)

      #expect(result.help == nil)
    }

    // MARK: Parity

    /// The same text with and without links gives the same characters.
    @Test(arguments: [
      "Ask \(liveID) to rebase.",
      "\(liveName) (\(liveID)) is done",
      "\(liveID) (\(liveName)) is done",
      "The dotfiles session (\(liveID))",
      "\(liveID),\(otherID) and \(removedID).",
      "\(liveID)'s PR",
      "sessions/\(liveID)/claude.sh",
      "stream",
      "",
    ])
    func withAndWithoutLinksGiveTheSameCharacters(_ s: String) {
      let linked = render(plain: s, links: true)
      let unlinked = render(plain: s, links: false)

      #expect(String(linked.text.characters) == String(unlinked.text.characters))
    }

    @Test(arguments: [
      "Ask \(liveID) to rebase.",
      "\(liveName) (\(liveID)) is done",
      "\(liveID),\(otherID) and \(removedID).",
      "sessions/\(liveID)/claude.sh",
    ])
    func linkedCharactersMatchThePlainTextPath(_ s: String) {
      let linked = render(plain: s, links: true)

      #expect(String(linked.text.characters) == names.replacingIDs(in: s))
    }

    // MARK: Help

    @Test func helpNamesALiveSessionAndItsId() {
      let result = render(plain: "Ask \(liveID) to rebase.")

      #expect(result.help == "\(liveName): \(liveID)")
    }

    @Test func helpMarksARemovedSession() {
      let result = render(plain: "Ask \(removedID) to rebase.")

      #expect(result.help == "\(removedName): \(removedID), removed")
    }

    /// Assumes the lines follow the order in which each session first appears.
    @Test func helpListsEachSessionOnItsOwnLine() {
      let result = render(plain: "\(liveID) waits on \(removedID) and \(otherID)")

      #expect(
        result.help
          == "\(liveName): \(liveID)\n\(removedName): \(removedID), removed\n\(otherName): \(otherID)")
    }

    /// Assumes a session that the text names twice gets one line.
    @Test func helpListsARepeatedSessionOnce() {
      let result = render(plain: "\(liveID) then \(liveID) again")

      #expect(result.help == "\(liveName): \(liveID)")
    }

    @Test func aTextWithNoMatchHasNoHelp() {
      let result = render(plain: "stream the switch to sgxxxx")

      #expect(result.help == nil)
    }

    @Test func withoutLinksThereIsNoHelp() {
      let result = render(plain: "Ask \(liveID) to rebase.", links: false)

      #expect(result.help == nil)
    }

    // MARK: Environment

    /// A view whose host never sets `sessionNames` draws ids as written.
    @Test func theEnvironmentDirectoryStartsEmpty() {
      #expect(EnvironmentValues().sessionNames == SessionNames(live: [:], removed: [:]))
    }
  }
}

// MARK: - References

/// The repository that a bare `#N` refers to in these tests.
private let contextRepo = "haacked/switchboard"

private func url(_ string: String) -> URL? { URL(string: string) }

extension InlineTextTests {
  @Suite struct References {
    // MARK: Bare #N

    @Test func aBareNumberWithAContextLinksToTheContextRepositorysIssue() throws {
      let result = render(plain: "Fix #1 first.", repo: contextRepo)

      #expect(try links(in: result.text, of: "#1") == [url("https://github.com/haacked/switchboard/issues/1")])
    }

    @Test func theTextAroundABareNumberHasNoLink() throws {
      let result = render(plain: "Fix #1 first.", repo: contextRepo)

      #expect(try links(in: result.text, of: "Fix ") == [nil])
      #expect(try links(in: result.text, of: " first.") == [nil])
    }

    @Test func aBareNumberWithoutAContextHasNoLink() {
      let result = render(plain: "Fix #1 first.")

      #expect(allLinks(result.text) == [nil])
    }

    /// Assumes that an invalid context repository acts as no context, as `InlineMentions` does.
    @Test(arguments: ["", "nope", "1/2", "o/r/x", "o r/x", "-/r"])
    func aBareNumberWithAnInvalidContextHasNoLink(_ repo: String) {
      let result = render(plain: "Fix #1 first.", repo: repo)

      #expect(allLinks(result.text) == [nil])
    }

    @Test(arguments: ["a#1", "&#123;", "/#1", "##1", "x.#1", "#12.5", "#12:30", "#12-fix", "#12a", "#0", "#01"])
    func aNumberThatIsNotABareReferenceHasNoLink(_ s: String) {
      let result = render(plain: s, repo: contextRepo)

      #expect(allLinks(result.text) == [nil])
    }

    // MARK: owner/name#N

    @Test func anOwnerNameReferenceLinksWithoutAContext() throws {
      let result = render(plain: "See o/r#1.")

      #expect(try links(in: result.text, of: "o/r#1") == [url("https://github.com/o/r/issues/1")])
    }

    @Test func anOwnerNameReferenceLinksToItsOwnRepositoryNotTheContext() throws {
      let result = render(plain: "See o/r#1.", repo: contextRepo)

      #expect(try links(in: result.text, of: "o/r#1") == [url("https://github.com/o/r/issues/1")])
    }

    // MARK: URLs

    @Test func aPullFilesURLInPlainTextLinksToItself() throws {
      let result = render(plain: "See https://github.com/o/r/pull/1/files.")

      #expect(
        try links(in: result.text, of: "https://github.com/o/r/pull/1/files")
          == [url("https://github.com/o/r/pull/1/files")])
    }

    @Test func aURLInPlainTextKeepsItsFragmentInTheLink() throws {
      let link = "https://github.com/o/r/issues/1#issuecomment-1"

      let result = render(plain: "See \(link) now")

      #expect(try links(in: result.text, of: link) == [url(link)])
    }

    @Test func anHttpURLInPlainTextLinksToHttps() throws {
      let result = render(plain: "See http://github.com/o/r/pull/1 now")

      #expect(try links(in: result.text, of: "http://github.com/o/r/pull/1") == [url("https://github.com/o/r/pull/1")])
    }

    // MARK: Existing links

    @Test func aGitHubMarkdownLinkKeepsItsOwnURL() {
      let link = "https://github.com/o/r/pull/1#discussion_r1"
      let text = MarkdownText([MarkdownText.Run("the fix", link: link)])

      let result = render(text, repo: contextRepo)

      #expect(String(result.text.characters) == "the fix")
      #expect(allLinks(result.text) == [url(link)])
    }

    @Test func aMarkdownLinkWhoseTextIsABareNumberKeepsItsURL() {
      let text = MarkdownText([MarkdownText.Run("#1", link: "https://example.com/x")])

      let result = render(text, repo: contextRepo)

      #expect(allLinks(result.text) == [url("https://example.com/x")])
    }

    // MARK: No link

    @Test(arguments: ["Fix #1.", "See o/r#1.", "See https://github.com/o/r/pull/1/files."])
    func withoutLinksAReferenceHasNoLink(_ s: String) {
      let result = render(plain: s, repo: contextRepo, links: false)

      #expect(allLinks(result.text) == [nil])
    }

    @Test func withoutLinksAGitHubMarkdownLinkHasNoLink() {
      let text = MarkdownText([MarkdownText.Run("the fix", link: "https://github.com/o/r/pull/1")])

      let result = render(text, repo: contextRepo, links: false)

      #expect(allLinks(result.text) == [nil])
    }

    /// Only a reference loses its link. Any other Markdown link keeps it.
    @Test func withoutLinksAnotherMarkdownLinkKeepsItsURL() {
      let text = MarkdownText([MarkdownText.Run("docs", link: "https://example.com/x")])

      let result = render(text, repo: contextRepo, links: false)

      #expect(allLinks(result.text) == [url("https://example.com/x")])
    }

    @Test(arguments: ["#1", "o/r#1", "https://github.com/o/r/pull/1", "see #1 and o/r#2"])
    func aCodeSpanReferenceHasNoLink(_ s: String) {
      let text = MarkdownText([MarkdownText.Run("Run "), MarkdownText.Run(s, .code)])

      let result = render(text, repo: contextRepo)

      #expect(allLinks(result.text) == [nil])
    }

    @Test func aCodeSpanReferenceKeepsTheCodeStyle() throws {
      let text = MarkdownText([MarkdownText.Run("Run "), MarkdownText.Run("#1", .code)])

      let result = render(text, repo: contextRepo)

      let range = try #require(result.text.range(of: "#1"))
      #expect(result.text[range].inlinePresentationIntent == .code)
    }

    // MARK: Text and style

    @Test(arguments: [nil, contextRepo] as [String?])
    func aReferenceKeepsItsTextAsWritten(_ repo: String?) {
      let s = "Fix #1, o/r#2 and https://github.com/o/r/pull/3/files."

      let result = render(plain: s, repo: repo)

      #expect(String(result.text.characters) == s)
    }

    @Test func aStrongReferenceKeepsItsStrongStyleAndLinks() throws {
      let text = MarkdownText([MarkdownText.Run("Fix "), MarkdownText.Run("#1", .strong)])

      let result = render(text, repo: contextRepo)

      let range = try #require(result.text.range(of: "#1"))
      #expect(result.text[range].inlinePresentationIntent == .stronglyEmphasized)
      #expect(result.text[range].link == url("https://github.com/haacked/switchboard/issues/1"))
    }

    // MARK: Help

    /// Assumes that the tooltip lists sessions only, so a text with only references has none.
    @Test func aReferenceAddsNoHelp() {
      let result = render(plain: "Fix #1 and o/r#2.", repo: contextRepo)

      #expect(result.help == nil)
    }

    @Test func helpWithAReferenceNamesOnlyTheSession() {
      let result = render(plain: "Ask \(liveID) about #1.", repo: contextRepo)

      #expect(result.help == "\(liveName): \(liveID)")
    }

    // MARK: Sessions

    @Test func aSessionAndAReferenceInOneTextEachLinkToTheirOwnTarget() throws {
      let result = render(plain: "Ask \(liveID) about #1.", repo: contextRepo)

      #expect(try links(in: result.text, of: liveName) == [SessionLink.url(for: liveID)])
      #expect(try links(in: result.text, of: "#1") == [url("https://github.com/haacked/switchboard/issues/1")])
    }

    @Test func withAContextALiveIdStillReadsAsItsName() {
      let result = render(plain: "Ask \(liveID) to rebase.", repo: contextRepo)

      #expect(String(result.text.characters) == "Ask \(liveName) to rebase.")
    }

    @Test func withAContextATextWithoutReferencesDrawsAsWithout() {
      let s = "Ask \(liveID) and \(removedID) to rebase."

      let withContext = render(plain: s, repo: contextRepo)
      let without = render(plain: s)

      #expect(withContext.text == without.text)
    }

    // MARK: Parity

    static let parityTexts: [MarkdownText] = [
      "Fix #1 first.",
      "See o/r#1.",
      "See https://github.com/o/r/pull/1/files.",
      "See https://github.com/o/r/issues/1#issuecomment-1 and http://github.com/o/r/pull/2",
      MarkdownText(stringLiteral: "Ask \(liveID) about #1 and o/r#2."),
      "&#123; a#1 #12.5 ##1",
      MarkdownText([MarkdownText.Run("Run "), MarkdownText.Run("#1", .code)]),
      MarkdownText([MarkdownText.Run("the fix", link: "https://github.com/o/r/pull/1"), MarkdownText.Run(" #2")]),
      MarkdownText([MarkdownText.Run("Fix "), MarkdownText.Run("#1", .strong), MarkdownText.Run(", ok")]),
    ]

    /// The same text with and without links gives the same characters.
    @Test(arguments: InlineTextTests.References.parityTexts, [nil, contextRepo] as [String?])
    func withAndWithoutLinksGiveTheSameCharacters(_ text: MarkdownText, repo: String?) {
      let linked = render(text, repo: repo, links: true)
      let unlinked = render(text, repo: repo, links: false)

      #expect(String(linked.text.characters) == String(unlinked.text.characters))
    }

    /// A context changes only links, never the characters.
    @Test(arguments: InlineTextTests.References.parityTexts)
    func withAndWithoutAContextGiveTheSameCharacters(_ text: MarkdownText) {
      let withContext = render(text, repo: contextRepo)
      let without = render(text)

      #expect(String(withContext.text.characters) == String(without.text.characters))
    }
  }
}
