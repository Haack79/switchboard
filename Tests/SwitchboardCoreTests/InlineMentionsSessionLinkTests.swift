import Foundation
import Testing

@testable import SwitchboardCore

private typealias Run = MarkdownText.Run
private typealias Piece = InlineMentions.Piece
private typealias Match = SessionNames.Match

private let liveID = "seb4ec"
private let liveName = "zsh-startup-for-switchboard"
private let names = SessionNames(live: [liveID: liveName, "sdcs7r": "docs-refresh"], removed: [:])
private let idURL = "switchboard://session/\(liveID)"
private let contextRepo = "haacked/switchboard"

private func pieces(_ text: MarkdownText, repo: String? = nil) -> [Piece] {
  InlineMentions(names: names, repo: repo).pieces(text)
}

private func pieces(plain: String, repo: String? = nil) -> [Piece] {
  pieces(MarkdownText(stringLiteral: plain), repo: repo)
}

/// A session link piece: the text that it draws, links to `url`.
private func link(_ text: String, _ style: MarkdownText.Style = [], url: String, _ target: SessionLink.Target) -> Piece
{
  Piece(run: Run(text, style, link: url), mention: .sessionLink(target))
}

private func idLink(_ text: String, _ style: MarkdownText.Style = []) -> Piece {
  link(text, style, url: idURL, .id(liveID))
}

private func plain(_ text: String, _ style: MarkdownText.Style = []) -> Piece {
  Piece(run: Run(text, style), mention: nil)
}

private func session(_ id: String = liveID, name: String = liveName) -> Piece {
  Piece(run: Run(name), mention: .session(Match(id: id, name: name, removed: false)))
}

private func targets(_ pieces: [Piece]) -> [SessionLink.Target] {
  pieces.compactMap { piece in
    guard case .sessionLink(let target)? = piece.mention else { return nil }
    return target
  }
}

private func hasSessionMatch(_ pieces: [Piece]) -> Bool {
  pieces.contains { piece in
    guard case .session? = piece.mention else { return false }
    return true
  }
}

private func paragraph(_ markdown: String) throws -> MarkdownText {
  let blocks = MarkdownBlock.parse(markdown)
  try #require(blocks.count == 1, "\(markdown) parses to \(blocks)")
  guard case .paragraph(let text) = blocks[0] else {
    Issue.record("\(markdown) parses to \(blocks[0]), not a paragraph")
    return MarkdownText()
  }
  return text
}

/// The pieces as a parity test compares them: each piece's text, link, and session link target.
private struct Seen: Equatable, CustomStringConvertible {
  let text: String
  let link: String?
  let target: SessionLink.Target?

  var description: String { "\(text.debugDescription) -> \(link ?? "nil") \(target.map { "\($0)" } ?? "")" }
}

/// Plain pieces that sit side by side join, because cmark can split one stretch of text into several runs.
private func seen(_ pieces: [Piece]) -> [Seen] {
  var out: [Seen] = []
  for piece in pieces {
    let target: SessionLink.Target? =
      if case .sessionLink(let t)? = piece.mention { t } else { nil }
    if piece.mention == nil, piece.run.link == nil, let last = out.last, last.link == nil, last.target == nil {
      out[out.count - 1] = Seen(text: last.text + piece.run.text, link: nil, target: nil)
    } else {
      out.append(Seen(text: piece.run.text, link: piece.run.link, target: target))
    }
  }
  return out
}

/// The name that Copy Link labels a link with. It holds every kind of character that cmark would read as Markdown
/// syntax in a label.
private let markdownName = "Fix `sb ls` *now* <x>"

extension InlineMentionsTests {
  /// Session links in text: a link run whose URL names a session, a bare `switchboard://session/…` URL, and
  /// `[label](switchboard://session/…)` in a run that no Markdown parser read.
  @Suite struct SessionLinks {
    // MARK: Bracket form

