import Foundation

/// Splits inline text that sbd or Claude wrote at each mention that a finder
/// reports. `SessionNames` finds session ids, `SessionLink` finds session
/// links, and `GitHubRef` finds issue and pull request references.
public struct InlineMentions: Sendable {
  public enum Mention: Equatable, Sendable {
    case session(SessionNames.Match)
    case reference(GitHubRef)
    /// A link run, a bare URL, or a `[label](URL)` whose URL names a session.
    case sessionLink(SessionLink.Target)
  }

  /// A run of the text. A session's run text is the session's name. A
  /// reference's run keeps its text and style, and links to the item. A
  /// session link's run keeps its style, and links to the URL. A link run
  /// keeps its text, a bare URL reads as written, and `[label](URL)` reads
  /// as its label.
  public struct Piece: Equatable, Sendable {
    public var run: MarkdownText.Run
    public var mention: Mention?

    public init(run: MarkdownText.Run, mention: Mention?) {
      self.run = run
      self.mention = mention
    }
  }

  /// A finder's candidate: the scalars it covers in the whole text, and what they mention.
  struct Span {
    var range: Range<Int>
    /// nil for a URL that names no issue, pull request, or session. It stays plain text.
    var mention: Mention?
    /// Whether the span is a URL or a `[label](URL)` in unlinked text. No other span may overlap it.
    var isURL = false
    /// The text that the piece reads in place of the covered scalars.
    var label: String?
    /// The URL that the piece links to, when its run has no link.
    var link: String?

    static func reference(_ range: Range<Int>, _ ref: GitHubRef?, isURL: Bool = false) -> Span {
      Span(range: range, mention: ref.map(Mention.reference), isURL: isURL)
    }
  }

  private let names: SessionNames
  /// The `owner/name` that a bare `#123` refers to, or nil when the text
  /// belongs to no single repository or the repository has no valid name.
  private let repo: String?

  public init(names: SessionNames, repo: String?) {
    self.names = names
    self.repo = repo.flatMap { GitHubRef.isLinkableRepo($0) ? $0 : nil }
  }

  /// The text split at each mention. An image or footnote run is never
  /// rewritten, and a code run only when its whole text is one session id. A
  /// link run is never split. It is one reference when its link names a
  /// GitHub issue or pull request, and one session link when its link names a
  /// session, even when the run is code or a footnote. A run with no mention
  /// comes back as it was.
  public func pieces(_ text: MarkdownText) -> [Piece] {
    // This collects every run's scalars, so the boundary rules read the real neighbor
    // even when it sits in a link, code, or image run.
    var scalars: [Unicode.Scalar] = []
    var bounds: [Range<Int>] = []
    for run in text.runs {
      let start = scalars.count
      scalars.append(contentsOf: run.text.unicodeScalars)
      bounds.append(start..<scalars.count)
    }
    var pieces: [Piece] = []
    for (run, range) in zip(text.runs, bounds) {
      let references = references(in: run, range, scalars)
      let urls = references.filter(\.isURL)
      let candidates = names.spans(in: run, range, scalars).filter { !Self.overlaps($0.range, urls) } + references
      let spans = Self.merged(candidates, from: range.lowerBound).compactMap { span in
        span.mention.map { (span, $0) }
      }
      guard !spans.isEmpty else {
        pieces.append(Piece(run: run, mention: nil))
        continue
      }
      var at = range.lowerBound
      for (span, mention) in spans {
        if at < span.range.lowerBound { pieces.append(Self.plainPiece(scalars[at..<span.range.lowerBound], run)) }
        pieces.append(Self.piece(span, mention, scalars[span.range], run))
        at = span.range.upperBound
      }
      if at < range.upperBound { pieces.append(Self.plainPiece(scalars[at..<range.upperBound], run)) }
    }
    return pieces
  }

  /// The reference, session link, and URL spans in one run, in order, with no two overlapping. Only plain,
  /// emphasis, strong, and strikethrough text is read. A link run gives one span over its whole text when its link
  /// names an issue, a pull request, or a session. A session link changes no text, so a code or footnote run in one
  /// gives its span too.
  private func references(in run: MarkdownText.Run, _ range: Range<Int>, _ s: [Unicode.Scalar]) -> [Span] {
    guard run.image == nil else { return [] }
    // `target(from:)` refuses a link without the exact prefix. The check skips the URL parse for every other link.
    if let link = run.link, link.hasPrefix(SessionLink.prefix),
      let target = URL(string: link).flatMap(SessionLink.target(from:))
    {
      return [Span(range: range, mention: .sessionLink(target))]
    }
    guard run.style.isDisjoint(with: [.code, .footnote]) else { return [] }
    guard let link = run.link else {
      let references = GitHubRef.spans(in: range, s, repo: repo)
      let sessionLinks = SessionLink.spans(in: range, s)
      // A GitHub URL and a session URL can overlap when no space separates them.
      return sessionLinks.isEmpty ? references : Self.merged(references + sessionLinks, from: range.lowerBound)
    }
    return GitHubRef(linkableURL: link).map { [.reference(range, $0)] } ?? []
  }

  /// Whether `range` overlaps one of `urls`, which are in order and do not overlap each other. It searches
  /// `urls` by halves, because a scan of every URL for each session id is quadratic in a long run.
  private static func overlaps(_ range: Range<Int>, _ urls: [Span]) -> Bool {
    var low = 0
    var high = urls.count
    while low < high {
      let mid = (low + high) / 2
      if urls[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
    }
    return low < urls.count && urls[low].range.lowerBound < range.upperBound
  }

  /// The spans to keep, in order: the earliest start wins, a longer span wins
  /// at the same start, and a span that overlaps a kept one is dropped.
  static func merged(_ candidates: [Span], from start: Int) -> [Span] {
    let sorted = candidates.sorted {
      ($0.range.lowerBound, -$0.range.count) < ($1.range.lowerBound, -$1.range.count)
    }
    var kept: [Span] = []
    for span in sorted where span.range.lowerBound >= (kept.last?.range.upperBound ?? start) {
      kept.append(span)
    }
    return kept
  }

  /// The piece for a span and its mention.
  private static func piece(
    _ span: Span, _ mention: Mention, _ covered: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run
  ) -> Piece {
    var piece = plainPiece(covered, run)
    piece.mention = mention
    switch mention {
    case .session(let match):
      var style = run.style
      style.remove(.code)
      piece.run = MarkdownText.Run(match.name, style)
    case .reference(let ref):
      if piece.run.link == nil { piece.run.link = ref.link(writtenAs: piece.run.text) }
    case .sessionLink:
      if let label = span.label { piece.run.text = label }
      if let link = span.link { piece.run.link = link }
    }
    return piece
  }

  private static func plainPiece(_ scalars: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run) -> Piece {
    var run = run
    run.text = String(String.UnicodeScalarView(scalars))
    return Piece(run: run, mention: nil)
  }
}
