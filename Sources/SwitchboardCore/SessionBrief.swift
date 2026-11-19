/// The few fields of a session that a caller needs to decide whether to act
/// on it. `sb get --brief`, `sb ls --brief`, and the `get_session` and
/// `list_sessions` tools return it. Each key means what the same key means in
/// `SessionSummary`. The reason and the wait line have length caps, so a long
/// reply, note, or wait note does not grow it.
public struct SessionBrief: Codable, Equatable, Sendable {
  public struct PR: Codable, Equatable, Sendable {
    public var number: Int
    public var repo: String
    public var state: PRState
    public var status: PRStatus
    public var checks: String?
  }

  public var id: String
  public var name: String
  public var url: String?
  public var state: AttentionState
  /// The reason on one line, cut to `reasonMax` characters.
  public var reason: String
  public var acknowledged: Bool?
  public var snoozedUntil: Int64?
  public var pr: PR?
  /// What each open wait waits on, joined with "; ". The line holds at most
  /// `waitLineMax` characters and counts the waits that did not fit.
  public var waitLine: String?

  public static let reasonMax = 200
  public static let waitMax = 80
  public static let waitLineMax = 200

  public init(_ s: SessionSummary) {
    id = s.id
    name = s.name
    url = s.url
    state = s.state
    reason = oneLine(s.reason, max: Self.reasonMax)
    acknowledged = s.acknowledged
    snoozedUntil = s.snoozedUntil
    pr = s.pr.map { PR(number: $0.number, repo: $0.repo, state: $0.state, status: $0.status, checks: $0.checks) }
    waitLine = Self.waitLine(s.waits)
  }

  /// The waits' summaries without repeats, each cut to `waitMax`. It adds
  /// summaries while the line, with its "and N more" ending, fits in
  /// `waitLineMax`. Repeats drop before the cut, so two notes that differ
  /// only after the cut both count.
  static func waitLine(_ waits: [Wait]) -> String? {
    var seen = Set<String>()
    let texts = waits.map(\.summary).filter { seen.insert($0).inserted }.map { oneLine($0, max: waitMax) }
    guard !texts.isEmpty else { return nil }
    func line(_ shown: ArraySlice<String>) -> String {
      let more = texts.count - shown.count
      return shown.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "")
    }
    var count = 1
    while count < texts.count, line(texts.prefix(count + 1)).count <= waitLineMax { count += 1 }
    return line(texts.prefix(count))
  }

  /// The brief form of `full`, which is one session or a list of sessions as
  /// sbd's `get` and `ls` answer.
  public static func json(_ full: JSON) throws -> JSON {
    if let items = full.array { return .array(try items.map(json)) }
    return try JSON(encoding: SessionBrief(JSONCoding.convert(full, to: SessionSummary.self)))
  }
}

extension SessionSummary {
  /// The brief form on one line: the id, name, state, reason, PR, open waits,
  /// and url.
  public var briefLine: String {
    let brief = SessionBrief(self)
    var parts = [id, name, "\(state.title): \(marking(brief.reason))"]
    if let pr { parts.append("PR \(pr.repo)\(pr.line)") }
    if let waits = brief.waitLine { parts.append("waits: \(waits)") }
    if let url { parts.append(url) }
    return oneLine(parts.joined(separator: "  "), max: .max).printable
  }
}