    @Test func aBracketLinkBecomesOnePieceThatReadsItsLabel() {
      #expect(pieces(plain: "[a](\(idURL))") == [idLink("a")])
    }

    @Test func aBracketLinkLeavesTheTextAroundItAsWritten() {
      #expect(pieces(plain: "Ask [a](\(idURL)) now.") == [plain("Ask "), idLink("a"), plain(" now.")])
    }

    /// A backslash before ASCII punctuation escapes it, as CommonMark reads a label.
    @Test(arguments: [
      ("[a\\]b](\(idURL))", "a]b"),
      ("[\\[x\\]](\(idURL))", "[x]"),
      ("[a\\*b\\_c](\(idURL))", "a*b_c"),
      ("[a\\\\b](\(idURL))", "a\\b"),
    ])
    func aBracketLinkLabelLosesTheBackslashBeforePunctuation(_ input: String, _ label: String) {
      #expect(pieces(plain: input) == [idLink(label)])
    }

    /// CommonMark keeps a backslash that comes before a letter, a digit, or a space.
    @Test(arguments: [("[a\\qb](\(idURL))", "a\\qb"), ("[a\\1](\(idURL))", "a\\1"), ("[a\\ b](\(idURL))", "a\\ b")])
    func aBracketLinkLabelKeepsTheBackslashBeforeOtherCharacters(_ input: String, _ label: String) {
      #expect(pieces(plain: input) == [idLink(label)])
    }

    /// A Copy Link output pasted into a note reads as the session's name.
    @Test func aCopyLinkOutputReadsAsTheSessionsName() {
      let input = SessionLink.markdown(name: markdownName, id: liveID)

      #expect(pieces(plain: input) == [idLink(markdownName)])
    }

    @Test func aBracketLinkToANameGivesANameTarget() {
      let url = "switchboard://session/Fix%20CI%20chat"

      #expect(pieces(plain: "[chat](\(url))") == [link("chat", url: url, .name("Fix CI chat"))])
    }

    /// A label that is a session id stays as written, because the link names its own target.
    @Test func aBracketLinkWhoseLabelIsAnIdKeepsTheLabel() {
      #expect(pieces(plain: "[sdcs7r](\(idURL))") == [idLink("sdcs7r")])
    }

    /// CommonMark drops the backslash before ASCII punctuation in a link's URL too, so `\)` does not end the URL.
    @Test func aBracketLinkURLLosesTheBackslashBeforePunctuation() {
      let url = "switchboard://session/x)y"

      #expect(pieces(plain: "[a](switchboard://session/x\\)y)") == [link("a", url: url, .name("x)y"))])
    }

    @Test func aBracketLinkKeepsTheStyleOfItsRun() {
      let text = MarkdownText([Run("see [a](\(idURL))", .emphasis)])

      #expect(pieces(text) == [plain("see ", .emphasis), idLink("a", .emphasis)])
    }

    @Test func anIdAfterABracketLinkStillMatches() {
      #expect(pieces(plain: "[a](\(idURL)) \(liveID)") == [idLink("a"), plain(" "), session()])
    }

    @Test func twoBracketLinksEachBecomeAPiece() {
      let other = "switchboard://session/sdcs7r"

      #expect(
        pieces(plain: "[a](\(idURL)),[b](\(other))")
          == [idLink("a"), plain(","), link("b", url: other, .id("sdcs7r"))])
    }

    // MARK: Bracket shapes that stay as written

    /// Each input is not a bracket link. Its text must come back as written, whatever the bare URL finder makes of
    /// a URL inside it.
    static let notBracketLinks: [String] = [
      "[a](https://example.com)",
      "[a](switchboard://session/\(liveID)?x=1)",
      "[a](switchboard://session/\(liveID)",
      "[a](switchboard://session/Fix CI chat)",
      "[[a]](\(idURL))",
      "[a]b](\(idURL))",
      "[a\nb](\(idURL))",
      "[](\(idURL))",
      "[a] (\(idURL))",
      "[a](<\(idURL)>)",
      "[a](switchboard://other/\(liveID))",
      "[a](SWITCHBOARD://session/\(liveID))",
      "\\[a](\(idURL))",
    ]

