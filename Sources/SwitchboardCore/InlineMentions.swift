/// Splits inline text that sbd or Claude wrote at each mention that a finder
/// reports. `SessionNames` finds session ids, and `GitHubRef` finds issue and
/// pull request references.
public struct InlineMentions: Sendable {
  public enum Mention: Equatable, Sendable {
    case session(SessionNames.Match)
    case reference(GitHubRef)
  }

  /// A run of the text. A session's run text is the session's name. A
  /// reference's run keeps its text and style, and links to the item.
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
    /// nil for a URL that names no issue or pull request. It stays plain text.
    var mention: Mention?
    /// Whether the span is a URL in unlinked text. No other span may overlap a URL.
    var isURL = false

    static func reference(_ range: Range<Int>, _ ref: GitHubRef?, isURL: Bool = false) -> Span {
      Span(range: range, mention: InlineMentions.linksReferences ? ref.map(Mention.reference) : nil, isURL: isURL)
    }
  }

  /// When false, every reference stays plain text, and URLs still keep session ids in them unchanged. A hotfix
  /// can turn it off to stop linking references without a revert.
  static let linksReferences = true

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
  /// link run is never split, and it is one reference when its link names a
  /// GitHub issue or pull request. A run with no mention comes back as it was.
  public func pieces(_ text: MarkdownText) -> [Piece] {
    // Every run's scalars, so that the boundary rules read the real neighbor
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
        span.mention.map { (range: span.range, mention: $0) }
      }
      guard !spans.isEmpty else {
        pieces.append(Piece(run: run, mention: nil))
        continue
      }
      var at = range.lowerBound
      for span in spans {
        if at < span.range.lowerBound { pieces.append(Self.plainPiece(scalars[at..<span.range.lowerBound], run)) }
        pieces.append(Self.piece(span.mention, scalars[span.range], run))
        at = span.range.upperBound
      }
      if at < range.upperBound { pieces.append(Self.plainPiece(scalars[at..<range.upperBound], run)) }
    }
    return pieces
  }

  /// The reference and URL spans in one run. Only plain, emphasis, strong, and strikethrough text is read. A link
  /// run gives one span over its whole text when its link names an issue or pull request.
  private func references(in run: MarkdownText.Run, _ range: Range<Int>, _ s: [Unicode.Scalar]) -> [Span] {
    guard run.image == nil, run.style.isDisjoint(with: [.code, .footnote]) else { return [] }
    guard let link = run.link else { return GitHubRef.spans(in: range, s, repo: repo) }
    return GitHubRef(linkableURL: link).map { [Span.reference(range, $0)] } ?? []
  }

  /// Whether `range` overlaps one of `urls`, which are in order and do not overlap each other.
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

  private static func piece(_ mention: Mention, _ covered: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run)
    -> Piece
  {
    switch mention {
    case .session(let match):
      var style = run.style
      style.remove(.code)
      return Piece(run: MarkdownText.Run(match.name, style), mention: mention)
    case .reference(let ref):
      var piece = plainPiece(covered, run)
      piece.mention = mention
      // A link run keeps its own link.
      if piece.run.link == nil { piece.run.link = ref.link(writtenAs: piece.run.text) }
      return piece
    }
  }

  private static func plainPiece(_ scalars: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run) -> Piece {
    var run = run
    run.text = String(String.UnicodeScalarView(scalars))
    return Piece(run: run, mention: nil)
  }
}
