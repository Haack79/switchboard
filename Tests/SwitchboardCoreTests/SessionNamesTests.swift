import Foundation
import Testing

@testable import SwitchboardCore

private typealias Run = MarkdownText.Run
private typealias Piece = InlineMentions.Piece
private typealias Match = SessionNames.Match

private let liveNames: [String: String] = [
  "seb4ec": "zsh-startup-for-switchboard",
  "sgcctv": "render-session-names",
  // A name that holds another session's id. The matcher must not scan it again.
  "sn4mzz": "redo sgcctv",
  // A name with characters that a regular expression would read as syntax.
  "s23456": "v1.2+fix",
  // Ids with other `shortId` prefixes, and an id outside the alphabet. None of
  // them has the session id shape, so text that holds them stays as written.
  "g4rvrf": "a-group",
  "w3k9ap": "a-wait",
  "sl0ok1": "not-an-id",
  // A new-form id.
  "swb_eb4ec": "new-id-form",
]

private let removedNames: [String: String] = ["sq7kpm": "old-cleanup", "swb_q7kpm": "removed-new-form"]

private var names: SessionNames { SessionNames(live: liveNames, removed: removedNames) }

private func text(_ runs: Run...) -> MarkdownText { MarkdownText(runs) }

private func piece(_ text: String, _ style: MarkdownText.Style = [], link: String? = nil, image: String? = nil)
  -> Piece
{
  Piece(run: Run(text, style, link: link, image: image), mention: nil)
}

/// The piece for a session in the test directory. A live entry wins over a removed one.
private func mention(
  _ id: String, _ style: MarkdownText.Style = [], live: [String: String] = liveNames,
  removed: [String: String] = removedNames
) -> Piece {
  let name = live[id] ?? removed[id] ?? "missing fixture \(id)"
  return Piece(run: Run(name, style), mention: .session(Match(id: id, name: name, removed: live[id] == nil)))
}

private func unchanged(_ text: MarkdownText) -> [Piece] { text.runs.map { Piece(run: $0, mention: nil) } }

/// The pieces that a row's expected text describes. `⟨id⟩` stands for the
/// session's name, matched. The rest is unstyled text.
private func expectedPieces(_ marked: String, live: [String: String] = liveNames) -> [Piece] {
  var pieces: [Piece] = []
  var rest = Substring(marked)
  while let open = rest.firstIndex(of: "⟨"), let close = rest[open...].firstIndex(of: "⟩") {
    if open > rest.startIndex { pieces.append(piece(String(rest[..<open]))) }
    pieces.append(mention(String(rest[rest.index(after: open)..<close]), live: live))
    rest = rest[rest.index(after: close)...]
  }
  if !rest.isEmpty { pieces.append(piece(String(rest))) }
  return pieces
}

