import Foundation
import Testing

@testable import SwitchboardCore

private typealias Run = MarkdownText.Run
private typealias Piece = InlineMentions.Piece
private typealias Mention = InlineMentions.Mention
private typealias Match = SessionNames.Match

/// The repository that a bare `#N` refers to in these tests.
private let contextRepo = "haacked/switchboard"

private let liveNames = ["seb4ec": "zsh-startup-for-switchboard", "swb_eb4ec": "new-id-form"]
private let names = SessionNames(live: liveNames, removed: [:])

/// Sessions whose names hold a bare reference. A session's name is never scanned again, so it never links.
private let hashNames = ["sk7fix": "fix #12", "sm3ref": "#12", "sk8ur2": "see https://github.com/o/r/pull/1"]

private func reference(_ ref: GitHubRef) -> Mention { .reference(ref) }

private func referenced(_ mention: Mention?) -> GitHubRef? {
  guard case .reference(let ref)? = mention else { return nil }
  return ref
}

/// The reference that a covered text names: a bare `#N` in `context`, a URL, or `owner/name#N`.
private func gitHubRef(_ covered: String, context: String = contextRepo) throws -> GitHubRef {
  let ref: GitHubRef? =
    if covered.hasPrefix("#") {
      GitHubRef(parsing: context + covered)
    } else if covered.contains("://") {
      GitHubRef(url: covered)
    } else {
      GitHubRef(parsing: covered)
    }
  return try #require(ref, "fixture \(covered.debugDescription) names no reference")
}

/// The piece for a reference found in an unlinked run. It keeps the text and
/// style as written. Its link is the text itself when that is https, and the
/// item's page otherwise, so that an `http` URL opens as https.
private func referencePiece(_ covered: String, _ style: MarkdownText.Style = [], context: String = contextRepo) throws
  -> Piece
{
  let ref = try gitHubRef(covered, context: context)
  let link = covered.hasPrefix("https://") ? covered : ref.url.absoluteString
  return Piece(run: Run(covered, style, link: link), mention: reference(ref))
}

/// The piece for a link run whose link is a GitHub issue or pull request URL: the run as written.
private func linkedPiece(_ text: String, _ style: MarkdownText.Style = [], link: String) throws -> Piece {
  Piece(run: Run(text, style, link: link), mention: reference(try gitHubRef(link)))
}

private func plain(_ text: String, _ style: MarkdownText.Style = [], link: String? = nil, image: String? = nil)
  -> Piece
{
  Piece(run: Run(text, style, link: link, image: image), mention: nil)
}

private func session(_ id: String, _ style: MarkdownText.Style = [], live: [String: String] = liveNames) -> Piece {
  let name = live[id] ?? "missing fixture \(id)"
  return Piece(run: Run(name, style), mention: .session(Match(id: id, name: name, removed: false)))
}

private func unchanged(_ text: MarkdownText) -> [Piece] { text.runs.map { Piece(run: $0, mention: nil) } }

/// The pieces that a row's expected text describes. `⟨id⟩` stands for the
/// session's name, matched. `«text»` stands for a reference that covers
/// `text`. The rest is unstyled text.
private func expectedPieces(_ marked: String, live: [String: String] = liveNames) throws -> [Piece] {
  var pieces: [Piece] = []
  var rest = Substring(marked)
  while let open = rest.firstIndex(where: { $0 == "⟨" || $0 == "«" }) {
    let closer: Character = rest[open] == "⟨" ? "⟩" : "»"
    let close = try #require(rest[open...].firstIndex(of: closer), "unclosed marker in \(marked.debugDescription)")
    if open > rest.startIndex { pieces.append(plain(String(rest[..<open]))) }
    let inner = String(rest[rest.index(after: open)..<close])
    pieces.append(closer == "⟩" ? session(inner, live: live) : try referencePiece(inner))
    rest = rest[rest.index(after: close)...]
  }
  if !rest.isEmpty { pieces.append(plain(String(rest))) }
  return pieces
}

/// A row's expected text when no context repo exists: each bare `#N` stays plain.
private func withoutContext(_ marked: String) -> String {
  var out = ""
  var rest = Substring(marked)
  while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
    let inner = rest[rest.index(after: open)..<close]
    out += rest[..<open]
    out += inner.hasPrefix("#") ? String(inner) : "«\(inner)»"
    rest = rest[rest.index(after: close)...]
  }
  return out + rest
}

private typealias Want = InlineMentionsTests.Want

extension InlineMentionsTests {
  /// A piece of a Markdown row's expected pieces.
  enum Want: Sendable {
    case text(String, MarkdownText.Style = [], link: String? = nil, image: String? = nil)
    /// A reference found in an unlinked run.
    case ref(String, MarkdownText.Style = [])
    /// A link run whose link is a GitHub issue or pull request URL.
    case linked(String, MarkdownText.Style = [], link: String)
    case session(String, MarkdownText.Style = [])
  }
}

private func expectedPieces(_ wants: [Want]) throws -> [Piece] {
  try wants.map { want in
    switch want {
    case .text(let text, let style, let link, let image): plain(text, style, link: link, image: image)
    case .ref(let covered, let style): try referencePiece(covered, style)
    case .linked(let text, let style, let link): try linkedPiece(text, style, link: link)
    case .session(let id, let style): session(id, style)
    }
  }
}

