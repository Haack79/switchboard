/// Splits inline text that sbd or Claude wrote at each mention that a finder
/// reports. `SessionNames` finds session ids.
public struct InlineMentions: Sendable {
  public enum Mention: Equatable, Sendable {
    case session(SessionNames.Match)
  }

  /// A run of the text. A session's run text is the session's name.
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
    var mention: Mention
  }

  private let names: SessionNames
  /// The `owner/name` that a bare `#123` refers to, or nil when the text belongs to no single repository.
  private let repo: String?

  public init(names: SessionNames, repo: String?) {
    self.names = names
    self.repo = repo
  }

  /// The text split at each mention. A link, image, or footnote run is never
  /// rewritten, and a code run only when its whole text is one session id. A
  /// run with no mention comes back as it was.
  public func pieces(_ text: MarkdownText) -> [Piece] {
    guard !names.isEmpty else { return text.runs.map { Piece(run: $0, mention: nil) } }
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
      let spans = Self.merged(names.spans(in: run, range, scalars), from: range.lowerBound)
      guard !spans.isEmpty else {
        pieces.append(Piece(run: run, mention: nil))
        continue
      }
      var at = range.lowerBound
      for span in spans {
        if at < span.range.lowerBound { pieces.append(Self.plainPiece(scalars[at..<span.range.lowerBound], run)) }
        pieces.append(Self.piece(span.mention, run))
        at = span.range.upperBound
      }
      if at < range.upperBound { pieces.append(Self.plainPiece(scalars[at..<range.upperBound], run)) }
    }
    return pieces
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

  private static func piece(_ mention: Mention, _ run: MarkdownText.Run) -> Piece {
    switch mention {
    case .session(let match):
      var style = run.style
      style.remove(.code)
      return Piece(run: MarkdownText.Run(match.name, style), mention: mention)
    }
  }

  private static func plainPiece(_ scalars: ArraySlice<Unicode.Scalar>, _ run: MarkdownText.Run) -> Piece {
    var run = run
    run.text = String(String.UnicodeScalarView(scalars))
    return Piece(run: run, mention: nil)
  }
}
