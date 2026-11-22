import Foundation

/// A web page attached to a group or a session, such as an RFC, a design doc, or a Slack thread. On a group, the
/// user adds any link, and a Claude Code session adds only a link to a claude.ai artifact. A group link to a
/// claude.ai artifact also lists among the group's artifacts.
public struct ExternalLink: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var url: String
  public var by: Author
  /// Milliseconds since the epoch.
  public var t: Int64

  /// The longest title, in characters.
  public static let titleLimit = 200
  /// The longest URL, in characters.
  public static let urlLimit = 2000

  public init(id: String, title: String, url: String, by: Author, t: Int64) {
    self.id = id
    self.title = title
    self.url = url
    self.by = by
    self.t = t
  }

  /// The URL that two links to the same page share: the normalized form of a claude.ai artifact link, else the URL.
  var target: String { ArtifactLink.normalized(url) ?? url }

  /// The URL without surrounding whitespace, and a claude.ai artifact link in its normalized form. It refuses a URL
  /// that is not http or https, that has no host, or that holds whitespace, because sessions will read it as one
  /// token.
  public static func cleanURL(_ text: String?) throws -> String {
    let url = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { throw APIError("a link needs a URL") }
    guard url.count <= urlLimit else {
      throw APIError("a link URL has at most \(urlLimit) characters, and this one has \(url.count)")
    }
    guard !url.contains(where: \.isWhitespace), let parsed = URL(string: url),
      let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme), parsed.host?.isEmpty == false
    else { throw APIError("a link needs an http or https URL with a host, not \(url)") }
    return ArtifactLink.normalized(url) ?? url
  }

  /// The title on one line. Without a title, it is the URL, cut to `titleLimit` characters with an ellipsis when it
  /// is longer. It refuses a given title over `titleLimit`.
  public static func cleanTitle(_ text: String?, url: String) throws -> String {
    if let title = try SessionGroup.cleanLine(text, limit: titleLimit, noun: "a link title") { return title }
    return url.count <= titleLimit ? url : String(url.prefix(titleLimit - 1)) + "…"
  }
}
