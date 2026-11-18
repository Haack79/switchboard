import Foundation

/// The URL of a link to a session, `switchboard://session/<id>` or
/// `switchboard://session/<name>`. The app registers the scheme, so a link
/// from another app or from `sb focus` opens the session in Switchboard.
public enum SessionLink {
  public static let scheme = "switchboard"
  private static let schemeStart = "\(scheme)://"
  static let prefix = "\(schemeStart)session/"

  /// What a link names. Names are not unique and change on rename, so the
  /// links that Switchboard writes always name the id.
  public enum Target: Hashable, Sendable {
    case id(String)
    case name(String)

    /// The id or the name, as the link holds it.
    public var text: String {
      switch self {
      case .id(let id): id
      case .name(let name): name
      }
    }
  }

  public enum Resolution: Equatable, Sendable {
    case session(String)
    case unknown
    /// More than one session has the name. The count is how many.
    case ambiguous(Int)
  }

  /// The guidance that the Manager guide, the chat guide, and the default
  /// system prompt give every agent.
  public static let guidance =
    "When you name a Switchboard session in a reply, write it as a Markdown link to its id URL, such as [fix-cache](switchboard://session/seb4ec). Copy the URL from the `url` field of `sb get --json`, `sb ls --json`, or the `get_session` and `list_sessions` tools, or from a Switchboard message that gives it. Never build the URL yourself: if you don't have it, look the session up first."

  /// `id` is a session id, so the string always parses as a URL.
  public static func url(for id: String) -> URL { URL(string: prefix + id)! }

  /// The name link of a session. Every character but an unreserved one is
  /// percent-encoded, so the result always parses as a URL. A dot name or an
  /// id-shaped name gives a URL that `target(from:)` refuses.
  public static func url(forName name: String) -> URL {
    // Every id character is unreserved. Without the escape, an id-shaped name
    // would give the id link of the session that has that id.
    if SessionNames.isSessionID(name) { return URL(string: prefix + "%73" + name.dropFirst())! }
    return URL(string: prefix + name.addingPercentEncoding(withAllowedCharacters: unreserved)!)!
  }

  /// What the link names, else nil. Any app can open the scheme, so the URL
  /// must start with exactly `switchboard://session/`, and the rest must be
  /// one path segment with no query, fragment, or `;`. The segment is an id
  /// target only as the exact id text. Otherwise it is a name target when it
  /// percent-decodes to a valid name.
  public static func target(from url: URL) -> Target? {
    let string = url.absoluteString
    guard string.hasPrefix(prefix) else { return nil }
    let segment = String(string.dropFirst(prefix.count))
    guard segment.unicodeScalars.allSatisfy(segmentScalars.contains) else { return nil }
    if SessionNames.isSessionID(segment) { return .id(segment) }
    guard let name = segment.removingPercentEncoding, isName(name) else { return nil }
    return .name(name)
  }

  /// The one session that the target names. An id target matches ids only,
  /// and a name target matches exact, case-sensitive names only.
  public static func resolve(_ target: Target, in sessions: some Sequence<(id: String, name: String)>) -> Resolution {
    switch target {
    case .id(let id):
      return sessions.contains { $0.id == id } ? .session(id) : .unknown
    case .name(let name):
      // The app's list can hold a session twice while it moves from one list to another.
      let ids = Set(sessions.lazy.filter { $0.name == name }.map(\.id))
      switch ids.count {
      case 0: return .unknown
      case 1: return .session(ids.first!)
      default: return .ambiguous(ids.count)
      }
    }
  }

  /// `[name](id link)` for the clipboard. Each newline in the name becomes a
  /// space. A backslash goes before each character that could start Markdown
  /// syntax inside the label, so the label reads as the name.
  public static func markdown(name: String, id: String) -> String {
    let label = String(name.map { $0.isNewline ? " " : $0 })
    var escaped = String.UnicodeScalarView()
    for c in label.unicodeScalars {
      if MarkdownText.alwaysEscaped.contains(c) { escaped.append("\\") }
      escaped.append(c)
    }
    return "[\(String(escaped))](\(url(for: id).absoluteString))"
  }

