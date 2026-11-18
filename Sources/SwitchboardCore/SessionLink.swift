import Foundation

/// The URL of a link to a session, `switchboard://session/<id>` or
/// `switchboard://session/<name>`. The app registers the scheme, so a link
/// from another app or from `sb focus` opens the session in Switchboard.
public enum SessionLink {
  public static let scheme = "switchboard"
  private static let prefix = "\(scheme)://session/"

  /// What a link names. Names are not unique and change on rename, so the
  /// links that Switchboard writes always name the id.
  public enum Target: Equatable, Sendable {
    case id(String)
    case name(String)
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
    "When you name a Switchboard session in a reply, write it as a Markdown link to the session's URL, such as [fix-cache](switchboard://session/seb4ec). Copy the URL from the `url` field of `sb get --json` or `sb ls --json`, or of the `get_session` or `list_sessions` tool."

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
  public static func resolve(_ target: Target, in sessions: [(id: String, name: String)]) -> Resolution {
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
