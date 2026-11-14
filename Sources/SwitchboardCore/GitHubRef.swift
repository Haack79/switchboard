import Foundation

/// A GitHub issue or pull request named by `owner/name#123` or by its URL.
public struct GitHubRef: Equatable, Hashable, Sendable {
  /// Where the reference came from. GitHub numbers issues and pull requests
  /// together and sends `/issues/N` on to the pull request, so only a
  /// `/pull/` URL tells the kind.
  public enum Form: Equatable, Hashable, Sendable {
    case pullURL
    case issueURL
    case shorthand
  }

  /// `owner/name` as written. It passes `Issues.validRepo`.
  public let repo: String
  public let number: Int
  public let form: Form

  private init(repo: String, number: Int, form: Form) {
    self.repo = repo
    self.number = number
    self.form = form
  }

  /// Reads `owner/name#123`, or a URL that `init(url:)` reads. Spaces and tabs around the text are dropped.
  public init?(parsing text: String) {
    self.init(trimmed: text.trimmingCharacters(in: .whitespaces))
  }

  /// `init(parsing:)` without the trim, for a caller that trimmed the text before it dropped a prefix. A second
  /// trim after `pr:` would accept `pr: owner/name#1`.
  init?(trimmed text: String) {
    if text.contains("://") {
      self.init(url: text)
      return
    }
    guard let hash = text.firstIndex(of: "#") else { return nil }
    let repo = String(text[..<hash])
    guard Issues.validRepo(repo), let number = Issues.number(String(text[text.index(after: hash)...])) else {
      return nil
    }
    self.init(repo: repo, number: number, form: .shorthand)
  }

  /// Reads `http` or `https` `github.com/owner/name/issues/123` or `/pull/123`,
  /// in any case, which may end in a further path, a query, or a fragment.
  public init?(url text: String) {
    guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()),
      url.host?.lowercased() == "github.com"
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 4 else { return nil }
    let form: Form
    switch parts[2] {
    case "issues": form = .issueURL
    case "pull": form = .pullURL
    default: return nil
    }
    let repo = "\(parts[0])/\(parts[1])"
    guard Issues.validRepo(repo), let number = Issues.number(parts[3]) else { return nil }
    self.init(repo: repo, number: number, form: form)
  }

  public var isPull: Bool { form == .pullURL }

  /// The lowercased `owner/name#123`. GitHub compares repository names without case.
  public var key: String { "\(repo.lowercased())#\(number)" }

  /// The item's page. An issue URL reaches a pull request too, because GitHub redirects it.
  public var url: URL {
    // `repo` holds only ASCII letters, digits, `_`, `.`, and `-`, so the string always parses.
    URL(string: "https://github.com/\(repo)/\(isPull ? "pull" : "issues")/\(number)")!
  }
}