/// The plain text that a row's expected text describes.
private func expectedPlain(_ marked: String, live: [String: String] = liveNames) -> String {
  expectedPieces(marked, live: live).map(\.run.text).joined()
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

/// Unstyled text that the matcher must leave exactly as written.
private let unchangedPlain: [String] = [
  "",
  "no session ids here",
  // Unknown ids and look-alike words that no session has as its id.
  "sx2zzz", "Ask sx2zzz to rebase", "stream", "switch", "submit", "street", "the stream and the street",
  // Other `shortId` prefixes and an id outside the alphabet, all in the directory.
  "g4rvrf", "w3k9ap", "group g4rvrf and wait w3k9ap", "sl0ok1",
  // Case and length.
  "SEB4EC", "Seb4ec", "seb4ecx", "xseb4ec", "2seb4ec", "seb4ec2",
  // Unicode letters and digits.
  "éseb4ec", "seb4ecé", "seb4ecü", "٣seb4ec", "seb4ec٣",
  // A combining mark joins the id to the letter it modifies.
  "e\u{0301}seb4ec", "seb4ec\u{0301}",
  // Pane names, paths, assignments, tags, and URLs.
  "seb4ec-claude", "sessions/seb4ec/claude.sh", "SB_SESSION_ID=seb4ec", "#seb4ec", "@seb4ec",
  "https://example.com/seb4ec", "C:\\seb4ec", "host:seb4ec",
  // `.ext` and `:suffix`.
  "seb4ec.jsonl", "seb4ec:card", "seb4ec:5", "seb4ec.2", "seb4ec.é", ".seb4ec", ":seb4ec",
  // A `.` or `:` followed by something other than whitespace, a closing mark, or the end.
  "seb4ec:/tmp", "seb4ec._x", "seb4ec.*", "seb4ec:-x", "seb4ec../x", "seb4ec::x",
  // Each character that the boundary rules forbid, on each side.
  "_seb4ec", "seb4ec_", "-seb4ec", "seb4ec-", "/seb4ec", "seb4ec/", "\\seb4ec", "seb4ec\\", "seb4ec@",
  "seb4ec#", "$seb4ec", "seb4ec$", "=seb4ec", "seb4ec=1", "~seb4ec", "seb4ec~", "&seb4ec", "seb4ec&",
  "%seb4ec", "seb4ec%", "+seb4ec", "seb4ec+",
  // The same shapes with the removed session's id.
  "sq7kpm-claude", "sessions/sq7kpm/claude.sh", "sq7kpm.jsonl",
  // An id inside a URL that Markdown did not link. The URL runs to the next whitespace, as a GFM autolink does.
  "https://example.com/?seb4ec", "https://example.com/a,seb4ec", "https://example.com/(seb4ec)",
  "https://example.com/x?a;seb4ec", "see https://example.com/?seb4ec now", "http://example.com/a,seb4ec",
  "(https://example.com/x)seb4ec", "see https://example.com/x,seb4ec", "https://github.com/o/r/pull/new/x,seb4ec",
  "https://example.com/?sq7kpm",
  // New-form ids: an unknown id, case, the prefix written another way, length, and letters on either side.
  "swb_zzzzz", "Ask swb_zzzzz to rebase", "SWB_eb4ec", "Swb_eb4ec", "swb_EB4EC", "swb-eb4ec", "swb__eb4ec",
  "swbeb4ec", "sw_eb4ec", "wb_eb4ec", "swb_eb4e", "swb_eb4ecx", "xswb_eb4ec", "2swb_eb4ec", "swb_eb4ec2", "éswb_eb4ec",
  "swb_eb4ecé",
  // Each character that the boundary rules forbid, on each side of a new-form id.
  "x_swb_eb4ec", "swb_eb4ec_x", "_swb_eb4ec", "swb_eb4ec_", "swb_eb4ec-x", "-swb_eb4ec", "/swb_eb4ec", "swb_eb4ec/",
  "\\swb_eb4ec", "#swb_eb4ec", "@swb_eb4ec", "swb_eb4ec@", "=swb_eb4ec", "swb_eb4ec=1", "~swb_eb4ec", "+swb_eb4ec",
  // Pane names, paths, assignments, `.ext`, `:suffix`, and URLs with a new-form id.
  "swb_eb4ec-claude", "swb_eb4ec-shell", "sessions/swb_eb4ec/claude.sh", "SB_SESSION_ID=swb_eb4ec", "swb_eb4ec.jsonl",
  "swb_eb4ec:card", "swb_eb4ec:/tmp", "swb_eb4ec._x", "host:swb_eb4ec", "https://example.com/swb_eb4ec",
  "https://example.com/?swb_eb4ec", "swb_q7kpm-claude", "sessions/swb_q7kpm/claude.sh", "swb_q7kpm.jsonl",
]

/// Unstyled text and the pieces the matcher gives for it, written as described in `expectedPieces`.
private let changedPlain: [(String, String)] = [
  // Position in the text.
  ("seb4ec", "⟨seb4ec⟩"),
  ("seb4ec is done", "⟨seb4ec⟩ is done"),
  ("Ask seb4ec to rebase", "Ask ⟨seb4ec⟩ to rebase"),
  ("waiting on seb4ec", "waiting on ⟨seb4ec⟩"),
  // Punctuation and whitespace neighbors.
  ("(seb4ec)", "(⟨seb4ec⟩)"),
  ("[seb4ec]", "[⟨seb4ec⟩]"),
  ("\"seb4ec\"", "\"⟨seb4ec⟩\""),
  ("'seb4ec'", "'⟨seb4ec⟩'"),
  ("seb4ec, then", "⟨seb4ec⟩, then"),
  ("a,seb4ec", "a,⟨seb4ec⟩"),
  (";seb4ec;", ";⟨seb4ec⟩;"),
  ("!seb4ec!", "!⟨seb4ec⟩!"),
  ("?seb4ec?", "?⟨seb4ec⟩?"),
  ("*seb4ec*", "*⟨seb4ec⟩*"),
  ("waiting on seb4ec.", "waiting on ⟨seb4ec⟩."),
  ("seb4ec. Next", "⟨seb4ec⟩. Next"),
  ("seb4ec.)", "⟨seb4ec⟩.)"),
  ("seb4ec: done", "⟨seb4ec⟩: done"),
  ("waiting on seb4ec:", "waiting on ⟨seb4ec⟩:"),
  ("seb4ec…", "⟨seb4ec⟩…"),
  ("seb4ec...", "⟨seb4ec⟩..."),
  ("seb4ec... then", "⟨seb4ec⟩... then"),
  ("'waiting on seb4ec.'", "'waiting on ⟨seb4ec⟩.'"),
  ("\"waiting on seb4ec.\"", "\"waiting on ⟨seb4ec⟩.\""),
  ("\u{2018}waiting on seb4ec.\u{2019}", "\u{2018}waiting on ⟨seb4ec⟩.\u{2019}"),
  ("[seb4ec.]", "[⟨seb4ec⟩.]"),
  ("\u{201C}waiting on seb4ec.\u{201D}", "\u{201C}waiting on ⟨seb4ec⟩.\u{201D}"),
  ("[seb4ec:]", "[⟨seb4ec⟩:]"),
  ("seb4ec.\u{00A0}now", "⟨seb4ec⟩.\u{00A0}now"),
  ("seb4ec's PR", "⟨seb4ec⟩'s PR"),
  ("seb4ec\u{2019}s PR", "⟨seb4ec⟩\u{2019}s PR"),
  ("a\nseb4ec\nb", "a\n⟨seb4ec⟩\nb"),
  ("a\tseb4ec\tb", "a\t⟨seb4ec⟩\tb"),
  ("a\u{2014}seb4ec\u{2014}b", "a\u{2014}⟨seb4ec⟩\u{2014}b"),
  ("seb4ec\u{00A0}now", "⟨seb4ec⟩\u{00A0}now"),
  ("🙂seb4ec🙂", "🙂⟨seb4ec⟩🙂"),
  // Commands in prose are not protected.
  ("sb send seb4ec hi", "sb send ⟨seb4ec⟩ hi"),
  // Several ids.
  ("seb4ec and seb4ec", "⟨seb4ec⟩ and ⟨seb4ec⟩"),
  ("sgcctv,seb4ec", "⟨sgcctv⟩,⟨seb4ec⟩"),
  ("sgcctv seb4ec", "⟨sgcctv⟩ ⟨seb4ec⟩"),
  ("sgcctv and sq7kpm", "⟨sgcctv⟩ and ⟨sq7kpm⟩"),
  ("sq7kpm", "⟨sq7kpm⟩"),
  // A replacement is not scanned again.
  ("sn4mzz", "⟨sn4mzz⟩"),
  ("s23456", "⟨s23456⟩"),
  // `name (id)` and `id (name)` collapse to one piece.
  ("zsh-startup-for-switchboard (seb4ec)", "⟨seb4ec⟩"),
  ("Ask zsh-startup-for-switchboard (seb4ec) to rebase", "Ask ⟨seb4ec⟩ to rebase"),
  ("seb4ec (zsh-startup-for-switchboard)", "⟨seb4ec⟩"),
  ("seb4ec (zsh-startup-for-switchboard) is done", "⟨seb4ec⟩ is done"),
  ("old-cleanup (sq7kpm)", "⟨sq7kpm⟩"),
  ("sq7kpm (old-cleanup)", "⟨sq7kpm⟩"),
  ("v1.2+fix (s23456)", "⟨s23456⟩"),
  ("redo sgcctv (sn4mzz)", "⟨sn4mzz⟩"),
  ("sn4mzz (redo sgcctv)", "⟨sn4mzz⟩"),
  ("zsh-startup-for-switchboard (seb4ec) and seb4ec", "⟨seb4ec⟩ and ⟨seb4ec⟩"),
  ("Ask zsh-startup-for-switchboard (seb4ec).", "Ask ⟨seb4ec⟩."),
  // A title capitalizes its first letter, so the name there may start with a capital.
  ("Zsh-startup-for-switchboard (seb4ec) is done", "⟨seb4ec⟩ is done"),
  ("Ask Zsh-startup-for-switchboard (seb4ec)", "Ask Zsh-startup-for-switchboard (⟨seb4ec⟩)"),
  ("Ask seb4ec (zsh-startup-for-switchboard).", "Ask ⟨seb4ec⟩."),
  // Text that touches the closing parenthesis: only the id changes.
  ("zsh-startup-for-switchboard (seb4ec)x", "zsh-startup-for-switchboard (⟨seb4ec⟩)x"),
  ("seb4ec (zsh-startup-for-switchboard)x", "⟨seb4ec⟩ (zsh-startup-for-switchboard)x"),
  ("zsh-startup-for-switchboard (seb4ec)-claude", "zsh-startup-for-switchboard (⟨seb4ec⟩)-claude"),
  ("seb4ec (zsh-startup-for-switchboard)/x", "⟨seb4ec⟩ (zsh-startup-for-switchboard)/x"),
  ("zsh-startup-for-switchboard (seb4ec).jsonl", "zsh-startup-for-switchboard (⟨seb4ec⟩).jsonl"),
  ("seb4ec (zsh-startup-for-switchboard):card", "⟨seb4ec⟩ (zsh-startup-for-switchboard):card"),
  // Another name, a longer word that ends with the name, or no space: only the id changes.
  ("The dotfiles session (seb4ec)", "The dotfiles session (⟨seb4ec⟩)"),
  ("render-session-names (seb4ec)", "render-session-names (⟨seb4ec⟩)"),
  ("my-zsh-startup-for-switchboard (seb4ec)", "my-zsh-startup-for-switchboard (⟨seb4ec⟩)"),
  ("zsh-startup-for-switchboard(seb4ec)", "zsh-startup-for-switchboard(⟨seb4ec⟩)"),
  ("v1x2+fix (s23456)", "v1x2+fix (⟨s23456⟩)"),
  ("seb4ec (zsh-startup-for-switchboard-v2)", "⟨seb4ec⟩ (zsh-startup-for-switchboard-v2)"),
  ("seb4ec (zsh-startup-for-switchboard and more)", "⟨seb4ec⟩ (zsh-startup-for-switchboard and more)"),
  ("sgcctv (seb4ec)", "⟨sgcctv⟩ (⟨seb4ec⟩)"),
  // A URL ends at whitespace, and GFM leaves trailing punctuation out of it.
  ("https://example.com/x seb4ec", "https://example.com/x ⟨seb4ec⟩"),
  ("see https://example.com/x, seb4ec", "see https://example.com/x, ⟨seb4ec⟩"),
  ("see https://example.com/x. seb4ec", "see https://example.com/x. ⟨seb4ec⟩"),
  ("(https://example.com/x) seb4ec", "(https://example.com/x) ⟨seb4ec⟩"),
  ("seb4ec https://example.com/?seb4ec", "⟨seb4ec⟩ https://example.com/?seb4ec"),
  // New-form ids, alone, beside punctuation, and beside old-form ids.
  ("swb_eb4ec", "⟨swb_eb4ec⟩"),
  ("swb_eb4ec is done", "⟨swb_eb4ec⟩ is done"),
  ("Ask swb_eb4ec to rebase", "Ask ⟨swb_eb4ec⟩ to rebase"),
  ("see swb_eb4ec", "see ⟨swb_eb4ec⟩"),
  ("(swb_eb4ec)", "(⟨swb_eb4ec⟩)"),
  ("[swb_eb4ec]", "[⟨swb_eb4ec⟩]"),
  ("\"swb_eb4ec\"", "\"⟨swb_eb4ec⟩\""),
  ("swb_eb4ec, then", "⟨swb_eb4ec⟩, then"),
  ("waiting on swb_eb4ec.", "waiting on ⟨swb_eb4ec⟩."),
  ("waiting on swb_eb4ec:", "waiting on ⟨swb_eb4ec⟩:"),
  ("swb_eb4ec: done", "⟨swb_eb4ec⟩: done"),
  ("swb_eb4ec's PR", "⟨swb_eb4ec⟩'s PR"),
  ("a\nswb_eb4ec\nb", "a\n⟨swb_eb4ec⟩\nb"),
  ("🙂swb_eb4ec🙂", "🙂⟨swb_eb4ec⟩🙂"),
  ("sb send swb_eb4ec hi", "sb send ⟨swb_eb4ec⟩ hi"),
  ("swb_q7kpm", "⟨swb_q7kpm⟩"),
  ("seb4ec and swb_eb4ec", "⟨seb4ec⟩ and ⟨swb_eb4ec⟩"),
  ("swb_eb4ec and seb4ec", "⟨swb_eb4ec⟩ and ⟨seb4ec⟩"),
  ("swb_eb4ec,seb4ec", "⟨swb_eb4ec⟩,⟨seb4ec⟩"),
  ("sgcctv swb_eb4ec sq7kpm swb_q7kpm", "⟨sgcctv⟩ ⟨swb_eb4ec⟩ ⟨sq7kpm⟩ ⟨swb_q7kpm⟩"),
  // `name (id)` and `id (name)` with a new-form id.
  ("new-id-form (swb_eb4ec)", "⟨swb_eb4ec⟩"),
  ("Ask new-id-form (swb_eb4ec) to rebase", "Ask ⟨swb_eb4ec⟩ to rebase"),
  ("swb_eb4ec (new-id-form)", "⟨swb_eb4ec⟩"),
  ("swb_eb4ec (new-id-form) is done", "⟨swb_eb4ec⟩ is done"),
  ("New-id-form (swb_eb4ec) is done", "⟨swb_eb4ec⟩ is done"),
  ("removed-new-form (swb_q7kpm)", "⟨swb_q7kpm⟩"),
  ("swb_q7kpm (removed-new-form)", "⟨swb_q7kpm⟩"),
  ("new-id-form (swb_eb4ec)x", "new-id-form (⟨swb_eb4ec⟩)x"),
  ("zsh-startup-for-switchboard (swb_eb4ec)", "zsh-startup-for-switchboard (⟨swb_eb4ec⟩)"),
  ("swb_eb4ec https://example.com/?swb_eb4ec", "⟨swb_eb4ec⟩ https://example.com/?swb_eb4ec"),
]

/// Markdown that the matcher must leave exactly as `MarkdownBlock.parse` gives it.
private let unchangedMarkdown: [String] = [
  // Code spans other than one exact, resolving id.
  "`sb send seb4ec hi`", "`seb4ec.`", "`sx2zzz`", "`g4rvrf`", "<kbd>sb send seb4ec</kbd>",
  // Links, autolinks, HTML links, and images.
  "[seb4ec](https://example.com)", "[the session](https://example.com/seb4ec)", "<https://example.com/seb4ec>",
  "see https://example.com/seb4ec now", "www.seb4ec.com", "<a href=\"https://x.example\">seb4ec</a>",
  "see ![seb4ec](x.png) now",
  // A letter in a neighboring run touches the id.
  "*a*seb4ec", "seb4ec*a*", "see`seb4ec`", "`seb4ec`s", "`x`seb4ec", "seb4ec`x`", "[x](u)seb4ec", "seb4ec[x](u)",
  // An escape or entity that puts a forbidden character next to the id.
  "seb4ec\\_x", "seb4ec&amp;x",
  // A `.` in the next run, followed by a word.
  "**seb4ec**.jsonl", "**seb4ec**:/tmp", "`seb4ec`:/tmp",
  // New-form ids: code spans that hold more than the id, links, and a letter or `_` in a neighboring run.
  "`sb send swb_eb4ec hi`", "`swb_eb4ec x`", "`x swb_eb4ec`", "`swb_eb4ec.`", "`swb_zzzzz`",
  "[swb_eb4ec](https://example.com)", "[the session](https://example.com/swb_eb4ec)", "see ![swb_eb4ec](x.png) now",
  "*a*swb_eb4ec", "swb_eb4ec*a*", "`x`swb_eb4ec", "swb_eb4ec`x`", "x_swb_eb4ec", "swb_eb4ec\\_x", "**swb_eb4ec**.jsonl",
]

private let docsLink = "https://example.com/docs"

/// No repository, and a repository that a bare `#123` would refer to. No row holds a reference, so the rows give the
/// same pieces with either.
private let contexts: [String?] = [nil, "haacked/switchboard"]

/// Markdown and the pieces the matcher gives for it.
private let changedMarkdown: [(String, [Piece])] = [
  ("`seb4ec`", [mention("seb4ec")]),
  ("`sq7kpm`", [mention("sq7kpm")]),
  ("<code>seb4ec</code>", [mention("seb4ec")]),
  ("*seb4ec*", [mention("seb4ec", .emphasis)]),
  ("**seb4ec**", [mention("seb4ec", .strong)]),
  ("~~seb4ec~~", [mention("seb4ec", .strikethrough)]),
  ("*`seb4ec`*", [mention("seb4ec", .emphasis)]),
  ("(*seb4ec*)", [piece("("), mention("seb4ec", .emphasis), piece(")")]),
  ("**Ask seb4ec now**", [piece("Ask ", .strong), mention("seb4ec", .strong), piece(" now", .strong)]),
  ("*x* seb4ec", [piece("x", .emphasis), piece(" "), mention("seb4ec")]),
  ("**bold** seb4ec", [piece("bold", .strong), piece(" "), mention("seb4ec")]),
  ("seb4ec [docs](\(docsLink))", [mention("seb4ec"), piece(" "), piece("docs", link: docsLink)]),
  ("\\*seb4ec\\*", [piece("*"), mention("seb4ec"), piece("*")]),
  ("seb4ec&nbsp;now", [mention("seb4ec"), piece("\u{00A0}now")]),
  ("*zsh-startup-for-switchboard (seb4ec)*", [mention("seb4ec", .emphasis)]),
  ("Ask **seb4ec**.", [piece("Ask "), mention("seb4ec", .strong), piece(".")]),
  // A word in the next run touches the closing parenthesis: only the id changes.
  (
    "zsh-startup-for-switchboard (seb4ec)*x*",
    [piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")"), piece("x", .emphasis)]
  ),
  (
    "seb4ec (zsh-startup-for-switchboard)`x`",
    [mention("seb4ec"), piece(" (zsh-startup-for-switchboard)"), piece("x", .code)]
  ),
  // The name and the id in different runs: only the id changes.
  (
    "**zsh-startup-for-switchboard** (seb4ec)",
    [piece("zsh-startup-for-switchboard", .strong), piece(" ("), mention("seb4ec"), piece(")")]
  ),
  (
    "seb4ec (*zsh-startup-for-switchboard*)",
    [mention("seb4ec"), piece(" ("), piece("zsh-startup-for-switchboard", .emphasis), piece(")")]
  ),
  ("zsh-startup-for-switchboard (`seb4ec`)", [piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")")]),
  // New-form ids. cmark reads the `_` inside the id as text, so it opens and closes no emphasis.
  ("see swb_eb4ec here", [piece("see "), mention("swb_eb4ec"), piece(" here")]),
  ("swb\\_eb4ec", [mention("swb_eb4ec")]),
  ("`swb_eb4ec`", [mention("swb_eb4ec")]),
  ("`swb_q7kpm`", [mention("swb_q7kpm")]),
  ("<code>swb_eb4ec</code>", [mention("swb_eb4ec")]),
  ("_swb_eb4ec_", [mention("swb_eb4ec", .emphasis)]),
  ("*swb_eb4ec*", [mention("swb_eb4ec", .emphasis)]),
  ("__swb_eb4ec__", [mention("swb_eb4ec", .strong)]),
  ("**swb_eb4ec**", [mention("swb_eb4ec", .strong)]),
  ("~~swb_eb4ec~~", [mention("swb_eb4ec", .strikethrough)]),
  ("Ask **swb_eb4ec**.", [piece("Ask "), mention("swb_eb4ec", .strong), piece(".")]),
  ("seb4ec and swb_eb4ec", [mention("seb4ec"), piece(" and "), mention("swb_eb4ec")]),
  ("_new-id-form (swb_eb4ec)_", [mention("swb_eb4ec", .emphasis)]),
  ("new-id-form (`swb_eb4ec`)", [piece("new-id-form ("), mention("swb_eb4ec"), piece(")")]),
]