    @Test(arguments: notBracketLinks)
    func aShapeThatIsNotABracketLinkKeepsItsText(_ input: String) {
      #expect(pieces(plain: input).map(\.run.text).joined() == input)
    }

    @Test(arguments: notBracketLinks)
    func aShapeThatIsNotABracketLinkGivesNoPieceThatReadsTheLabel(_ input: String) {
      let linked = pieces(plain: input).filter { $0.mention != nil }

      #expect(!linked.contains { $0.run.text == "a" }, "\(linked)")
    }

    @Test func aBracketLinkToAnotherSiteIsOnePlainPiece() {
      #expect(pieces(plain: "[a](https://example.com)") == [plain("[a](https://example.com)")])
    }

    @Test func aBracketLinkToARefusedURLIsOnePlainPiece() {
      let input = "[a](switchboard://session/\(liveID)?x=1)"

      #expect(pieces(plain: input) == [plain(input)])
    }

    /// Without the `)`, only the bare URL inside links.
    @Test func aBracketLinkWithoutItsClosingParenthesisLinksOnlyTheBareURL() {
      #expect(pieces(plain: "[a](\(idURL)") == [plain("[a]("), idLink(idURL)])
    }

    @Test(arguments: [
      MarkdownText([Run("[a](\(idURL))", .code)]),
      MarkdownText([Run("see "), Run("[a](\(idURL))", .code), Run(" now")]),
      MarkdownText([Run("[a](\(idURL))", .footnote)]),
      MarkdownText([Run("[a](\(idURL))", image: "x.png")]),
    ])
    func aBracketLinkInACodeFootnoteOrImageRunPassesThrough(_ text: MarkdownText) {
      #expect(pieces(text) == text.runs.map { Piece(run: $0, mention: nil) })
    }

    // MARK: Bare URLs

    @Test func aBareIdURLIsOnePieceThatKeepsItsText() {
      #expect(pieces(plain: idURL) == [idLink(idURL)])
    }

    /// cmark does not autolink a custom scheme, so the URL reaches a paragraph's run as text.
    @Test func aBareIdURLInAParagraphIsOnePiece() throws {
      #expect(pieces(try paragraph("See \(idURL) now")) == [plain("See "), idLink(idURL), plain(" now")])
    }

    /// The session id inside the URL is part of the URL, so it does not become a name of its own.
    @Test func aBareIdURLGivesNoSessionPieceInsideIt() {
      #expect(!hasSessionMatch(pieces(plain: "See \(idURL) now")))
    }

    /// The URL ends where cmark ends an autolink, so the closing punctuation stays out of it.
    @Test(arguments: [
      ("See \(idURL).", [plain("See "), idLink(idURL), plain(".")]),
      ("(\(idURL))", [plain("("), idLink(idURL), plain(")")]),
      ("\(idURL), then", [idLink(idURL), plain(", then")]),
      ("\(idURL)!", [idLink(idURL), plain("!")]),
      ("Is it \(idURL)?", [plain("Is it "), idLink(idURL), plain("?")]),
      ("\"\(idURL)\"", [plain("\""), idLink(idURL), plain("\"")]),
      ("a\n\(idURL)\nb", [plain("a\n"), idLink(idURL), plain("\nb")]),
    ])
    fileprivate func aBareURLEndsBeforeTrailingPunctuation(_ input: String, _ expected: [Piece]) {
      #expect(pieces(plain: input) == expected)
    }