  /// The session link spans in one unlinked run, in order. A bare
  /// `switchboard://` URL ends where cmark-gfm ends an autolink, and it links
  /// only when `target(from:)` accepts it, `URL(string:)` keeps its text as
  /// written, and no word or path touches its scheme. A refused URL is a span
  /// with no mention, so no session id inside it matches. `[label](URL)` is a
  /// span when the label is not empty, holds no newline and no unescaped `[`
  /// or `]`, and `target(from:)` accepts the URL. Its piece reads the label,
  /// and the backslash before each ASCII punctuation character in the label or
  /// the URL is dropped, as CommonMark reads a link. A `[` with a backslash
  /// before it starts no label.
  static func spans(in range: Range<Int>, _ s: [Unicode.Scalar]) -> [InlineMentions.Span] {
    var spans: [InlineMentions.Span] = []
    var i = range.lowerBound
    while i < range.upperBound {
      if isEscape(at: i, before: range.upperBound, s) {
        i += 2
      } else if s[i] == "[", let span = bracketLink(at: i, before: range.upperBound, s) {
        spans.append(span)
        i = span.range.upperBound
      } else if let schemeEnd = TokenBoundary.spells(schemeStart, at: i, before: range.upperBound, s) {
        let (end, cut) = TokenBoundary.autolinkEnd(after: schemeEnd, before: range.upperBound, s)
        let text = String(String.UnicodeScalarView(s[i..<end]))
        // `URL(string:)` percent-encodes a character that no URL may hold, such as the `>` of `<URL>`.
        let url = URL(string: text).flatMap { $0.absoluteString == text ? $0 : nil }
        let target = !cut && (i == 0 || TokenBoundary.allowedBefore(s[i - 1])) ? url.flatMap(target(from:)) : nil
        spans.append(
          InlineMentions.Span(range: i..<end, mention: target.map { .sessionLink($0) }, isURL: true, link: text))
        i = end
      } else {
        i += 1
      }
    }
    return spans
  }

  /// The `[label](URL)` span whose `[` sits at `open`. The URL stops at the
  /// first `)` outside balanced parentheses. A space, a control character,
  /// or a raw `[` or `]` in it refuses the span, so that a scan from each
  /// `[` stops at the next one.
  private static func bracketLink(at open: Int, before limit: Int, _ s: [Unicode.Scalar]) -> InlineMentions.Span? {
    var label = String.UnicodeScalarView()
    var i = open + 1
    while i < limit, s[i] != "]" {
      if s[i] == "[" || s[i] == "\n" || s[i] == "\r" { return nil }
      if isEscape(at: i, before: limit, s) { i += 1 }
      label.append(s[i])
      i += 1
    }
    guard !label.isEmpty, i + 1 < limit, s[i + 1] == "(" else { return nil }
    var destination = String.UnicodeScalarView()
    var end = i + 2
    var depth = 0
    while end < limit, s[end] != ")" || depth > 0 {
      switch s[end] {
      case "\\" where isEscape(at: end, before: limit, s): end += 1
      case "(": depth += 1
      case ")": depth -= 1
      case "[", "]": return nil
      case let c where c.properties.isWhitespace || c.properties.generalCategory == .control: return nil
      default: break
      }
      destination.append(s[end])
      end += 1
    }
    guard end < limit else { return nil }
    let url = String(destination)
    guard let target = URL(string: url).flatMap(target(from:)) else { return nil }
    return InlineMentions.Span(
      range: open..<end + 1, mention: .sessionLink(target), isURL: true, label: String(label), link: url)
  }

  /// Whether `s[i]` is a backslash that escapes the ASCII punctuation character after it.
  private static func isEscape(at i: Int, before limit: Int, _ s: [Unicode.Scalar]) -> Bool {
    s[i] == "\\" && i + 1 < limit && isASCIIPunctuation(s[i + 1])
  }

  private static func isASCIIPunctuation(_ c: Unicode.Scalar) -> Bool {
    c.isASCII && c.properties.generalCategory != .control && !c.properties.isAlphabetic
      && !("0"..."9").contains(c) && c != " "
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// RFC 3986 `pchar` without `;`. A `/`, `?`, or `#` would start another
  /// segment, a query, or a fragment.
  private static let segmentScalars = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%!$&'()*+,=:@".unicodeScalars)

  private static let maxNameScalars = 200

  /// A dot name would be a dot segment, and an id-shaped name would reach a
  /// session by a form that the id path refuses.
  private static func isName(_ name: String) -> Bool {
    let scalars = name.unicodeScalars
    return !scalars.allSatisfy(\.properties.isWhitespace)
      && !scalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
      && scalars.count <= maxNameScalars
      && name != "." && name != ".."
      && !SessionNames.isSessionID(name)
  }
}