@Suite struct SessionNamesTests {
  @Test func mentionPutsTheNameFirst() {
    #expect(sessionMention(name: "zsh-startup-for-switchboard", id: "seb4ec") == "zsh-startup-for-switchboard (seb4ec)")
  }

  @Test func entryResolvesALiveSession() {
    let entry = names.entry("seb4ec")

    #expect(entry?.name == "zsh-startup-for-switchboard")
    #expect(entry?.removed == false)
  }

  @Test func entryResolvesARemovedSession() {
    let entry = names.entry("sq7kpm")

    #expect(entry?.name == "old-cleanup")
    #expect(entry?.removed == true)
  }

  @Test func entryOfAnUnknownIdIsNil() {
    #expect(names.entry("sx2zzz") == nil)
  }

  @Test func liveEntryWinsOverATombstone() {
    let names = SessionNames(live: ["seb4ec": "new-name"], removed: ["seb4ec": "old-name"])

    let entry = names.entry("seb4ec")

    #expect(entry?.name == "new-name")
    #expect(entry?.removed == false)
  }

  @Test func liveEntryWinsOverATombstoneInText() {
    let live = ["seb4ec": "new-name"]
    let names = SessionNames(live: live, removed: ["seb4ec": "old-name"])

    let pieces = InlineMentions(names: names, repo: nil).pieces("old-name (seb4ec)")

    #expect(pieces == [piece("old-name ("), mention("seb4ec", live: live, removed: [:]), piece(")")])
  }