/// A Markdown row's expected pieces when no context repo exists: each bare
/// `#N` stays plain text and joins the plain text of the same style beside it.
private func withoutContext(_ wants: [Want]) -> [Want] {
  var out: [Want] = []
  for var want in wants {
    if case .ref(let covered, let style) = want, covered.hasPrefix("#") { want = .text(covered, style) }
    if case .text(let text, let style, nil, nil) = want, case .text(let last, let lastStyle, nil, nil)? = out.last,
      lastStyle == style
    {
      out[out.count - 1] = .text(last + text, style)
      continue
    }
    out.append(want)
  }
  return out
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

/// Whether the pieces spell `input` in order, where each session piece stands
/// for its id, its `name (id)`, or its `id (name)`. So no two pieces cover the
/// same text and no text is lost.
private func spell(_ pieces: [Piece], _ input: String) -> Bool {
  let scalars = Array(input.unicodeScalars)
  var at = 0
  func consume(_ text: String, capitalizedAtStart: Bool = false) -> Bool {
    let want = Array(text.unicodeScalars)
    guard at + want.count <= scalars.count else { return false }
    let written = scalars[at..<at + want.count]
    let same =
      written.elementsEqual(want)
      || (capitalizedAtStart && at == 0
        && written.first?.properties.lowercaseMapping == want.first?.properties.lowercaseMapping
        && written.dropFirst().elementsEqual(want.dropFirst()))
    if same { at += want.count }
    return same
  }
  for piece in pieces {
    if case .session(let match)? = piece.mention {
      guard
        consume("\(match.name) (\(match.id))", capitalizedAtStart: true) || consume("\(match.id) (\(match.name))")
          || consume(match.id)
      else { return false }
    } else {
      guard consume(piece.run.text) else { return false }
    }
  }
  return at == scalars.count
}

/// A reference piece as the parity tests compare it.
private struct Found: Equatable, CustomStringConvertible {
  let text: String
  let key: String
  let form: GitHubRef.Form

  var description: String { "\(text) -> \(key) (\(form))" }
}

private func found(_ pieces: [Piece]) -> [Found] {
  pieces.compactMap { piece in
    referenced(piece.mention).map { Found(text: piece.run.text, key: $0.key, form: $0.form) }
  }
}

// MARK: - Rows

/// Unstyled text and its pieces under the context repo, written as `expectedPieces` describes.
private let referenceRows: [(String, String)] = [
  // Position in the text.
  ("#1", "«#1»"),
  ("#1 is next", "«#1» is next"),
  ("see #1 now", "see «#1» now"),
  ("fixed in #1", "fixed in «#1»"),
  ("a\n#12\nb", "a\n«#12»\nb"),
  ("a\t#12\tb", "a\t«#12»\tb"),
  // The scalar after the number.
  ("#12.", "«#12»."),
  ("#12. Next", "«#12». Next"),
  ("#12,", "«#12»,"),
  ("#12)", "«#12»)"),
  ("#12:", "«#12»:"),
  ("#12: done", "«#12»: done"),
  ("#12's", "«#12»'s"),
  ("#12\u{2019}s", "«#12»\u{2019}s"),
  ("#12...", "«#12»..."),
  ("#12... then", "«#12»... then"),
  ("#12;", "«#12»;"),
  ("#12!", "«#12»!"),
  ("#12?", "«#12»?"),
  ("#12.)", "«#12».)"),
  ("#12\u{00A0}now", "«#12»\u{00A0}now"),
  ("#12\u{2014}x", "«#12»\u{2014}x"),
  // The scalar before the `#`.
  ("(#1)", "(«#1»)"),
  ("\"#1\"", "\"«#1»\""),
  ("'#1'", "'«#1»'"),
  ("[#1]", "[«#1»]"),
  ("a,#1", "a,«#1»"),
  ("a;#1", "a;«#1»"),
  ("\u{2014}#1", "\u{2014}«#1»"),
  ("🙂#1🙂", "🙂«#1»🙂"),
  // The number.
  ("#123456789", "«#123456789»"),
  // Accepted false positives, as GitHub has them.
  ("step #2", "step «#2»"),
  ("#123456", "«#123456»"),
  ("and/or#1", "«and/or#1»"),
  // Several references.
  ("#1,#2", "«#1»,«#2»"),
  ("#1 #2", "«#1» «#2»"),
  ("#1 and #1", "«#1» and «#1»"),
  // `owner/name#N`.
  ("o/r#1", "«o/r#1»"),
  ("see o/r#1 now", "see «o/r#1» now"),
  ("(o/r#1)", "(«o/r#1»)"),
  ("o/r#1.", "«o/r#1»."),
  ("o/r#1's", "«o/r#1»'s"),
  ("haacked/switchboard#283", "«haacked/switchboard#283»"),
  ("O/R#1", "«O/R#1»"),
  ("o-x/r_y.z#1", "«o-x/r_y.z#1»"),
  ("o/r.git#1", "«o/r.git#1»"),
  ("o/r#1,o/r#2", "«o/r#1»,«o/r#2»"),
  ("o/r#1 and #2", "«o/r#1» and «#2»"),
  ("o/r #1", "o/r «#1»"),
  ("o/r#123456789", "«o/r#123456789»"),
  // A reference beside a session id.
  ("#1,seb4ec", "«#1»,⟨seb4ec⟩"),
  ("#1 (seb4ec)", "«#1» (⟨seb4ec⟩)"),
  ("seb4ec #1", "⟨seb4ec⟩ «#1»"),
  ("seb4ec,#1", "⟨seb4ec⟩,«#1»"),
  ("zsh-startup-for-switchboard (seb4ec) #1", "⟨seb4ec⟩ «#1»"),
  ("seb4ec (zsh-startup-for-switchboard) fixes o/r#2", "⟨seb4ec⟩ fixes «o/r#2»"),
  ("#1,swb_eb4ec", "«#1»,⟨swb_eb4ec⟩"),
  ("#1 (swb_eb4ec)", "«#1» (⟨swb_eb4ec⟩)"),
  ("swb_eb4ec #1", "⟨swb_eb4ec⟩ «#1»"),
  ("swb_eb4ec,#1", "⟨swb_eb4ec⟩,«#1»"),
  ("new-id-form (swb_eb4ec) #1", "⟨swb_eb4ec⟩ «#1»"),
  ("swb_eb4ec (new-id-form) fixes o/r#2", "⟨swb_eb4ec⟩ fixes «o/r#2»"),
  ("seb4ec and swb_eb4ec fix #3", "⟨seb4ec⟩ and ⟨swb_eb4ec⟩ fix «#3»"),
  // URLs with text inside them that other finders would match.
  ("https://github.com/o/r/pull/1?seb4ec", "«https://github.com/o/r/pull/1?seb4ec»"),
  ("https://github.com/o/r/pull/1?x=seb4ec", "«https://github.com/o/r/pull/1?x=seb4ec»"),
  ("https://github.com/o/r/pull/1?swb_eb4ec", "«https://github.com/o/r/pull/1?swb_eb4ec»"),
  ("https://github.com/o/r/pull/1?a,#2", "«https://github.com/o/r/pull/1?a,#2»"),
  ("https://github.com/o/r/pull/1?a,o/r#2", "«https://github.com/o/r/pull/1?a,o/r#2»"),
  ("https://github.com/o/r/issues/1#2", "«https://github.com/o/r/issues/1#2»"),
  // Text after a URL.
  ("https://github.com/o/r/pull/1 seb4ec", "«https://github.com/o/r/pull/1» ⟨seb4ec⟩"),
  ("https://github.com/o/r/pull/1, seb4ec", "«https://github.com/o/r/pull/1», ⟨seb4ec⟩"),
  ("https://github.com/o/r/pull/1 swb_eb4ec", "«https://github.com/o/r/pull/1» ⟨swb_eb4ec⟩"),
  ("https://github.com/o/r/pull/1 #2", "«https://github.com/o/r/pull/1» «#2»"),
  ("see https://example.com/x and #12", "see https://example.com/x and «#12»"),
  ("see https://example.com/x. #12", "see https://example.com/x. «#12»"),
  ("see https://example.com/x, #12", "see https://example.com/x, «#12»"),
  ("see https://example.com/x (#12)", "see https://example.com/x («#12»)"),
  ("https://example.com/x seb4ec", "https://example.com/x ⟨seb4ec⟩"),
  // Trailing punctuation that GFM leaves out of an autolink, more than once.
  ("(see https://github.com/o/r/pull/1.)", "(see «https://github.com/o/r/pull/1».)"),
  ("see https://github.com/o/r/pull/1)) now", "see «https://github.com/o/r/pull/1»)) now"),
  ("see https://github.com/o/r/pull/1?! now", "see «https://github.com/o/r/pull/1»?! now"),
]

/// Each URL form that names an issue or a pull request.
private let referenceURLs = [
  "https://github.com/o/r/issues/1",
  "https://github.com/o/r/pull/1",
  "https://github.com/o/r/pull/1/files",
  "https://github.com/o/r/pull/1/commits/0123abc",
  "https://github.com/o/r/pull/1/checks",
  "https://github.com/o/r/pull/1/changes",
  "https://github.com/o/r/issues/1?q=is%3Aopen",
  "https://github.com/o/r/issues/1#issuecomment-1",
  "https://github.com/o/r/pull/1#discussion_r1",
  "https://github.com/o/r/pull/1/files#diff-abc",
  "https://github.com/haacked/switchboard/issues/283",
  "https://github.com/o-x/r_y.z/pull/1",
  "http://github.com/o/r/issues/1",
  "http://github.com/o/r/pull/1#issuecomment-1",
  "https://GitHub.com/o/r/pull/1",
]

/// Each URL form inside text: with the trailing punctuation that GFM leaves
/// out of an autolink, and with balanced parentheses that it keeps.
private let urlRows: [(String, String)] = referenceURLs.flatMap { url -> [(String, String)] in
  let balanced = url + (url.contains("?") || url.contains("#") ? "(x)" : "?q=(x)")
  let wrapped: [(String, String)] = [
    (url, "«\(url)»"),
    ("see \(url) now", "see «\(url)» now"),
    ("see \(url). Next", "see «\(url)». Next"),
    ("see \(url), then", "see «\(url)», then"),
    ("see \(url))", "see «\(url)»)"),
    ("(see \(url))", "(see «\(url)»)"),
    ("(\(url))", "(«\(url)»)"),
    ("see \(balanced) now", "see «\(balanced)» now"),
    ("(see \(balanced))", "(see «\(balanced)»)"),
  ]
  let trailing = ".,:;!?'\"*_~".map { mark in ("\(url)\(mark)", "«\(url)»\(mark)") }
  return wrapped + trailing
}

/// Unstyled text that no finder may match, with or without a context repo.
private let unchangedRows: [String] = [
  "", "no references here", "#", "# 1", "#a", "#seb4ec",
  // The scalar after the number.
  "#12.5", "#12:30", "#12-fix", "#12a", "#12_x", "#12/3", "#12.x", "#12:x", "#12..x", "#12=", "#12@", "#12~",
  "#12$", "#12%", "#12+", "#12&", "#12\\", "#1é", "#1\u{0301}", "#1٣",
  // The number.
  "#012", "#0", "#00", "#1234567890", "#٣", "#-1", "#+1",
  // The scalar before the `#`.
  "&#123;", "a#1", "/#1", "##1", "x.#1", "_#1", "-#1", "@#1", ":#1", "\\#1", "$#1", "=#1", "~#1", "&#1", "%#1",
  "+#1", "é#1", "2#1", "e\u{0301}#1",
  // Two references with no boundary between them.
  "#1#2", "o/r#1#2",
  // `owner/name#N` that fails a rule.
  "a/b/c#1", "github.com/o/r#1", "www.github.com/o/r#1", "1/2#3", "a1/2#3", "o/2#3", "o/r#0", "o/r#012",
  "o/r#1234567890", "o/r#12.5", "o/r#1a", "o/r#1-fix", "@o/r#1", "o/#1", "/r#1", "../r#1", "./r#1", "o /r#1",
  "o/r##1", "o/r#",
  // A reference touching a session id.
  "seb4ec#1",
]

/// Text inside a URL. The URL blocks every finder, so nothing in it changes.
private let blockedRows: [String] = [
  // URLs that are not GitHub's.
  "https://example.com/page#12", "https://example.com/#12", "https://example.com/a,#12", "https://example.com/(#12)",
  "https://example.com/x,#12", "https://example.com/x(#12)", "https://example.com/?o/r#1",
  "https://example.com/a,o/r#1",
  "https://example.com/?seb4ec", "https://example.com/a,seb4ec", "https://example.com/(seb4ec)",
  "see https://example.com/?seb4ec now", "see https://example.com/a,#12 now", "http://example.com/a,#12",
  "http://example.com/a,seb4ec", "(https://example.com/x)seb4ec",
  // GitHub URLs that name no issue or pull request.
  "https://github.com/o/r/pull/new/x", "https://github.com/o/r/pull/new/x,#2",
  "https://github.com/o/r/pull/new/x?(seb4ec)",
  "https://github.com/o/r/issues", "https://github.com/o/r/issues/", "https://github.com/o/r/pulls/1",
  "https://github.com/o/r/discussions/1", "https://github.com/o/r/discussions/1?x,#2",
  "https://github.com/o/r/commit/0123abc", "https://github.com/o/r", "https://github.com/o/r/issues/0",
  "https://github.com/o/r/issues/012", "https://github.com/o/r/issues/1234567890", "https://github.com/o/r/pull/1x",
  "https://github.com/o/r/pull/1.5", "https://github.com/o/r/pull/-1", "https://github.com/o/r/issues/1,seb4ec",
  "https://github.com/1/2/pull/3", "https://github.com/a/b/c/pull/1",
  // Hosts other than github.com.
  "https://www.github.com/o/r/pull/1", "https://github.example.com/o/r/pull/1", "https://gist.github.com/o/r/pull/1",
  "https://github.com.example.com/o/r/pull/1", "https://notgithub.com/o/r/pull/1",
  // Forms that `URL` reads as github.com but that are not a plain `github.com` host.
  "https://user@github.com/o/r/pull/1", "https://github.com:443/o/r/pull/1", "https://github.com/o/r/pull/%31",
  // Paths that a browser or `URL` reads as another page than the one the text names.
  "https://github.com//o/r/pull/1", "https://github.com/%6F/r/pull/1", "https://github.com/o/r/pull/1/../../x",
  "https://github.com/o/r/pull/1/..\\..\\x", "https://github.com/o/r/pull/1/./x", "https://github.com./o/r/pull/1",
  // Whitespace that is not ASCII stays inside the URL, as it does in an autolink.
  "https://github.com/o/r/pull/1\u{00A0}seb4ec", "https://example.com/x\u{2003}#12",
  // A scheme that touches a word or a forbidden scalar.
  "xhttps://github.com/o/r/pull/1", "=https://github.com/o/r/pull/1", "x=https://example.com/a,seb4ec",
  "x=https://example.com/a,#12",
  // No scheme.
  "www.github.com/o/r/pull/1", "github.com/o/r/pull/1",
]

/// Every unstyled row and its pieces under the context repo.
private let plainRows: [(String, String)] =
  referenceRows + urlRows + (unchangedRows + blockedRows).map { ($0, $0) }

/// Markdown that every finder must leave exactly as `MarkdownBlock.parse` gives it, with or without a context repo.
private let unchangedMarkdown: [String] = [
  // Code spans.
  "`#1`", "`o/r#1`", "`https://github.com/o/r/pull/1`", "see `#12` now",
  // Links whose link is not a GitHub issue or pull request.
  "[#1](https://x.dev)", "[see #1](https://x.dev)", "<a href=\"https://x.dev\">#1</a>",
  "www.github.com/o/r/pull/1", "https://github.com/o/r/pull/new/x", "see https://example.com/page#12 now",
  "<https://example.com/a,#12>",
  // An image, even one inside a link to a pull request.
  "see ![#1](x.png) now", "see [![#1](x.png)](https://github.com/o/r/pull/1) now",
  // A word in a neighboring run touches the reference.
  "*a*#1", "#1*a*", "*o/r*#1", "`x`#1", "#1`x`", "[x](https://x.dev)#1",
  // A new-form id split across runs, or touched by a word in a neighboring run.
  "swb_eb**4ec**", "swb_eb4**ec**", "swb_eb[4ec](https://x.test)", "swb_eb`4ec`", "seb**4ec**", "*a*swb_eb4ec",
  "swb_eb4ec*a*",
]

/// Markdown and its pieces under the context repo.
private let markdownRows: [(String, [Want])] = [
  ("**#1**", [.ref("#1", .strong)]),
  ("*#1*", [.ref("#1", .emphasis)]),
  ("~~#1~~", [.ref("#1", .strikethrough)]),
  ("**o/r#1**", [.ref("o/r#1", .strong)]),
  ("*see #12 now*", [.text("see ", .emphasis), .ref("#12", .emphasis), .text(" now", .emphasis)]),
  ("**#12**.", [.ref("#12", .strong), .text(".")]),
  ("*a* #1", [.text("a", .emphasis), .text(" "), .ref("#1")]),
  ("#1 *a*", [.ref("#1"), .text(" "), .text("a", .emphasis)]),
  ("seb4ec **#1**", [.session("seb4ec"), .text(" "), .ref("#1", .strong)]),
  ("swb_eb4ec **#1**", [.session("swb_eb4ec"), .text(" "), .ref("#1", .strong)]),
  ("see swb_eb4ec here", [.text("see "), .session("swb_eb4ec"), .text(" here")]),
  ("_swb_eb4ec_ #1", [.session("swb_eb4ec", .emphasis), .text(" "), .ref("#1")]),
  ("**swb_eb4ec** #1", [.session("swb_eb4ec", .strong), .text(" "), .ref("#1")]),
  ("#1 [docs](https://example.com/docs)", [.ref("#1"), .text(" "), .text("docs", link: "https://example.com/docs")]),
  // Links whose link is a GitHub issue or pull request keep their run.
  ("[text](https://github.com/o/r/pull/1)", [.linked("text", link: "https://github.com/o/r/pull/1")]),
  ("[#4](https://github.com/o/r/issues/3)", [.linked("#4", link: "https://github.com/o/r/issues/3")]),
  ("[seb4ec](https://github.com/o/r/issues/3)", [.linked("seb4ec", link: "https://github.com/o/r/issues/3")]),
  (
    "*[x](https://github.com/o/r/issues/3#issuecomment-9)*",
    [.linked("x", .emphasis, link: "https://github.com/o/r/issues/3#issuecomment-9")]
  ),
  (
    "see https://github.com/o/r/pull/1 now",
    [.text("see "), .linked("https://github.com/o/r/pull/1", link: "https://github.com/o/r/pull/1"), .text(" now")]
  ),
  (
    "<https://github.com/o/r/issues/2>",
    [.linked("https://github.com/o/r/issues/2", link: "https://github.com/o/r/issues/2")]
  ),
  ("<a href=\"https://github.com/o/r/pull/1\">PR</a>", [.linked("PR", link: "https://github.com/o/r/pull/1")]),
  ("[x](https://github.com/o/r/pull/1)#2", [.linked("x", link: "https://github.com/o/r/pull/1"), .text("#2")]),
  (
    "[x](https://github.com/o/r/pull/1) #2",
    [.linked("x", link: "https://github.com/o/r/pull/1"), .text(" "), .ref("#2")]
  ),
]

/// Rows for a directory whose session names hold a reference.
private let hashNameRows: [(String, String)] = [
  ("fix #12 (sk7fix)", "⟨sk7fix⟩"),
  ("sk7fix (fix #12)", "⟨sk7fix⟩"),
  ("Fix #12 (sk7fix)", "⟨sk7fix⟩"),
  ("see fix #12 (sk7fix) and #13", "see ⟨sk7fix⟩ and «#13»"),
  ("sk7fix", "⟨sk7fix⟩"),
  ("a #12 (sk7fix)", "a «#12» (⟨sk7fix⟩)"),
  // The collapse and the reference start at the same scalar, and the longer one wins.
  ("#12 (sm3ref)", "⟨sm3ref⟩"),
  ("sm3ref (#12)", "⟨sm3ref⟩"),
  // A name that holds a URL. No span may overlap a URL, so the collapse gives way and the bare id still matches.
  ("see https://github.com/o/r/pull/1 (sk8ur2)", "see «https://github.com/o/r/pull/1» (⟨sk8ur2⟩)"),
]

/// Every unstyled input, for the tests that hold for any text.
private let plainInputs: [String] = plainRows.map(\.0) + hashNameRows.map(\.0)

/// Every Markdown input, for the tests that hold for any text.
private let markdownInputs: [String] = unchangedMarkdown + markdownRows.map(\.0)

private let contexts: [String?] = [contextRepo, nil]

/// Whether cmark reads the line as an ATX heading.
private func isHeading(_ line: String) -> Bool {
  let hashes = line.prefix(while: { $0 == "#" }).count
  return (1...6).contains(hashes) && (line.count == hashes || line.dropFirst(hashes).first == " ")
}

/// Unstyled rows that cmark parses as one paragraph of the same text, with no autolink.
private let unstyledInputs: [String] = plainRows.map(\.0).filter { input in
  !input.isEmpty && input == input.trimmingCharacters(in: .whitespacesAndNewlines)
    && input.allSatisfy { !"`*_[]<>&~\\!".contains($0) }
    && !input.contains("http") && !input.contains("www.") && !input.contains("://") && !isHeading(input)
}

@Suite struct InlineMentionsTests {
  // MARK: Rows

  @Test(arguments: plainRows)
  func plainTextWithAContextRepo(_ input: String, _ expected: String) throws {
    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces == (try expectedPieces(expected)))
  }

  @Test(arguments: plainRows)
  func plainTextWithoutAContextRepoLeavesBareNumbersPlain(_ input: String, _ expected: String) throws {
    let pieces = InlineMentions(names: names, repo: nil).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces == (try expectedPieces(withoutContext(expected))))
  }

  @Test(arguments: hashNameRows)
  func sessionNameThatHoldsAReferenceIsNotScannedAgain(_ input: String, _ expected: String) throws {
    let names = SessionNames(live: hashNames, removed: [:])

    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces == (try expectedPieces(expected, live: hashNames)))
  }

  @Test(arguments: markdownRows)
  func markdownWithAContextRepo(_ markdown: String, _ expected: [Want]) throws {
    let text = try paragraph(markdown)

    #expect(InlineMentions(names: names, repo: contextRepo).pieces(text) == (try expectedPieces(expected)))
  }

  @Test(arguments: markdownRows)
  func markdownWithoutAContextRepoLeavesBareNumbersPlain(_ markdown: String, _ expected: [Want]) throws {
    let text = try paragraph(markdown)

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == (try expectedPieces(withoutContext(expected))))
  }

  @Test(arguments: unchangedMarkdown, contexts)
  func markdownThatMustNotChangePassesThrough(_ markdown: String, _ repo: String?) throws {
    let text = try paragraph(markdown)

    #expect(InlineMentions(names: names, repo: repo).pieces(text) == unchanged(text))
  }

  /// The first run holds no whole id, so the id that the two runs spell together links nothing, while the
  /// reference after it still links.
  @Test(arguments: contexts)
  func newIdSplitAcrossRunsLinksNoSession(_ repo: String?) {
    let text = MarkdownText([Run("see swb_eb4"), Run("ec", .strong), Run(" o/r#1")])

    let pieces = InlineMentions(names: names, repo: repo).pieces(text)

    #expect(!pieces.contains { if case .session? = $0.mention { true } else { false } }, "\(pieces)")
    #expect(pieces.contains { referenced($0.mention) != nil }, "\(pieces)")
  }

  /// A code block never becomes a paragraph's `MarkdownText`, so its references never reach `pieces`.
  @Test(arguments: ["```\n#1\n```", "    #1", "```\nhttps://github.com/o/r/pull/1\n```"])
  func codeBlockIsNotInlineText(_ markdown: String) {
    let blocks = MarkdownBlock.parse(markdown)

    #expect(blocks.count == 1)
    guard case .code = blocks.first else {
      Issue.record("\(markdown) parses to \(blocks), not a code block")
      return
    }
  }

  // MARK: Runs that are not eligible

  @Test(arguments: [
    Run("#1", .code), Run("o/r#1", .code), Run("https://github.com/o/r/pull/1", .code), Run("#1", [.code, .strong]),
    Run("#1", .footnote), Run("o/r#1", .footnote),
    Run("#1", image: "x.png"), Run("PR", link: "https://github.com/o/r/pull/1", image: "x.png"),
    Run("#1", link: "https://x.dev"), Run("o/r#1", link: "https://x.dev"),
    Run("https://github.com/o/r/pull/1", link: "https://x.dev"),
    Run("x", link: "https://github.com/o/r/pull/new/x"), Run("x", link: "https://www.github.com/o/r/pull/1"),
    Run("x", link: "https://github.com/o/r/pull/012"), Run("x", link: "https://github.com/1/2/pull/3"),
    Run("x", link: "https://user@github.com/o/r/pull/1"), Run("x", link: "https://github.com//o/r/pull/1"),
    Run("#1", [.code], link: "https://github.com/o/r/pull/1"),
    Run("x", .footnote, link: "https://github.com/o/r/pull/1"),
  ])
  func ineligibleRunPassesThrough(_ run: MarkdownText.Run) {
    let text = MarkdownText([Run("see "), run, Run(" now")])

    #expect(InlineMentions(names: names, repo: contextRepo).pieces(text) == unchanged(text))
  }

  @Test(arguments: [
    "https://github.com/o/r/pull/1", "http://github.com/o/r/pull/1", "https://github.com/o/r/issues/2#issuecomment-3",
    "HTTPS://GITHUB.COM/o/r/pull/1",
  ])
  func linkRunToAGitHubItemBecomesOneReferenceWithItsRunUnchanged(_ link: String) throws {
    let run = Run("the fix for #9", .strong, link: link)
    let text = MarkdownText([Run("see "), run])

    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(text)

    #expect(pieces == [plain("see "), Piece(run: run, mention: reference(try gitHubRef(link)))])
  }

  @Test func referenceSplitAcrossRunsPassesThrough() {
    let text = MarkdownText([Run("#"), Run("12")])

    #expect(InlineMentions(names: names, repo: contextRepo).pieces(text) == unchanged(text))
  }

  /// cmark-gfm would read the URL on into the next run, so the text in the first run is not the whole URL.
  @Test(arguments: [
    [Run("see https://github.com/o/r/pull/1"), Run("2", .strong)],
    [Run("see https://github.com/o/r/pull/1."), Run("x", .emphasis)],
    [Run("https://github.com/o/r/pull/1"), Run("x", link: "https://x.dev")],
  ])
  func urlCutByARunBoundaryGivesNoReference(_ runs: [MarkdownText.Run]) {
    let text = MarkdownText(runs)

    #expect(InlineMentions(names: names, repo: contextRepo).pieces(text) == unchanged(text))
  }

  @Test func ownerInAnotherRunGivesNoReference() {
    let text = MarkdownText([Run("o/r", .emphasis), Run("#1")])

    #expect(InlineMentions(names: names, repo: contextRepo).pieces(text) == unchanged(text))
  }

  @Test func urlInAnEmphasisRunKeepsItsStyle() throws {
    let url = "https://github.com/o/r/pull/1"
    let text = MarkdownText([Run("see "), Run(url, .emphasis)])

    #expect(
      InlineMentions(names: names, repo: contextRepo).pieces(text) == [
        plain("see "), try referencePiece(url, .emphasis),
      ])
  }

  // MARK: Context repo

  @Test(arguments: ["see #12 now", "#1", "(#1)"])
  func bareNumberWithoutAContextRepoIsPlain(_ input: String) {
    let text = MarkdownText(stringLiteral: input)

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  @Test(arguments: ["", "o", "o/", "/r", "a/b/c", "1/2", "a1/2", "o/r r", "../r", "o/r#1", "https://github.com/o/r"])
  func invalidContextRepoLinksNoBareNumber(_ repo: String) throws {
    let pieces = InlineMentions(names: names, repo: repo).pieces("see #12 and o/r#3")

    #expect(pieces == [plain("see #12 and "), try referencePiece("o/r#3")])
  }

  @Test func bareNumberTakesTheContextRepoAsWritten() throws {
    let pieces = InlineMentions(names: names, repo: "Haacked/Switchboard").pieces("#12")

    #expect(pieces == [try referencePiece("#12", context: "Haacked/Switchboard")])
  }

  @Test(arguments: contexts)
  func emptyDirectoryStillFindsReferences(_ repo: String?) throws {
    let pieces = InlineMentions(names: .empty, repo: repo).pieces("see o/r#1")

    #expect(pieces == [plain("see "), try referencePiece("o/r#1")])
  }

  // MARK: Form and link

  @Test(arguments: [
    ("#12", GitHubRefFields(contextRepo, 12, .shorthand)),
    ("o/r#1", GitHubRefFields("o/r", 1, .shorthand)),
    ("O/R#1", GitHubRefFields("O/R", 1, .shorthand)),
    ("https://github.com/o/r/issues/1", GitHubRefFields("o/r", 1, .issueURL)),
    ("https://github.com/o/r/issues/2#issuecomment-1", GitHubRefFields("o/r", 2, .issueURL)),
    ("https://github.com/o/r/pull/3", GitHubRefFields("o/r", 3, .pullURL)),
    ("https://github.com/o/r/pull/4/files", GitHubRefFields("o/r", 4, .pullURL)),
    ("http://github.com/o/r/pull/5", GitHubRefFields("o/r", 5, .pullURL)),
    ("https://GitHub.com/O/R/issues/6", GitHubRefFields("O/R", 6, .issueURL)),
  ])
  func referenceRecordsItsRepoNumberAndForm(_ input: String, _ expected: GitHubRefFields) throws {
    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(MarkdownText(stringLiteral: input))

    let ref = try #require(referenced(pieces.first?.mention))
    #expect(GitHubRefFields(ref) == expected)
  }

  @Test(arguments: [
    ("#12", false), ("o/r#1", false), ("https://github.com/o/r/issues/1", false),
    ("https://github.com/o/r/pull/1", true),
  ])
  func onlyAPullRequestURLSaysTheItemIsAPullRequest(_ input: String, _ isPull: Bool) throws {
    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(MarkdownText(stringLiteral: input))

    #expect(try #require(referenced(pieces.first?.mention)).isPull == isPull)
  }

  @Test(arguments: [
    ("#12", "https://github.com/haacked/switchboard/issues/12"),
    ("o/r#1", "https://github.com/o/r/issues/1"),
    ("O/R#5", "https://github.com/O/R/issues/5"),
    ("https://github.com/o/r/pull/1", "https://github.com/o/r/pull/1"),
    ("https://github.com/o/r/pull/1#issuecomment-1", "https://github.com/o/r/pull/1#issuecomment-1"),
    ("https://github.com/o/r/issues/1#issuecomment-2", "https://github.com/o/r/issues/1#issuecomment-2"),
    ("https://github.com/o/r/pull/1/files?w=1", "https://github.com/o/r/pull/1/files?w=1"),
    ("https://GitHub.com/o/r/pull/1", "https://GitHub.com/o/r/pull/1"),
    ("http://github.com/o/r/issues/1", "https://github.com/o/r/issues/1"),
    ("http://github.com/o/r/pull/1#issuecomment-1", "https://github.com/o/r/pull/1"),
  ])
  func referenceLinksToItsHttpsTextOrToTheItemsPage(_ input: String, _ link: String) {
    let pieces = InlineMentions(names: names, repo: contextRepo).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces.count == 1)
    #expect(referenced(pieces.first?.mention) != nil)
    #expect(pieces.first?.run.link == link)
  }

  // MARK: Parity

  @Test func unstyledInputsAreNotFew() {
    #expect(unstyledInputs.count >= 60)
  }

  @Test(arguments: unstyledInputs, contexts)
  func plainTextAndItsParagraphFindTheSameReferences(_ input: String, _ repo: String?) throws {
    let mentions = InlineMentions(names: names, repo: repo)

    let fromPlain = mentions.pieces(MarkdownText(stringLiteral: input))
    let fromParagraph = mentions.pieces(try paragraph(input))

    #expect(found(fromPlain) == found(fromParagraph))
  }

  /// A URL in unstyled text, which cmark makes an autolink.
  @Test(arguments: [
    "See https://github.com/o/r/pull/1.", "(https://github.com/o/r/pull/1)",
    "see https://github.com/o/r/issues/1?q=(a) now",
    "(see https://github.com/o/r/issues/1?q=(a))", "https://github.com/o/r/pull/1/files#diff-1,",
    "https://github.com/o/r/pull/1!", "https://github.com/o/r/pull/1?", "https://github.com/o/r/pull/1:",
    "https://github.com/o/r/pull/1;", "https://github.com/o/r/pull/1'", "https://github.com/o/r/pull/1\"",
    "(see https://github.com/o/r/pull/1.)", "see https://github.com/o/r/pull/1)) now",
    "x https://github.com/o/r/pull/1#issuecomment-1. y", "http://github.com/o/r/issues/1.",
    "https://GitHub.com/o/r/pull/1.", "https://github.com/o/r/pull/1/commits/0123abc, then",
    // cmark-gfm drops a trailing `&entity;` from an autolink.
    "https://github.com/o/r/pull/1&amp;", "see https://github.com/o/r/pull/1?a=1&b; now",
  ])
  func plainURLAndItsAutolinkCoverTheSameText(_ input: String) throws {
    let mentions = InlineMentions(names: names, repo: contextRepo)

    let fromPlain = found(mentions.pieces(MarkdownText(stringLiteral: input)))
    let fromAutolink = found(mentions.pieces(try paragraph(input)))

    #expect(fromPlain.count == 1)
    #expect(fromPlain == fromAutolink)
  }

  @Test(arguments: plainInputs, contexts)
  func referencesNeverChangeTheText(_ input: String, _ repo: String?) {
    let pieces = InlineMentions(names: names, repo: repo).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces.map(\.run.text).joined() == names.replacingIDs(in: input))
  }

  // MARK: Overlap

  @Test(arguments: plainInputs, contexts)
  func plainPiecesWithoutSessionsJoinToTheInput(_ input: String, _ repo: String?) {
    let pieces = InlineMentions(names: .empty, repo: repo).pieces(MarkdownText(stringLiteral: input))

    #expect(pieces.map(\.run.text).joined() == input)
  }

  @Test(arguments: plainInputs, contexts)
  func plainPiecesSpellTheInput(_ input: String, _ repo: String?) {
    let names = SessionNames(live: liveNames.merging(hashNames) { a, _ in a }, removed: [:])

    let pieces = InlineMentions(names: names, repo: repo).pieces(MarkdownText(stringLiteral: input))

    #expect(spell(pieces, input), "\(pieces)")
  }

  @Test(arguments: markdownInputs, contexts)
  func markdownPiecesWithoutSessionsJoinToTheText(_ markdown: String, _ repo: String?) throws {
    let text = try paragraph(markdown)

    #expect(InlineMentions(names: .empty, repo: repo).pieces(text).map(\.run.text).joined() == text.plain)
  }

  @Test(arguments: markdownInputs, contexts)
  func markdownPiecesSpellTheText(_ markdown: String, _ repo: String?) throws {
    let text = try paragraph(markdown)

    let pieces = InlineMentions(names: names, repo: repo).pieces(text)

    #expect(spell(pieces, text.plain), "\(pieces)")
  }

  // MARK: Performance

  /// One reference of each form in turn.
  private static func referenceText(_ i: Int) -> String {
    switch i % 4 {
    case 0: "#\(i + 1)"
    case 1: "o/r#\(i + 1)"
    case 2: "https://github.com/o/r/pull/\(i + 1)"
    default: "(https://github.com/o/r/issues/\(i + 1)/files?x=#\(i))"
    }
  }

  /// Text around each mention: look-alike words, numbers, punctuation, a URL that is no reference, and multibyte characters.
  private static let filler =
    " to rebase, then check café ☕ build 1.2#3 for the stream, see https://example.com/a,#4 and step 12:30 on main; "

  @Test func findingTwoThousandIdsOfEachFormAndAReferenceForEachInOneRunGrowsLinearly() {
    let ((text, _), pieces) = expectLinearGrowth { count in
      let ids = ManySessions.ids(count)
      let string = ids.enumerated().map { "Ask \($1) about \(Self.referenceText($0))\(Self.filler)" }.joined()
      return (MarkdownText(stringLiteral: string), InlineMentions(names: ManySessions.names(ids), repo: contextRepo))
    } _: { text, mentions in
      mentions.pieces(text)
    }

    #expect(text.plain.utf8.count >= 200_000)
    #expect(
      pieces.count(where: { if case .session? = $0.mention { true } else { false } }) == ManySessions.largeIdCount)
    #expect(pieces.count(where: { referenced($0.mention) != nil }) == ManySessions.largeIdCount)
  }

  @Test func findingTwoThousandIdsOfEachFormAndAReferenceForEachAcrossManyRunsGrowsLinearly() {
    let ((text, _), pieces) = expectLinearGrowth { count in
      let ids = ManySessions.ids(count)
      let runs = ids.enumerated().flatMap { i, id in
        [Run("Ask "), Run(id, .emphasis), Run(" about "), Run(Self.referenceText(i), .strong), Run(Self.filler)]
      }
      return (MarkdownText(runs), InlineMentions(names: ManySessions.names(ids), repo: contextRepo))
    } _: { text, mentions in
      mentions.pieces(text)
    }

    #expect(text.plain.utf8.count >= 200_000)
    #expect(
      pieces.count(where: { if case .session? = $0.mention { true } else { false } }) == ManySessions.largeIdCount)
    #expect(pieces.count(where: { referenced($0.mention) != nil }) == ManySessions.largeIdCount)
  }
}
