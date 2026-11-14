import Foundation

/// The URL of a link to a session, `switchboard://session/<id>`. The app
/// registers the scheme, so a link from another app or from `sb focus` opens
/// the session in Switchboard.
public enum SessionLink {
  public static let scheme = "switchboard"
  private static let prefix = "\(scheme)://session/"

  /// `id` is a session id, so the string always parses as a URL.
  public static func url(for id: String) -> URL { URL(string: prefix + id)! }

  /// The session id of a link that `url(for:)` made, else nil. Any app can
  /// open the scheme, so only the exact text that `url(for:)` builds counts.
  public static func id(from url: URL) -> String? {
    let string = url.absoluteString
    guard string.hasPrefix(prefix) else { return nil }
    let id = String(string.dropFirst(prefix.count))
    return SessionNames.isSessionID(id) ? id : nil
  }
}