  @Test func emptyDirectoryIsEmpty() {
    #expect(SessionNames(live: [:], removed: [:]).isEmpty)
  }

  @Test(arguments: [(["seb4ec": "a"], [String: String]()), ([:], ["sq7kpm": "b"])])
  func directoryWithAnEntryIsNotEmpty(_ live: [String: String], _ removed: [String: String]) {
    #expect(!SessionNames(live: live, removed: removed).isEmpty)
  }

  @Test func directoriesWithTheSameEntriesAreEqual() {
    #expect(SessionNames(live: liveNames, removed: removedNames) == names)
  }

  @Test(arguments: [
    (["seb4ec": "a"], ["seb4ec": "b"]),
    (["seb4ec": "a"], ["sgcctv": "a"]),
  ])
  func directoriesWithDifferentLiveEntriesAreNotEqual(_ a: [String: String], _ b: [String: String]) {
    #expect(SessionNames(live: a, removed: [:]) != SessionNames(live: b, removed: [:]))
  }

  @Test func directoriesThatDifferInRemovalAreNotEqual() {
    #expect(SessionNames(live: ["seb4ec": "a"], removed: [:]) != SessionNames(live: [:], removed: ["seb4ec": "a"]))
  }

  @Test(arguments: unchangedPlain, contexts)
  func plainTextThatMustNotChangePassesThrough(_ input: String, _ repo: String?) {
    let text = MarkdownText(stringLiteral: input)

    #expect(InlineMentions(names: names, repo: repo).pieces(text) == unchanged(text))
  }

