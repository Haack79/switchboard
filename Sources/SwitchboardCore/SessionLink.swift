import Foundation

/// The URL of a link to a session. Only the app's own views see the scheme,
/// because it is not registered with Launch Services.
public enum SessionLink {
  private static let prefix = "switchboard-session:"

  /// `id` is a session id, so the string always parses as a URL.
  public static func url(for id: String) -> URL { URL(string: prefix + id)! }

  /// The session id of a link that `url(for:)` made, else nil.
  public static func id(from url: URL) -> String? {
    let string = url.absoluteString
    guard string.hasPrefix(prefix) else { return nil }
    let id = String(string.dropFirst(prefix.count))
    return SessionNames.isSessionID(id) ? id : nil
  }
}
