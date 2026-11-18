/// How sbd names a session in text that a person or an agent reads. The id
/// stays because an agent needs it to run `sb` commands.
public func sessionMention(name: String, id: String) -> String { "\(name) (\(id))" }

extension Session {
  public var mention: String { sessionMention(name: name, id: id) }
}

/// A session that sbd removed, with the name it had then.
public struct RemovedSession: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  /// When sbd removed the session, in ms since the epoch.
  public var removed: Int64

  public init(id: String, name: String, removed: Int64) {
    self.id = id
    self.name = name
    self.removed = removed
  }
}

/// The names of live and removed sessions, and the matcher that finds their
/// ids in text that sbd or Claude wrote.
public struct SessionNames: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let name: String
    public let removed: Bool
  }

  public struct Match: Equatable, Sendable {
    public var id: String
    public var name: String
    public var removed: Bool

    public init(id: String, name: String, removed: Bool) {
      self.id = id
      self.name = name
      self.removed = removed
    }
  }

  private typealias Span = InlineMentions.Span

  private let entries: [String: Entry]

  /// A live name wins over a removed one. An empty name resolves nothing,
  /// because the id would then vanish from the text.
  public init(live: [String: String], removed: [String: String]) {
    var entries: [String: Entry] = [:]
    for (id, name) in removed where !name.isEmpty { entries[id] = Entry(name: name, removed: true) }
    for (id, name) in live where !name.isEmpty { entries[id] = Entry(name: name, removed: false) }
    self.entries = entries
  }

  public static let empty = SessionNames(live: [:], removed: [:])

  public var isEmpty: Bool { entries.isEmpty }

  public func entry(_ id: String) -> Entry? { entries[id] }

  /// The session's name, or `id` when no session has it.
  public func name(_ id: String) -> String { entries[id]?.name ?? id }

  /// `string` with each session id that resolves replaced by the session's name, and each session link written as
  /// `[label](URL)` replaced by its label. No other Markdown in it is parsed.
  public func replacingIDs(in string: String) -> String {
    InlineMentions(names: self, repo: nil).pieces(MarkdownText(stringLiteral: string)).map(\.run.text).joined()
  }

  /// The candidate spans in one run that become names: each id that is a whole token and resolves, and each
  /// `name (id)` around one. `InlineMentions` drops the ones that overlap.
  func spans(in run: MarkdownText.Run, _ range: Range<Int>, _ s: [Unicode.Scalar]) -> [InlineMentions.Span] {
    guard run.link == nil, run.image == nil, !run.style.contains(.footnote) else { return [] }
    if run.style.contains(.code) {
      // A code span is rewritten only when its whole text is one id.
      guard let (match, length) = match(at: range.lowerBound, before: range.upperBound, s), length == range.count
      else { return [] }
      return [Span(range: range, mention: .session(match))]
    }
    var candidates: [Span] = []
    var i = range.lowerBound
    while i + SessionID.minLength <= range.upperBound {
      if let (match, length) = match(at: i, before: range.upperBound, s) {
        let bare = i..<i + length
        let wide = collapsed(bare, match, within: range, s)
        // A collapsed `name (id)` wins over an id found inside its name. When an
        // earlier span takes part of a collapsed one, the bare id still matches.
        candidates.append(Span(range: bare, mention: .session(match)))
        if wide != bare { candidates.append(Span(range: wide, mention: .session(match))) }
      }
      i += 1
    }
    return candidates
  }

  /// The session whose id starts at `i` and ends at or before `limit`, with the id's length, when the id is a whole
  /// token and resolves.
  private func match(at i: Int, before limit: Int, _ s: [Unicode.Scalar]) -> (Match, Int)? {
    guard let length = SessionID.length(at: i, in: s, before: limit),
      i == 0 || TokenBoundary.allowedBefore(s[i - 1]),
      TokenBoundary.allowedAfter(i + length, s)
    else { return nil }
    let id = String(String.UnicodeScalarView(s[i..<i + length]))
    guard let entry = entries[id] else { return nil }
    return (Match(id: id, name: entry.name, removed: entry.removed), length)
  }

  /// The id's range widened to `<name> (<id>)` or `<id> (<name>)` when the
  /// session's name sits there within the same run and the widened span is a
  /// whole token.
  private func collapsed(_ id: Range<Int>, _ match: Match, within run: Range<Int>, _ s: [Unicode.Scalar]) -> Range<Int>
  {
    let name = Array(match.name.unicodeScalars)
    let before = name + [" ", "("]
    let start = id.lowerBound - before.count
    if start >= run.lowerBound, id.upperBound < run.upperBound, s[id.upperBound] == ")",
      Self.spells(s[start..<id.lowerBound], before, atTextStart: start == 0),
      start == 0 || TokenBoundary.allowedBefore(s[start - 1]),
      TokenBoundary.allowedAfter(id.upperBound + 1, s)
    {
      return start..<id.upperBound + 1
    }
    let after = [" ", "("] + name + [")"]
    let end = id.upperBound + after.count
    if end <= run.upperBound, s[id.upperBound..<end].elementsEqual(after), TokenBoundary.allowedAfter(end, s) {
      return id.lowerBound..<end
    }
    return id
  }

  /// Whether `written` is `expected`. At the start of the text the first letter may differ in case, because a
  /// title capitalizes it.
  private static func spells(_ written: ArraySlice<Unicode.Scalar>, _ expected: [Unicode.Scalar], atTextStart: Bool)
    -> Bool
  {
    if written.elementsEqual(expected) { return true }
    guard atTextStart, let first = written.first, let expectedFirst = expected.first else { return false }
    return first.properties.lowercaseMapping == expectedFirst.properties.lowercaseMapping
      && written.dropFirst().elementsEqual(expected.dropFirst())
  }
}