    @Test func aBareNameURLGivesANameTarget() {
      let url = "switchboard://session/fix-cache"

      #expect(
        pieces(plain: "See \(url) now") == [plain("See "), link(url, url: url, .name("fix-cache")), plain(" now")])
    }

    /// Assumes the piece keeps the style of its run, as a found GitHub URL does.
    @Test func aBareURLKeepsTheStyleOfItsRun() {
      let text = MarkdownText([Run("see \(idURL)", .emphasis)])

      #expect(pieces(text) == [plain("see ", .emphasis), idLink(idURL, .emphasis)])
    }

    /// `,` is a valid name character, so the whole text is one name link. The id after it would match on its own.
    @Test func anAcceptedURLWithAnIdInItsNameGivesNoSessionPiece() {
      let url = "switchboard://session/x,\(liveID)"

      #expect(pieces(plain: url) == [link(url, url: url, .name("x,\(liveID)"))])
    }

    @Test func anAcceptedURLWithAnIdInParenthesesGivesNoSessionPiece() {
      let url = "switchboard://session/(\(liveID))"

      #expect(pieces(plain: url) == [link(url, url: url, .name("(\(liveID))"))])
    }

    // MARK: Refused bare URLs

    /// `URL(string:)` would percent-encode the `>`, and the result would be a name target for `seb4ec>`.
    @Test func aBareURLThatURLStringWouldReencodeStaysPlain() {
      #expect(pieces(plain: "<\(idURL)>") == [plain("<\(idURL)>")])
    }

    /// Each URL is refused. Without the URL around it, the id at its end would match.
    @Test(arguments: [
      "switchboard://session/x?\(liveID)",
      "switchboard://session/x?q=(\(liveID))",
      "switchboard://session/x?a,\(liveID)",
    ])
    func aRefusedBareURLStaysPlainAndNoIdInsideItMatches(_ input: String) {
      #expect(pieces(plain: input) == [plain(input)])
    }

    /// A word or path that touches the scheme keeps the URL from linking, and no id inside it matches.
    @Test(arguments: ["x\(idURL)", "a/\(idURL)"])
    func aBareURLThatAWordOrPathTouchesStaysPlain(_ input: String) {
      let found = pieces(plain: input)

      #expect(found.allSatisfy { $0.mention == nil }, "\(found)")
      #expect(found.map(\.run.text).joined() == input)
    }

    /// The control for the refused URLs: the same id after the same scalars, with no URL, matches.
    @Test(arguments: ["x?\(liveID)", "x?q=(\(liveID))", "x?a,\(liveID)"])
    func theSameIdOutsideAURLMatches(_ input: String) {
      #expect(hasSessionMatch(pieces(plain: input)))
    }

    @Test func anIdAfterARefusedURLStillMatches() {
      #expect(pieces(plain: "switchboard://session/x?y \(liveID)") == [plain("switchboard://session/x?y "), session()])
    }

    // MARK: Link runs

    @Test func aLinkRunToAnIdURLBecomesASessionLinkWithItsRunUnchanged() {
      let run = Run("the fix", .strong, link: idURL)

      #expect(
        pieces(MarkdownText([Run("see "), run])) == [
          plain("see "), Piece(run: run, mention: .sessionLink(.id(liveID))),
        ])
    }

    @Test func aParsedMarkdownSessionLinkBecomesASessionLink() throws {
      #expect(pieces(try paragraph("Ask [x](\(idURL)) now")) == [plain("Ask "), idLink("x"), plain(" now")])
    }

    /// A session link changes no text, so a code or footnote run in it keeps its text and style. A code run that is
    /// one session id is not swapped for the name, because a link run is never rewritten.
    @Test(arguments: [
      Run("fix-cache", .code, link: idURL), Run(liveID, .code, link: idURL), Run("1", .footnote, link: idURL),
    ])
    fileprivate func aCodeOrFootnoteRunInASessionLinkBecomesASessionLinkWithItsRunUnchanged(_ run: Run) {
      #expect(
        pieces(MarkdownText([Run("see "), run])) == [
          plain("see "), Piece(run: run, mention: .sessionLink(.id(liveID))),
        ])
    }

    @Test func aParsedSessionLinkWhoseLabelIsACodeSpanBecomesASessionLink() throws {
      #expect(
        pieces(try paragraph("Ask [`fix-cache`](\(idURL)) now")) == [
          plain("Ask "), idLink("fix-cache", .code), plain(" now"),
        ])
    }

    @Test func aParsedSessionLinkWithACodeSpanInItsLabelGivesEachRunTheSessionLink() throws {
      #expect(
        pieces(try paragraph("Ask [the `fix-cache` fix](\(idURL)) now")) == [
          plain("Ask "), idLink("the "), idLink("fix-cache", .code), idLink(" fix"), plain(" now"),
        ])
    }

    /// GitHub links in a code span stay as they were: the code run is not read for a reference.
    @Test func aCodeRunInAGitHubLinkPassesThrough() {
      let text = MarkdownText([Run("see "), Run("o/r#1", .code, link: "https://github.com/o/r/pull/1")])

      #expect(pieces(text) == text.runs.map { Piece(run: $0, mention: nil) })
    }

    /// A code run whose link is a refused session URL stays as it was, and the id in the URL does not match.
    @Test func aCodeRunInARefusedSessionLinkPassesThrough() {
      let text = MarkdownText([Run("see "), Run(liveID, .code, link: "\(idURL)?x=1")])

      #expect(pieces(text) == text.runs.map { Piece(run: $0, mention: nil) })
    }

    /// An image run is never read, even in a session link. The link still opens the session on a click.
    @Test func anImageRunInASessionLinkPassesThrough() {
      let text = MarkdownText([Run("fix-cache", link: idURL, image: "x.png")])

      #expect(pieces(text) == text.runs.map { Piece(run: $0, mention: nil) })
    }

    @Test func aLinkRunToANameURLGivesANameTarget() {
      let url = "switchboard://session/docs-refresh"
      let run = Run("docs", link: url)

      #expect(pieces(MarkdownText([run])) == [Piece(run: run, mention: .sessionLink(.name("docs-refresh")))])
    }

    @Test(arguments: [
      "switchboard://session/\(liveID)?x=1", "switchboard://session/\(liveID)#f", "switchboard://session/a/b",
      "switchboard://session/", "switchboard://other/\(liveID)", "https://example.com/\(liveID)",
    ])
    func aLinkRunToAURLThatNamesNoSessionPassesThrough(_ url: String) {
      let text = MarkdownText([Run("see "), Run("x", link: url)])

      #expect(pieces(text) == text.runs.map { Piece(run: $0, mention: nil) })
    }

    /// A link run is never rewritten, so a label that is a session id stays as written.
    @Test func aLinkRunWhoseLabelIsAnIdKeepsItsLabel() {
      let run = Run(liveID, link: idURL)

      #expect(pieces(MarkdownText([run])) == [Piece(run: run, mention: .sessionLink(.id(liveID)))])
    }

    // MARK: Beside GitHub URLs

    @Test func aGitHubURLAndASessionURLWithASpaceBetweenEachLink() throws {
      let github = "https://github.com/o/r/pull/1"

      let found = pieces(plain: "\(github) \(idURL)")

      #expect(found.map(\.run.text) == [github, " ", idURL])
      #expect(targets(found) == [.id(liveID)])
      #expect(found.first?.mention == .reference(try #require(GitHubRef(url: github))))
    }

    @Test func aSessionURLAndAGitHubURLWithASpaceBetweenEachLink() throws {
      let github = "https://github.com/o/r/pull/1"

      let found = pieces(plain: "\(idURL) \(github)")

      #expect(found.map(\.run.text) == [idURL, " ", github])
      #expect(targets(found) == [.id(liveID)])
      #expect(found.last?.mention == .reference(try #require(GitHubRef(url: github))))
    }

    /// With no space between them, the first URL runs on over the second, as cmark reads it. The text stays whole.
    @Test(arguments: ["https://github.com/o/r/pull/1\(idURL)", "\(idURL)https://github.com/o/r/pull/1"])
    func twoURLsWithNoSpaceBetweenKeepTheirText(_ input: String) {
      #expect(pieces(plain: input).map(\.run.text).joined() == input)
    }

    // MARK: Parity

    /// URLs that must give the same answer from the bare URL finder and from `SessionLink.target(from:)`. Each
    /// ends in a scalar that cmark keeps in an autolink, and `URL(string:)` keeps each as written.
    static let finderURLs: [String] = [
      idURL, "switchboard://session/sdcs7r", "switchboard://session/fix-cache",
      "switchboard://session/Fix%20CI%20chat", "switchboard://session/posthog-code%2Fflag-evaluations-table",
      "switchboard://session/SEB4EC", "switchboard://session/seb4e", "switchboard://session/x,\(liveID)",
      "switchboard://session/a+b", "switchboard://session/\(liveID)%20",
      "switchboard://session/\(liveID)?x=1", "switchboard://session/\(liveID)#f", "switchboard://session/a/b",
      "switchboard://session/%73eb4ec", "switchboard://session/\(liveID);x", "switchboard://session/%ff",
      "switchboard://session/%C3", "switchboard://session/%20", "switchboard://session/%0A",
      "switchboard://session/%00",
      "switchboard://session/" + String(repeating: "a", count: 201),
      "switchboard://session/" + String(repeating: "a", count: 200),
      "switchboard://Session/\(liveID)", "switchboard://session//\(liveID)", "switchboard:session/\(liveID)",
      "switchboard://user@session/\(liveID)", "switchboard://session:1/\(liveID)",
    ]

    @Test func theFinderURLsHoldBothAcceptedAndRefusedURLs() throws {
      let parsed = try Self.finderURLs.map { SessionLink.target(from: try #require(URL(string: $0), "\($0)")) }

      #expect(parsed.contains { $0 != nil })
      #expect(parsed.contains { $0 == nil })
    }

    @Test(arguments: finderURLs)
    func theBareURLFinderAndTheParserAcceptTheSameURLs(_ string: String) throws {
      let target = SessionLink.target(from: try #require(URL(string: string)))

      let found = pieces(plain: "see \(string) now")

      if let target {
        #expect(found == [plain("see "), link(string, url: string, target), plain(" now")])
      } else {
        #expect(found == [plain("see \(string) now")])
      }
    }

    /// cmark parses a bracket link as a link run. The bracket finder must read it the same way in plain text.
    @Test(arguments: [
      "Ask [x](\(idURL)) now",
      "[a\\]b](\(idURL))",
      "[chat](switchboard://session/Fix%20CI%20chat)",
      "[a](switchboard://session/x\\)y)",
      "[a](switchboard://session/a(b))",
      SessionLink.markdown(name: markdownName, id: liveID),
      SessionLink.markdown(name: "fix-flag-cache-race", id: "sdcs7r"),
      "See \(idURL) and [y](switchboard://session/sdcs7r).",
      "See \(liveID) and [y](\(idURL)) and o/r#1.",
    ])
    func aBracketLinkReadsTheSameInPlainTextAndInAParagraph(_ input: String) throws {
      let fromPlain = seen(pieces(plain: input, repo: contextRepo))
      let fromParagraph = seen(pieces(try paragraph(input), repo: contextRepo))

      #expect(fromPlain == fromParagraph)
    }

    @Test(arguments: [
      "See \(idURL).", "(\(idURL))", "\(idURL), then \(liveID)", "switchboard://session/fix-cache now",
      "switchboard://session/x?\(liveID)", "see https://github.com/o/r/pull/1 and \(idURL)",
    ])
    func aBareURLReadsTheSameInPlainTextAndInAParagraph(_ input: String) throws {
      let fromPlain = seen(pieces(plain: input, repo: contextRepo))
      let fromParagraph = seen(pieces(try paragraph(input), repo: contextRepo))

      #expect(fromPlain == fromParagraph)
    }
  }
}