  @Test(arguments: unchangedPlain)
  func plainStringThatMustNotChangeComesBackAsWritten(_ input: String) {
    #expect(names.replacingIDs(in: input) == input)
  }

  @Test(arguments: changedPlain, contexts)
  func plainTextIdsBecomeNames(_ row: (String, String), _ repo: String?) {
    #expect(
      InlineMentions(names: names, repo: repo).pieces(MarkdownText(stringLiteral: row.0)) == expectedPieces(row.1))
  }

  @Test(arguments: changedPlain)
  func plainStringIdsBecomeNames(_ input: String, _ expected: String) {
    #expect(names.replacingIDs(in: input) == expectedPlain(expected))
  }

  @Test(arguments: unchangedPlain + changedPlain.map(\.0))
  func emptyDirectoryChangesNothing(_ input: String) {
    let names = SessionNames(live: [:], removed: [:])
    let text = MarkdownText(stringLiteral: input)

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
    #expect(names.replacingIDs(in: input) == input)
  }

  @Test(arguments: [
    ("Fix the stream reader", "Fix the ⟨stream⟩ reader"),
    ("streams", "streams"),
    ("upstream", "upstream"),
  ])
  func sessionWhoseIdIsAWordRewritesThatWord(_ input: String, _ expected: String) {
    let live = ["stream": "stream-fix"]
    let names = SessionNames(live: live, removed: [:])

    #expect(
      InlineMentions(names: names, repo: nil).pieces(MarkdownText(stringLiteral: input))
        == expectedPieces(expected, live: live))
  }

  @Test(arguments: unchangedMarkdown, contexts)
  func markdownThatMustNotChangePassesThrough(_ markdown: String, _ repo: String?) throws {
    let text = try paragraph(markdown)

    #expect(InlineMentions(names: names, repo: repo).pieces(text) == unchanged(text))
  }

  @Test(arguments: changedMarkdown, contexts)
  func markdownIdsBecomeNames(_ row: (String, [InlineMentions.Piece]), _ repo: String?) throws {
    let text = try paragraph(row.0)

    #expect(InlineMentions(names: names, repo: repo).pieces(text) == row.1)
  }

  /// A code block never becomes a paragraph's `MarkdownText`, so its ids never reach `pieces`.
  @Test(arguments: ["```\nseb4ec\n```", "    seb4ec"])
  func codeBlockIsNotInlineText(_ markdown: String) {
    let blocks = MarkdownBlock.parse(markdown)

    #expect(blocks.count == 1)
    guard case .code(_, let code) = blocks.first else {
      Issue.record("\(markdown) parses to \(blocks), not a code block")
      return
    }
    #expect(code.contains("seb4ec"))
  }

  @Test func aClosingParenthesisInAnotherRunKeepsTheNameAsWritten() {
    let text = text(Run("zsh-startup-for-switchboard (seb4ec"), Run(")", .emphasis))

    #expect(
      InlineMentions(names: names, repo: nil).pieces(text) == [
        piece("zsh-startup-for-switchboard ("), mention("seb4ec"), piece(")", .emphasis),
      ])
  }

  @Test func footnoteRunPassesThrough() {
    let text = text(Run("See "), Run("seb4ec", .footnote))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  @Test func imageRunPassesThrough() {
    let text = text(Run("seb4ec", image: "x.png"), Run(" seb4ec"))

    #expect(
      InlineMentions(names: names, repo: nil).pieces(text) == [
        piece("seb4ec", image: "x.png"), piece(" "), mention("seb4ec"),
      ])
  }

  @Test func linkRunPassesThrough() {
    let text = text(Run("seb4ec", link: "https://example.com"), Run(" and seb4ec"))

    #expect(
      InlineMentions(names: names, repo: nil).pieces(text) == [
        piece("seb4ec", link: "https://example.com"), piece(" and "), mention("seb4ec"),
      ])
  }

  @Test(arguments: ["seb4ec", "swb_eb4ec"])
  func exactIdCodeSpanKeepsItsOtherStyles(_ id: String) {
    let text = text(Run(id, [.code, .strong]))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == [mention(id, .strong)])
  }

  @Test func exactIdCodeSpanOfAnUnknownIdKeepsItsCodeStyle() {
    let text = text(Run("sx2zzz", .code))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  @Test func idSplitAcrossRunsPassesThrough() {
    let text = text(Run("seb"), Run("4ec"))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  /// An id never reaches past the end of its run. The first run alone holds no whole id, so nothing links, whatever
  /// the style of the run after it.
  @Test(arguments: [[], .emphasis, .strong, .code, .strikethrough] as [MarkdownText.Style])
  func newIdSplitAcrossRunsPassesThrough(_ style: MarkdownText.Style) {
    let text = text(Run("see swb_eb4"), Run("ec", style), Run(" now"))

    #expect(InlineMentions(names: names, repo: nil).pieces(text).allSatisfy { $0.mention == nil })
  }

  @Test(arguments: [("swb_", "eb4ec"), ("swb", "_eb4ec"), ("s", "wb_eb4ec"), ("swb_eb4e", "c"), ("swb_eb", "4ec")])
  func newIdSplitAtEachPointPassesThrough(_ first: String, _ second: String) {
    let text = text(Run(first), Run(second, .emphasis))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  @Test func oldIdAtTheEndOfARunBeforeAStyledRunMatches() {
    let text = text(Run("see seb4ec"), Run(" now", .strong))

    #expect(
      InlineMentions(names: names, repo: nil).pieces(text) == [
        piece("see "), mention("seb4ec"), piece(" now", .strong),
      ])
  }

  @Test(arguments: ["swb_eb4ecx", "swb_eb4e"])
  func codeSpanThatIsNotExactlyAKnownNewIdKeepsItsCodeStyle(_ code: String) {
    let text = text(Run(code, .code))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  /// cmark splits each of these into runs at the id, and the matcher must not join the runs back into an id.
  @Test(arguments: [
    "swb_eb**4ec**", "swb_eb4**ec**", "swb_eb4*ec*", "swb_eb4~~ec~~", "swb_eb[4ec](https://x.test)", "swb_eb`4ec`",
    "swb_eb4e`c`", "see swb_eb4**ec** now", "seb**4ec**", "seb4e*c*",
  ])
  func markdownThatSplitsAnIdAcrossRunsLinksNothing(_ markdown: String) throws {
    let text = try paragraph(markdown)
    try #require(text.runs.count >= 2, "\(markdown) parses to \(text.runs)")

    #expect(InlineMentions(names: names, repo: nil).pieces(text).allSatisfy { $0.mention == nil })
  }

  /// The `_` of a new id is plain text to cmark, so the paragraph keeps the id in one unstyled run.
  @Test(arguments: ["see swb_eb4ec here", "swb_eb4ec", "seb4ec and swb_eb4ec", "Ask new-id-form (swb_eb4ec) now."])
  func markdownKeepsANewIdInOneUnstyledRun(_ markdown: String) throws {
    let text = try paragraph(markdown)

    #expect(text.runs == [Run(markdown)])
  }

  /// An `s` inside a new id starts an old-form shape. The `_` before it is not a token boundary, so it never matches.
  @Test(arguments: [
    ("swb_s2abcd", "swb_s2abcd"),
    ("swb_s2abc", "⟨swb_s2abc⟩"),
    ("swb_s2abc s2abcd", "⟨swb_s2abc⟩ ⟨s2abcd⟩"),
    ("s2abcd", "⟨s2abcd⟩"),
    ("see swb_s2abcd now", "see swb_s2abcd now"),
  ])
  func oldIdInsideANewIdDoesNotMatch(_ input: String, _ expected: String) {
    let live = ["swb_s2abc": "new-form", "s2abcd": "old-form"]
    let names = SessionNames(live: live, removed: [:])

    #expect(
      InlineMentions(names: names, repo: nil).pieces(MarkdownText(stringLiteral: input))
        == expectedPieces(expected, live: live))
  }

  @Test func oldIdInTheRunAfterANewPrefixDoesNotMatch() {
    let names = SessionNames(live: ["s2abcd": "old-form"], removed: [:])
    let text = text(Run("swb_", .emphasis), Run("s2abcd"))

    #expect(InlineMentions(names: names, repo: nil).pieces(text) == unchanged(text))
  }

  @Test func plainStringBracketSessionLinkBecomesItsLabel() {
    #expect(
      names.replacingIDs(in: "Ask [the fix](switchboard://session/seb4ec) now, then sgcctv.")
        == "Ask the fix now, then render-session-names.")
  }

  @Test(arguments: [
    "Ask [the fix](switchboard://session/seb4ec?x=1) now.",
    "Ask [the fix](switchboard://other/seb4ec) now.",
    "Ask [the fix](https://example.com/seb4ec) now.",
  ])
  func plainStringBracketLinkToARefusedURLComesBackAsWritten(_ input: String) {
    #expect(names.replacingIDs(in: input) == input)
  }

  @Test func sessionWithAnEmptyNameResolvesNothing() {
    let names = SessionNames(live: ["seb4ec": ""], removed: ["sq7kpm": ""])

    #expect(names.isEmpty)
    #expect(names.entry("seb4ec") == nil)
    #expect(names.replacingIDs(in: "seb4ec () and sq7kpm") == "seb4ec () and sq7kpm")
  }

  @Test func collapseThatOverlapsAnEarlierOneStillReplacesItsId() {
    let live = ["sa2222": "b", "sb3333": "b)"]
    let names = SessionNames(live: live, removed: [:])

    #expect(
      InlineMentions(names: names, repo: nil).pieces("sa2222 (b) (sb3333)")
        == expectedPieces("⟨sa2222⟩ (⟨sb3333⟩)", live: live))
  }

  @Test func plainStringBracketSessionLinkToANewIdBecomesItsLabel() {
    #expect(
      names.replacingIDs(in: "Ask [the fix](switchboard://session/swb_eb4ec) now, then swb_eb4ec.")
        == "Ask the fix now, then new-id-form.")
  }

  /// Unstyled rows with a new-form id that cmark parses as one paragraph of the same text.
  private static let newIdParityInputs: [String] = (unchangedPlain + changedPlain.map(\.0)).filter { input in
    input.contains("swb") && input == input.trimmingCharacters(in: .whitespacesAndNewlines)
      && input.allSatisfy { !"`*[]<>&~\\!#".contains($0) } && !input.contains("://") && !input.contains("www.")
  }

  @Test func newIdParityInputsHoldIdsThatLink() {
    let linking = Self.newIdParityInputs.filter { input in
      InlineMentions(names: names, repo: nil).pieces(MarkdownText(stringLiteral: input)).contains { $0.mention != nil }
    }

    #expect(linking.count >= 15, "\(linking)")
  }

  /// The plain-text path and the parsed-paragraph path find the same sessions in text that holds a new id, so the
  /// `_` in the id changes nothing that cmark reads.
  @Test(arguments: newIdParityInputs)
  func plainTextAndItsParagraphFindTheSameSessions(_ input: String) throws {
    let mentions = InlineMentions(names: names, repo: nil)

    let fromPlain = mentions.pieces(MarkdownText(stringLiteral: input)).compactMap(\.mention)
    let fromParagraph = mentions.pieces(try paragraph(input)).compactMap(\.mention)

    #expect(fromPlain == fromParagraph)
  }

  @Test(arguments: ["seb4ec", "swb_eb4ec"])
  func idAtTheEdgeOfAnEmphasisRunMatches(_ id: String) {
    let text = text(Run("Ask "), Run(id, .emphasis), Run(" now"))

    #expect(
      InlineMentions(names: names, repo: nil).pieces(text) == [
        piece("Ask "), mention(id, .emphasis), piece(" now"),
      ])
  }

  @Test(arguments: unchangedPlain)
  func textWithoutIdsHasNoMatches(_ input: String) {
    #expect(
      InlineMentions(names: names, repo: nil).pieces(MarkdownText(stringLiteral: input)).allSatisfy {
        $0.mention == nil
      })
  }

  @Test func matchesReportLiveAndRemovedSessions() {
    let matches = InlineMentions(names: names, repo: nil).pieces("sgcctv and sq7kpm").compactMap(\.mention)

    #expect(
      matches == [
        .session(Match(id: "sgcctv", name: "render-session-names", removed: false)),
        .session(Match(id: "sq7kpm", name: "old-cleanup", removed: true)),
      ])
  }

  @Test func removedSessionDecodesFromJSON() throws {
    let json = Data(#"{"id":"sq7kpm","name":"old-cleanup","removed":1762900000000}"#.utf8)

    let session = try JSONDecoder().decode(RemovedSession.self, from: json)

    #expect(session == RemovedSession(id: "sq7kpm", name: "old-cleanup", removed: 1_762_900_000_000))
  }

  @Test func removedSessionRoundTripsThroughJSON() throws {
    let session = RemovedSession(id: "sq7kpm", name: "old-cleanup", removed: 1_762_900_000_000)

    let decoded = try JSONDecoder().decode(RemovedSession.self, from: JSONEncoder().encode(session))

    #expect(decoded == session)
  }

  /// 2,000 distinct ids of each form in the session id alphabet.
  private static let manyIds: [String] = ["s", SessionID.prefix].flatMap { prefix in
    let alphabet = Array(ShortId.alphabet)
    return (0..<2_000).map { i in
      var n = i
      var id = prefix
      for _ in 0..<ShortId.length {
        id.append(alphabet[n % alphabet.count])
        n /= alphabet.count
      }
      return id
    }
  }

  private static func manyNames() -> SessionNames {
    SessionNames(
      live: Dictionary(uniqueKeysWithValues: manyIds.enumerated().map { ($1, "session-\($0)") }), removed: [:])
  }

  /// Text around each id: look-alike words, punctuation, and multibyte characters.
  private static let filler =
    " to rebase, then check the café ☕ build log for the stream, switch, and submit steps on main street; "

  /// A linear scan takes well under a second, even on a loaded CI runner. A quadratic scan of 200 KB takes
  /// minutes, so this bound still catches one.
  private static let linearBound = Duration.seconds(5)

  @Test func matchingTwoThousandIdsOfEachFormInOneRunIsFast() {
    let string = Self.manyIds.map { "Ask \($0)\(Self.filler)" }.joined()
    let text = MarkdownText(stringLiteral: string)
    let names = Self.manyNames()
    var matched = 0

    let elapsed = ContinuousClock().measure {
      matched = InlineMentions(names: names, repo: nil).pieces(text).count(where: { $0.mention != nil })
    }

    #expect(string.utf8.count >= 200_000)
    #expect(matched == Self.manyIds.count)
    #expect(elapsed < Self.linearBound)
  }

  @Test func matchingTwoThousandIdsOfEachFormAcrossManyRunsIsFast() {
    let runs = Self.manyIds.flatMap { [Run("Ask "), Run($0, .emphasis), Run(Self.filler)] }
    let text = MarkdownText(runs)
    let names = Self.manyNames()
    var matched = 0

    let elapsed = ContinuousClock().measure {
      matched = InlineMentions(names: names, repo: nil).pieces(text).count(where: { $0.mention != nil })
    }

    #expect(text.plain.utf8.count >= 200_000)
    #expect(matched == Self.manyIds.count)
    #expect(elapsed < Self.linearBound)
  }
}
